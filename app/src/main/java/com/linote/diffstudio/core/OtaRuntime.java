package com.linote.diffstudio.core;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

/** Port of ota_runtime.py. */
public final class OtaRuntime {
    private OtaRuntime() {}

    /** Ordered support sources: engine.py, boot.py, rpc.py, proxy.sh, unisoc-ota.js, errors.js, unisoc-ota.json, lz4raw-aarch64.so */
    public interface SupportFiles {
        /** family is "e5" or "mu300": each desktop edition ships its own protocol engine. */
        byte[] read(String family, String name) throws IOException;
    }

    public static final String[] TEXT_SUPPORT = {"engine.py", "boot.py", "rpc.py", "proxy.sh", "unisoc-ota.js", "errors.js", "unisoc-ota.json"};

    public static LinkedHashMap<String, byte[]> supportSources(String family, SupportFiles files) throws IOException {
        LinkedHashMap<String, byte[]> result = new LinkedHashMap<>();
        for (String name : TEXT_SUPPORT) result.put(name, crlfToLf(files.read(family, name)));
        result.put("lz4raw-aarch64.so", files.read(family, "lz4raw-aarch64.so"));
        return result;
    }

    static byte[] crlfToLf(byte[] b) {
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream(b.length);
        for (int i = 0; i < b.length; i++) {
            if (b[i] == '\r' && i + 1 < b.length && b[i + 1] == '\n') continue;
            out.write(b[i]);
        }
        return out.toByteArray();
    }

    public static final class Built {
        public final LinkedHashMap<String, Map<String, Object>> runtime;
        public final Map<String, Object> busybox; // null when the release has no static BusyBox
        public final LinkedHashMap<String, byte[]> extra;

        Built(LinkedHashMap<String, Map<String, Object>> runtime, Map<String, Object> busybox, LinkedHashMap<String, byte[]> extra) {
            this.runtime = runtime;
            this.busybox = busybox;
            this.extra = extra;
        }
    }

    private static boolean selected(String name) {
        if (name.startsWith("usr/lib/python3") || name.startsWith("usr/bin/python3")) return true;
        if (!(name.startsWith("lib/") || name.startsWith("usr/lib/"))) return false;
        String[] parts = name.split("/", name.startsWith("usr/") ? 3 : 2);
        String last = parts[parts.length - 1];
        return !last.contains("/") && (name.contains(".so") || name.endsWith("/libc.so"));
    }

    public static Built build(Release release, SupportFiles files) throws IOException {
        LinkedHashMap<String, Map<String, Object>> runtime = new LinkedHashMap<>();
        LinkedHashMap<String, byte[]> extra = new LinkedHashMap<>();
        for (Map.Entry<String, Map<String, Object>> e : release.entries.entrySet()) {
            if (selected(e.getKey()) && !"dir".equals(e.getValue().get("kind"))) runtime.put(e.getKey(), e.getValue());
        }
        for (int round = 0; round < 8; round++) {
            boolean added = false;
            for (Map.Entry<String, Map<String, Object>> e : new ArrayList<>(runtime.entrySet())) {
                Map<String, Object> desc = e.getValue();
                if (!"symlink".equals(desc.get("kind"))) continue;
                String target = (String) desc.get("target");
                String name = e.getKey();
                target = Py.normpath(target.startsWith("/") ? target.replaceFirst("^/+", "") : Py.join(Py.dirname(name), target));
                if (!runtime.containsKey(target) && release.entries.containsKey(target)) {
                    runtime.put(target, release.entries.get(target));
                    added = true;
                }
            }
            if (!added) break;
        }
        for (Map.Entry<String, byte[]> e : supportSources(release.family, files).entrySet()) {
            byte[] content = e.getValue();
            String h = Py.sha256Hex(content);
            extra.put(h, content);
            runtime.put("ota/" + e.getKey(), fileDesc(0644, content.length, h));
        }
        String busybox = null;
        for (String n : new String[]{"files/busybox", "payload/busybox", "busybox"}) {
            if (release.exists(n)) { busybox = n; break; }
        }
        Map<String, Object> bb = null;
        if (busybox != null) {
            byte[] content;
            try (InputStream in = release.open(busybox)) {
                content = Py.readUpTo(in, 16L << 20);
            }
            String h = Py.sha256Hex(content);
            extra.put(h, content);
            bb = new LinkedHashMap<>();
            bb.put("sha256", h);
            bb.put("size", (long) content.length);
            Map<String, Object> d = fileDesc(0700, content.length, h);
            runtime.put("ota/busybox", d);
        }
        return new Built(runtime, bb, extra);
    }

    static Map<String, Object> fileDesc(long mode, long size, String sha) {
        LinkedHashMap<String, Object> d = new LinkedHashMap<>();
        d.put("kind", "file");
        d.put("mode", mode);
        d.put("uid", 0L);
        d.put("gid", 0L);
        d.put("xattrs", new LinkedHashMap<String, Object>());
        d.put("size", size);
        d.put("sha256", sha);
        return d;
    }

    /** str(Path(name).parent).replace('\\', '/') as evaluated on Windows for the generated relative names. */
    static String parent(String name) {
        int i = name.lastIndexOf('/');
        return i < 0 ? "." : name.substring(0, i);
    }

    public static byte[] bootstrap(Map<String, Map<String, Object>> runtime) {
        List<String> lines = new ArrayList<>();
        String[] head = {"#!/bin/sh", "set -eu", "umask 077", "patch=$1", "command=$2", "home=$3",
                "id=${home#/tmp/unisoc-ota-}",
                "case \"$id\" in *[!0-9a-f]*|'') exit 2 ;; esac",
                "[ \"$home\" != \"$id\" ] && [ ${#id} -eq 64 ] && [ ! -L \"$home\" ]",
                "bb=\"$home/busybox\"", "root=\"$home/root\"", "\"$bb\" mkdir -p \"$root\" \"$home/content\"",
                "mounted() {",
                " while read -r source destination rest; do",
                "  [ \"$destination\" != \"$1\" ] || return 0",
                " done < /proc/mounts",
                " return 1", "}"};
        for (String s : head) lines.add(s);
        TreeSet<String> hashes = new TreeSet<>(Py.CODEPOINT_ORDER);
        for (Map<String, Object> d : runtime.values()) if ("file".equals(d.get("kind"))) hashes.add((String) d.get("sha256"));
        StringBuilder unzip = new StringBuilder("\"$bb\" unzip -oq \"$patch\" ");
        boolean first = true;
        for (String h : hashes) {
            if (!first) unzip.append(' ');
            first = false;
            unzip.append("blobs/").append(h);
        }
        unzip.append(" -d \"$home/content\"");
        lines.add(unzip.toString());
        lines.add("\"$bb\" cat > \"$home/runtime.sha256\" <<'OTA_RUNTIME_HASHES'");
        for (String h : hashes) lines.add(h + "  content/blobs/" + h);
        lines.add("OTA_RUNTIME_HASHES");
        lines.add("(cd \"$home\"; \"$bb\" sha256sum -c runtime.sha256 >/dev/null)");
        TreeMap<String, Map<String, Object>> sorted = new TreeMap<>(Py.CODEPOINT_ORDER);
        sorted.putAll(runtime);
        for (Map.Entry<String, Map<String, Object>> e : sorted.entrySet()) {
            String name = e.getKey();
            Map<String, Object> desc = e.getValue();
            String path = "\"$root\"/" + Py.shlexQuote(name);
            lines.add("\"$bb\" mkdir -p \"$root\"/" + Py.shlexQuote(parent(name)));
            if ("file".equals(desc.get("kind"))) {
                lines.add("\"$bb\" cp \"$home/content/blobs/" + desc.get("sha256") + "\" " + path + ".new");
                lines.add("\"$bb\" chmod " + Py.oct(Json.asLong(desc.get("mode"))) + " " + path + ".new");
                lines.add("\"$bb\" mv " + path + ".new " + path);
            } else {
                lines.add("\"$bb\" ln -snf " + Py.shlexQuote((String) desc.get("target")) + " " + path);
            }
        }
        String[] tail = {"\"$bb\" rm -rf \"$home/content\"",
                "\"$bb\" mkdir -p \"$root/target\" \"$root/dev\" \"$root/proc\" \"$root/sys\" \"$root/target/dev\" \"$root/target/run\" \"$root/target/sys\"",
                "mounted \"$root/target\" || \"$bb\" mount --bind / \"$root/target\"",
                "mounted \"$root/dev\" || \"$bb\" mount --bind /dev \"$root/dev\"",
                "mounted \"$root/target/dev\" || \"$bb\" mount --bind /dev \"$root/target/dev\"",
                "mounted \"$root/target/run\" || \"$bb\" mount --bind /run \"$root/target/run\"",
                "mounted \"$root/sys\" || \"$bb\" mount --bind /sys \"$root/sys\"",
                "mounted \"$root/target/sys\" || \"$bb\" mount --bind /sys \"$root/target/sys\"",
                "mounted \"$root/proc\" || \"$bb\" mount -t proc proc \"$root/proc\"",
                "if [ \"$command\" = start ]; then printf \"%s\\n\" \"$root\" > /etc/unisoc-ota/active-runtime; fi",
                "export UNISOC_OTA_ROOT=/target UNISOC_OTA_RAM=/ UNISOC_OTA_LIVE=1 PYTHONHOME=/usr",
                "case \"$command\" in",
                " inspect) exec \"$bb\" chroot \"$root\" /usr/bin/python3 /ota/engine.py inspect \"/target$patch\" --root /target ;;",
                " start) exec \"$bb\" chroot \"$root\" /usr/bin/python3 /ota/rpc.py start \"/target$patch\" \"$id\" ;;",
                " status) exec \"$bb\" chroot \"$root\" /usr/bin/python3 /ota/rpc.py status ;;",
                " *) exit 2 ;;", "esac"};
        for (String s : tail) lines.add(s);
        return (String.join("\n", lines) + "\n").getBytes(StandardCharsets.UTF_8);
    }
}

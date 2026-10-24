package com.linote.diffstudio.core;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Port of ota_package.compare / analyze / patch_filename. */
public final class OtaPackage {
    private OtaPackage() {}

    public static final class Analysis {
        public Map<String, Object> manifest;
        public List<String> blockers = new ArrayList<>();
        public boolean canExport;
        public String suggestedName;
        public long payloadBytes;
        public int files, added, removed;
        public File output;
        public long archiveBytes;
        LinkedHashMap<String, byte[]> extra;
    }

    private static final Pattern UNSAFE = Pattern.compile("[<>:\"/\\\\|?*\\x00-\\x1f\\x7f]");

    static String safe(String text, int limit) {
        text = UNSAFE.matcher(text).replaceAll("_");
        text = Py.rstripChars(Py.strip(text), ". ");
        byte[] b = text.getBytes(StandardCharsets.UTF_8);
        if (b.length > limit) {
            int n = limit;
            // drop a partially cut UTF-8 sequence ('ignore')
            while (n > 0 && (b[n] & 0xc0) == 0x80) n--;
            text = new String(b, 0, n, StandardCharsets.UTF_8);
        }
        return Py.rstripChars(text, ". ");
    }

    private static final Pattern DATE = Pattern.compile("(?:^|-)r?(\\d{8}(?:\\.\\d{6})?)(?=-|$)");
    private static final Pattern COMMIT = Pattern.compile("(?:^|-)g([a-fA-F0-9]{7,64})(?=-|$)");
    private static final Pattern KERNEL = Pattern.compile("^\\d+(?:\\.\\d+){1,3}");

    private static String marker(Map<String, Object> meta) {
        Object v = meta.getOrDefault("image_version", "");
        String version = String.valueOf(v);
        Matcher d = DATE.matcher(version), c = COMMIT.matcher(version);
        if (d.find() && c.find()) return d.group(1) + "-g" + c.group(1).substring(0, Math.min(8, c.group(1).length())).toLowerCase(java.util.Locale.ROOT);
        return null;
    }

    public static String patchFilename(Map<String, Object> old, Map<String, Object> neu, String source) {
        String start = marker(old), end = marker(neu);
        if (start == null || end == null) {
            String leaf = source.replace('\\', '/');
            leaf = leaf.substring(leaf.lastIndexOf('/') + 1);
            String stem = leaf.toLowerCase(java.util.Locale.ROOT).endsWith(".zip") ? leaf.substring(0, leaf.length() - 4) : leaf;
            stem = safe(stem, 180);
            return "OpenWrt-patch" + (stem.isEmpty() ? "" : "-" + stem) + ".zip";
        }
        Map<String, String> models = new LinkedHashMap<>();
        String[] kv = {"e5", "E5", "t551m", "T551M", "t512n", "T512N", "m8", "M8", "yuanhang41s", "Yuanhang41S", "k1", "K1",
                "u30air", "U30Air", "mu300", "MU300-F50-V50-U30Air", "f50", "F50", "v50", "V50"};
        for (int i = 0; i < kv.length; i += 2) models.put(kv[i], kv[i + 1]);
        String profile = String.valueOf(neu.getOrDefault("profile", ""));
        String model = models.get(profile);
        if (model == null) {
            model = safe(profile, 32);
            if (model.isEmpty()) model = "Device";
        }
        String version = safe(String.valueOf(neu.getOrDefault("openwrt", "")), 24);
        String previous = safe(String.valueOf(old.getOrDefault("openwrt", "")), 24);
        if (!previous.isEmpty() && !version.isEmpty() && !previous.equals(version)) version = previous + "-to-" + version;
        Matcher k = KERNEL.matcher(String.valueOf(neu.getOrDefault("kernel_release", "")));
        List<String> parts = new ArrayList<>(java.util.Arrays.asList("OpenWrt", "patch", model));
        if (!version.isEmpty()) parts.add(version);
        if (k.find()) parts.add("k" + k.group());
        parts.add(start);
        parts.add("to");
        parts.add(end);
        return safe(String.join("-", parts), 220) + ".zip";
    }

    private static Map<String, Object> dirDesc() {
        LinkedHashMap<String, Object> d = new LinkedHashMap<>();
        d.put("kind", "dir");
        d.put("mode", 0755L);
        d.put("uid", 0L);
        d.put("gid", 0L);
        d.put("xattrs", new LinkedHashMap<String, Object>());
        return d;
    }

    @SuppressWarnings("unchecked")
    public static Analysis compare(Release old, Release neu, OtaRuntime.SupportFiles support) throws IOException {
        if (!old.family.equals(neu.family)) throw new OtaException("Packages belong to different device families");
        if (!Json.pyEquals(old.meta.get("profile"), neu.meta.get("profile"))) throw new OtaException("Incompatible full releases: profile");
        OtaRuntime.Built built = OtaRuntime.build(neu, support);
        LinkedHashMap<String, Map<String, Object>> runtime = built.runtime;
        Map<String, Object> busybox = built.busybox;
        LinkedHashMap<String, byte[]> supportBlobs = built.extra;
        boolean portable = busybox != null && runtime.containsKey("usr/bin/python3");
        if (portable) {
            for (String name : new String[]{"engine.py", "boot.py", "rpc.py", "proxy.sh"})
                neu.entries.put("usr/lib/unisoc-ota/" + name, runtime.get("ota/" + name));
            Map<String, Object> proxy = new LinkedHashMap<>(runtime.get("ota/proxy.sh"));
            proxy.put("mode", 0755L);
            neu.entries.put("usr/libexec/rpcd/unisoc-ota", proxy);
            String[][] dests = {{"unisoc-ota.js", "www/luci-static/resources/view/system/unisoc-ota.js"},
                    {"errors.js", "www/luci-static/resources/unisoc-ota/errors.js"},
                    {"unisoc-ota.json", "usr/share/rpcd/acl.d/unisoc-ota.json"}};
            for (String[] d : dests) neu.entries.put(d[1], runtime.get("ota/" + d[0]));
            for (String name : new String[]{"usr/lib/unisoc-ota", "usr/libexec", "usr/libexec/rpcd"})
                neu.entries.putIfAbsent(name, dirDesc());
        }
        List<Object> operations = new ArrayList<>();
        List<Object> preserved = new ArrayList<>();
        List<String> blockers = new ArrayList<>();
        TreeSet<String> all = new TreeSet<>(Py.CODEPOINT_ORDER);
        all.addAll(old.entries.keySet());
        all.addAll(neu.entries.keySet());
        for (String name : all) {
            Map<String, Object> before = old.entries.get(name), after = neu.entries.get(name);
            if (Json.pyEquals(before, after)) continue;
            String merge = null;
            if (name.equals("etc/e5/release.json") || name.equals("etc/mu300/release.json")) merge = "release";
            else if (name.equals("etc/passwd") || name.equals("etc/shadow") || name.equals("etc/group") || name.equals("etc/gshadow")) merge = "accounts";
            else if (name.equals("etc/apk/world")) merge = "world";
            else if (name.equals("lib/apk/db/installed")) merge = "apk-db";
            else if (name.equals("lib/apk/db/scripts.tar")) merge = "apk-scripts";
            else if (name.equals("lib/apk/db/triggers")) merge = "apk-triggers";
            else if (Ota.isProtected(name)) {
                if (name.startsWith("etc/") && before == null && Json.truthy(after) && !"dir".equals(after.get("kind"))
                        && !(name.startsWith("etc/unisoc-ota/") || name.startsWith("etc/uci-defaults/"))) {
                    merge = "default";
                } else {
                    preserved.add(name);
                    continue;
                }
            }
            if (Json.truthy(before) && "dir".equals(before.get("kind")) && !Json.truthy(after)) {
                preserved.add(name);
                continue;
            }
            LinkedHashMap<String, Object> op = new LinkedHashMap<>();
            op.put("path", name);
            op.put("before", before);
            op.put("after", after);
            if (merge != null) op.put("merge", merge);
            operations.add(op);
        }
        LinkedHashMap<String, Object> m = new LinkedHashMap<>();
        m.put("format", Ota.FORMAT);
        m.put("family", neu.family);
        m.put("profile", neu.meta.get("profile"));
        m.put("base_version", old.meta.get("image_version"));
        m.put("target_version", neu.meta.get("image_version"));
        m.put("kernel_release", neu.meta.get("kernel_release"));
        m.put("operations", operations);
        m.put("preserved", preserved);
        m.put("mode", "differential");
        m.put("base_packages", old.packages);
        m.put("target_packages", neu.packages);
        String oldBoot = old.bootDigest;
        byte[] content;
        try (InputStream in = neu.open(neu.bootName)) {
            content = Py.readUpTo(in, 128L << 20);
        }
        String newBoot = Py.sha256Hex(content);
        LinkedHashMap<String, byte[]> extra = new LinkedHashMap<>();
        if (!oldBoot.equals(newBoot)) {
            LinkedHashMap<String, Object> boot = new LinkedHashMap<>();
            boot.put("sha256", newBoot);
            boot.put("size", (long) content.length);
            m.put("boot", boot);
            extra.put(newBoot, content);
        }
        if (portable) {
            m.put("runtime", runtime);
            m.put("busybox", busybox);
            byte[] script = OtaRuntime.bootstrap(runtime);
            String h = Py.sha256Hex(script);
            LinkedHashMap<String, Object> bs = new LinkedHashMap<>();
            bs.put("sha256", h);
            bs.put("size", (long) script.length);
            m.put("bootstrap", bs);
            supportBlobs.put(h, script);
            for (Map.Entry<String, byte[]> e : supportBlobs.entrySet()) extra.putIfAbsent(e.getKey(), e.getValue());
        }
        try {
            Ota.validateManifest(m);
        } catch (OtaException e) {
            blockers.add(e.getMessage());
        }
        LinkedHashMap<String, Long> blobs = new LinkedHashMap<>();
        int added = 0, removed = 0;
        for (Object oo : operations) {
            Map<String, Object> o = (Map<String, Object>) oo;
            Map<String, Object> after = Json.map(o.get("after"));
            if (Json.truthy(after) && "file".equals(after.get("kind"))) blobs.put((String) after.get("sha256"), Json.asLong(after.get("size")));
            if (o.get("before") == null) added++;
            if (o.get("after") == null) removed++;
        }
        Map<String, Object> rt = Json.map(m.get("runtime"));
        if (rt != null) for (Object d : rt.values()) {
            Map<String, Object> dm = Json.map(d);
            if ("file".equals(dm.get("kind"))) blobs.put((String) dm.get("sha256"), Json.asLong(dm.get("size")));
        }
        for (String key : new String[]{"boot", "busybox", "bootstrap"}) {
            if (m.containsKey(key)) {
                Map<String, Object> d = Json.map(m.get(key));
                blobs.put((String) d.get("sha256"), Json.asLong(d.get("size")));
            }
        }
        Analysis a = new Analysis();
        a.manifest = m;
        a.blockers = blockers;
        a.canExport = blockers.isEmpty();
        a.suggestedName = patchFilename(old.meta, neu.meta, neu.source.displayName);
        long total = 0;
        for (long v : blobs.values()) total += v;
        a.payloadBytes = total;
        a.files = operations.size();
        a.added = added;
        a.removed = removed;
        a.extra = extra;
        return a;
    }

    /**
     * analyze(old, new, output): the old index is released before the new image is decompressed.
     * When output is non-null the verified differential archive is written there.
     */
    @SuppressWarnings("unchecked")
    public static Analysis analyze(Release.Source oldSrc, Release.Source newSrc, File output, Release.Progress progress,
                                   OtaRuntime.SupportFiles support, File scratch) throws IOException {
        Release old = new Release(oldSrc, scratch, progress);
        old.close(); // entries/meta/packages stay in memory; the scratch image is gone
        try (Release neu = new Release(newSrc, scratch, progress)) {
            Analysis result = compare(old, neu, support);
            if (output != null) {
                if (!result.blockers.isEmpty())
                    throw new OtaException(String.join("; ", result.blockers.subList(0, Math.min(12, result.blockers.size()))));
                if (output.exists()) throw new OtaException("Output already exists; select a new filename");
                File tmp = new File(output.getPath() + ".building");
                if (tmp.exists()) throw new OtaException("Output staging exists");
                try {
                    ZipOut archive = new ZipOut(tmp);
                    boolean ok = false;
                    try {
                        archive.writeBytes("manifest.json", Json.canonical(result.manifest));
                        Set<String> wanted = new LinkedHashSet<>();
                        for (Object oo : (List<Object>) result.manifest.get("operations")) {
                            Map<String, Object> after = Json.map(((Map<String, Object>) oo).get("after"));
                            if (Json.truthy(after) && "file".equals(after.get("kind"))) wanted.add((String) after.get("sha256"));
                        }
                        Map<String, Object> rt = Json.map(result.manifest.get("runtime"));
                        if (rt != null) for (Object d : rt.values()) {
                            Map<String, Object> dm = Json.map(d);
                            if ("file".equals(dm.get("kind"))) wanted.add((String) dm.get("sha256"));
                        }
                        for (Map.Entry<String, byte[]> e : result.extra.entrySet()) {
                            archive.writeBytes("blobs/" + e.getKey(), e.getValue());
                        }
                        wanted.removeAll(result.extra.keySet());
                        neu.writeBlobs(archive, wanted, progress);
                        ok = true;
                    } finally {
                        if (ok) archive.close();
                        else archive.abort();
                    }
                    progress.emit("verify", output.getName());
                    try (Ota.Patch ignored = new Ota.Patch(tmp)) {
                        // full re-verification of the written archive
                    }
                    if (!tmp.renameTo(output)) throw new OtaException("Cannot move finished patch into place");
                    result.output = output;
                    result.archiveBytes = output.length();
                } finally {
                    if (tmp.exists()) tmp.delete();
                }
            }
            return result;
        }
    }

    /** Copy helper used by bundle export. */
    static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[1 << 20];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
    }
}

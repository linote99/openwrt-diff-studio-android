package com.linote.diffstudio.core;

import java.io.Closeable;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** Port of ota_engine.py parts used on the generator / desktop side (protocol 2). */
public final class Ota {
    private Ota() {}

    public static final String FORMAT = "unisoc-diff-ota-2";
    public static final long MAX_MANIFEST = 16L << 20;
    public static final long MAX_BYTES = 2L << 30;
    public static final int MAX_FILES = 50000;
    public static final String STATE = "etc/unisoc-ota";
    private static final Pattern HEX = Pattern.compile("[0-9a-f]{64}");
    private static final Pattern VERSION = Pattern.compile("[A-Za-z0-9._+\\-]{1,180}");
    public static final String[] PROTECTED = {"lib/firmware", "lib/apk", "usr/lib/opkg", "usr/lib/apk",
            "opt/e5/vendor", "opt/e5/firmware", "opt/e5/nv", "opt/e5/android",
            "opt/mu300/vendor", "opt/mu300/firmware", "opt/mu300/nv",
            "etc/unisoc-ota", "etc/uci-defaults"};

    public static boolean isHex(Object v) {
        return v instanceof String && HEX.matcher((String) v).matches();
    }

    public static String safeName(Object o) {
        boolean bad = !(o instanceof String);
        if (!bad) {
            String name = (String) o;
            bad = name.isEmpty() || Py.pyLen(name) > 2048 || name.indexOf('\\') >= 0 || name.indexOf('\0') >= 0
                    || name.startsWith("/");
            if (!bad) for (int i = 0; i < name.length(); i++) if (name.charAt(i) < 32) { bad = true; break; }
            if (!bad) for (String p : name.split("/", -1)) if (p.isEmpty() || p.equals(".") || p.equals("..")) { bad = true; break; }
        }
        if (bad) throw new OtaException("Unsafe path: " + Py.repr(o));
        return (String) o;
    }

    public static boolean isProtected(String name) {
        safeName(name);
        String top = name.split("/", -1)[0];
        switch (top) {
            case "bin": case "sbin": case "lib": case "lib64": case "usr": case "opt": case "etc": case "www": break;
            default: return true;
        }
        if (name.startsWith("etc/") && !(name.startsWith("etc/init.d/") || name.startsWith("etc/hotplug.d/") || name.startsWith("etc/uci-defaults/")))
            return true;
        for (String p : PROTECTED) if (name.equals(p) || name.startsWith(p + "/")) return true;
        return false;
    }

    /** package_versions(raw): {P: {V, A, D}} */
    public static Map<String, Map<String, Object>> packageVersions(byte[] raw) {
        Map<String, Map<String, Object>> result = new LinkedHashMap<>();
        String text = Py.decodeUtf8Strict(raw);
        for (String paragraph : text.split("\n\n", -1)) {
            Map<Character, String> fields = new LinkedHashMap<>();
            for (String line : Py.splitlines(paragraph)) {
                if (Py.pyLen(line) > 2 && line.charAt(1) == ':' && !Character.isSurrogate(line.charAt(0))) fields.put(line.charAt(0), line.substring(2));
            }
            if (fields.containsKey('P')) {
                Map<String, Object> v = new LinkedHashMap<>();
                for (char k : new char[]{'V', 'A', 'D'}) v.put(String.valueOf(k), fields.getOrDefault(k, ""));
                result.remove(fields.get('P'));
                result.put(fields.get('P'), v);
            }
        }
        return result;
    }

    public static void validateDescriptor(Object value) {
        if (value == null) return;
        Map<String, Object> v = Json.map(value);
        Object kind = v == null ? null : v.get("kind");
        if (v == null || !("file".equals(kind) || "symlink".equals(kind) || "dir".equals(kind)))
            throw new OtaException("Invalid file descriptor");
        Object[][] limits = {{"mode", 07777L}, {"uid", 65535L}, {"gid", 65535L}};
        for (Object[] l : limits) {
            Object x = v.get(l[0]);
            if (!Json.isInt(x) || Json.asLong(x) < 0 || Json.asLong(x) > (Long) l[1])
                throw new OtaException("Invalid file permissions/ownership");
        }
        if ("file".equals(kind)) {
            Object sha = v.containsKey("sha256") ? v.get("sha256") : "";
            if (!(sha instanceof String)) throw new OtaException("TypeError: expected string or bytes-like object");
            Object size = v.get("size");
            if (!isHex(sha) || !Json.isInt(size) || Json.asLong(size) < 0 || Json.asLong(size) > MAX_BYTES)
                throw new OtaException("Invalid file hash/size");
        }
        if ("symlink".equals(kind)) {
            Object t = v.get("target");
            if (!(t instanceof String) || ((String) t).isEmpty() || Py.pyLen((String) t) > 4096 || ((String) t).indexOf('\0') >= 0)
                throw new OtaException("Invalid symbolic link");
        }
        Object xa = v.containsKey("xattrs") ? v.get("xattrs") : new LinkedHashMap<>();
        Map<String, Object> xm = Json.map(xa);
        if (xm == null) throw new OtaException("AttributeError: xattrs has no attribute 'items'");
        for (Map.Entry<String, Object> e : xm.entrySet()) {
            String name = e.getKey();
            if (!(e.getValue() instanceof String)) throw new OtaException("TypeError: argument should be a bytes-like object or ASCII string");
            if (name.isEmpty() || name.indexOf('\0') >= 0 || Py.b64decodeStrict((String) e.getValue()).length > 65536)
                throw new OtaException("Invalid extended attribute");
        }
    }

    private static boolean dictTruthy(Object o) {
        return Json.truthy(o);
    }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> validateManifest(Object mo) {
        Map<String, Object> m = Json.map(mo);
        if (m == null || !FORMAT.equals(m.get("format"))) throw new OtaException("Unsupported OTA format");
        Object fam = m.get("family");
        if (!("e5".equals(fam) || "mu300".equals(fam)) || !(m.get("profile") instanceof String))
            throw new OtaException("Invalid OTA family/profile");
        for (String k : new String[]{"base_version", "target_version", "kernel_release"}) {
            Object v = m.get(k);
            if (!(v instanceof String) || !VERSION.matcher((String) v).matches()) throw new OtaException("Invalid " + k);
        }
        if (m.get("base_version").equals(m.get("target_version"))) throw new OtaException("Release versions are identical");
        List<Object> ops = Json.list(m.get("operations"));
        if (ops == null || ops.size() > MAX_FILES || (ops.isEmpty() && !Json.truthy(m.get("boot"))))
            throw new OtaException("Empty or excessive OTA operations");
        Set<String> seen = new HashSet<>();
        Map<String, Map<String, Object>> firstByPath = new LinkedHashMap<>();
        for (Object oo : ops) {
            Map<String, Object> op = Json.map(oo);
            if (op == null) throw new OtaException("TypeError: operation must be an object");
            if (!op.containsKey("path")) throw new OtaException("KeyError: 'path'");
            String name = safeName(op.get("path"));
            Object merge = op.get("merge");
            boolean special = ("apk-db".equals(merge) && name.equals("lib/apk/db/installed"))
                    || ("apk-scripts".equals(merge) && name.equals("lib/apk/db/scripts.tar"))
                    || ("apk-triggers".equals(merge) && name.equals("lib/apk/db/triggers"))
                    || ("release".equals(merge) && (name.equals("etc/e5/release.json") || name.equals("etc/mu300/release.json")))
                    || ("accounts".equals(merge) && (name.equals("etc/passwd") || name.equals("etc/shadow") || name.equals("etc/group") || name.equals("etc/gshadow")))
                    || ("world".equals(merge) && name.equals("etc/apk/world"))
                    || ("default".equals(merge) && name.startsWith("etc/") && !(name.startsWith("etc/unisoc-ota/") || name.startsWith("etc/uci-defaults/")));
            if (merge != null && !special) throw new OtaException("Invalid merge operation");
            if (seen.contains(name) || (isProtected(name) && !special)) throw new OtaException("Duplicate/protected OTA path: " + name);
            seen.add(name);
            firstByPath.putIfAbsent(name, op);
            Object before = op.get("before"), after = op.get("after");
            validateDescriptor(before);
            validateDescriptor(after);
            if (Json.pyEquals(before, after) || (before == null && after == null)) throw new OtaException("Redundant operation");
            if (dictTruthy(before) && "dir".equals(Json.map(before).get("kind")) && (!dictTruthy(after) || !"dir".equals(Json.map(after).get("kind"))))
                throw new OtaException("Directory removal/type change is not supported: " + name);
        }
        for (String name : seen) {
            String p = name;
            while (p.contains("/")) {
                p = p.substring(0, p.lastIndexOf('/'));
                if (seen.contains(p)) {
                    Map<String, Object> op = firstByPath.get(p);
                    if (!op.containsKey("after")) throw new OtaException("KeyError: 'after'");
                    Object a = op.get("after");
                    if (!dictTruthy(a) || !"dir".equals(Json.map(a).get("kind")))
                        throw new OtaException("Operation below a non-directory: " + name);
                }
            }
        }
        for (String key : new String[]{"boot", "busybox", "bootstrap"}) {
            if (m.containsKey(key)) {
                Map<String, Object> v = Json.map(m.get(key));
                Object sha = v == null ? null : (v.containsKey("sha256") ? v.get("sha256") : "");
                Object size = v == null ? null : v.get("size");
                if (v == null || !isHex(sha) || !Json.isInt(size) || Json.asLong(size) <= 0 || Json.asLong(size) > MAX_BYTES)
                    throw new OtaException("Invalid " + key + " payload");
            }
        }
        Object rt = m.containsKey("runtime") ? m.get("runtime") : new LinkedHashMap<>();
        Map<String, Object> runtime = Json.map(rt);
        if (runtime == null) throw new OtaException("AttributeError: runtime has no attribute 'items'");
        for (Map.Entry<String, Object> e : runtime.entrySet()) {
            String name = safeName(e.getKey());
            String top = name.split("/", -1)[0];
            if (!(top.equals("lib") || top.equals("lib64") || top.equals("usr") || top.equals("ota")))
                throw new OtaException("Invalid runtime path");
            validateDescriptor(e.getValue());
            if (e.getValue() == null || "dir".equals(Json.map(e.getValue()).get("kind"))) throw new OtaException("Invalid runtime entry");
        }
        return m;
    }

    public interface BlobProgress {
        void onBlob(int done, int total);
    }

    /** ota_engine.Patch: validated, checksum-verified differential archive. */
    public static final class Patch implements Closeable {
        public final ZipIn archive;
        public final Map<String, Object> manifest;
        public final String id;

        public Patch(File path) throws IOException {
            this(path, null);
        }

        @SuppressWarnings("unchecked")
        public Patch(File path, BlobProgress progress) throws IOException {
            archive = ZipIn.open(path);
            try {
                List<String> names = archive.namelist();
                if (names.size() != new HashSet<>(names).size() || names.size() > MAX_FILES + 1)
                    throw new OtaException("Duplicate/excessive ZIP entries");
                ZipIn.Entry info = archive.getinfo("manifest.json");
                if (info.size > MAX_MANIFEST) throw new OtaException("OTA manifest too large");
                byte[] raw;
                try (InputStream in = archive.open(info)) {
                    raw = Py.readAll(in);
                }
                manifest = validateManifest(Json.parse(raw));
                id = Py.sha256Hex(Json.canonical(manifest));
                Map<String, Long> blobs = new LinkedHashMap<>();
                for (Object oo : (List<Object>) manifest.get("operations")) {
                    Map<String, Object> after = Json.map(Json.map(oo).get("after"));
                    if (Json.truthy(after) && "file".equals(after.get("kind")))
                        blobs.put((String) after.get("sha256"), Json.asLong(after.get("size")));
                }
                Map<String, Object> runtime = Json.map(manifest.get("runtime"));
                if (runtime != null) for (Object d : runtime.values()) {
                    Map<String, Object> dm = Json.map(d);
                    if ("file".equals(dm.get("kind"))) blobs.put((String) dm.get("sha256"), Json.asLong(dm.get("size")));
                }
                for (String key : new String[]{"boot", "busybox", "bootstrap"}) {
                    if (manifest.containsKey(key)) {
                        Map<String, Object> d = Json.map(manifest.get(key));
                        blobs.put((String) d.get("sha256"), Json.asLong(d.get("size")));
                    }
                }
                Set<String> expected = new HashSet<>();
                expected.add("manifest.json");
                for (String h : blobs.keySet()) expected.add("blobs/" + h);
                if (!new HashSet<>(names).equals(expected)) throw new OtaException("Unexpected or missing archive entries");
                long total = 0;
                for (long s : blobs.values()) total += s;
                if (total > MAX_BYTES) throw new OtaException("OTA exceeds expanded size limit");
                int done = 0;
                for (Map.Entry<String, Long> b : blobs.entrySet()) {
                    ZipIn.Entry e = archive.getinfo("blobs/" + b.getKey());
                    if (e.size != b.getValue() || (e.flags & 1) != 0) throw new OtaException("Invalid encrypted blob or length");
                    try (InputStream in = archive.open(e)) {
                        if (!Py.digest(in).equals(b.getKey())) throw new OtaException("OTA content checksum mismatch: " + b.getKey());
                    }
                    if (progress != null) progress.onBlob(++done, blobs.size());
                }
            } catch (IOException | RuntimeException e) {
                archive.close();
                throw e;
            }
        }

        public byte[] blob(String sha) throws IOException {
            return archive.read("blobs/" + sha);
        }

        @Override
        public void close() throws IOException {
            archive.close();
        }
    }
}

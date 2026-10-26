package com.linote.diffstudio.core;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Port of release_index.py (desktop 2026-10-26): portable, content-checked release baselines.
 * An index holds a release's identity, file table, package versions and boot hash, but no payload
 * or device data. It can stand in for the old full release when generating the next patch.
 */
public final class ReleaseIndex {
    private ReleaseIndex() {}

    public static final String FORMAT = "openwrt-release-index";
    public static final String SUFFIX = ".owrt-index.json";
    public static final long MAX_SIZE = 64L << 20;

    /** The attributes compare() reads from the old release; a full Release or a loaded index. */
    public static final class Base {
        public final String family;
        public final Map<String, Object> meta;
        public final Map<String, Map<String, Object>> entries;
        public final Map<String, Map<String, Object>> packages;
        public final String bootDigest;

        Base(String family, Map<String, Object> meta, Map<String, Map<String, Object>> entries,
             Map<String, Map<String, Object>> packages, String bootDigest) {
            this.family = family;
            this.meta = meta;
            this.entries = entries;
            this.packages = packages;
            this.bootDigest = bootDigest;
        }

        public static Base of(Release r) {
            return new Base(r.family, r.meta, r.entries, r.packages, r.bootDigest);
        }
    }

    private static final Pattern PROFILE = Pattern.compile("[a-z0-9][a-z0-9_-]{0,63}");
    private static final Pattern HEX64 = Pattern.compile("[a-f0-9]{64}");
    private static final Set<String> TOP = new HashSet<>(Arrays.asList("format", "version", "sha256", "release"));
    private static final Set<String> RELEASE = new HashSet<>(Arrays.asList("family", "meta", "entries", "packages", "boot_digest"));
    private static final Set<String> META = new HashSet<>(Arrays.asList("profile", "image_version", "kernel_release", "openwrt"));
    private static final Set<String> DESC = new HashSet<>(Arrays.asList("kind", "mode", "uid", "gid", "size", "sha256", "target", "xattrs"));
    private static final Set<String> VAD = new HashSet<>(Arrays.asList("V", "A", "D"));

    private static boolean idString(Object v) {
        if (!(v instanceof String)) return false;
        String s = (String) v;
        if (s.isEmpty() || Py.pyLen(s) > 256) return false;
        for (int i = 0; i < s.length(); i++) if (s.charAt(i) < 32) return false;
        return true;
    }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> validate(Object value) {
        Map<String, Object> data = value instanceof Map ? (Map<String, Object>) value : null;
        if (data == null || !data.keySet().equals(TOP) || !FORMAT.equals(data.get("format"))
                || !Json.isInt(data.get("version")) || !Json.pyEquals(data.get("version"), 1L))
            throw new OtaException("Unsupported release index / 不支持的版本摘要格式");
        Object ro = data.get("release");
        Map<String, Object> release = ro instanceof Map ? (Map<String, Object>) ro : null;
        if (release == null || !release.keySet().equals(RELEASE))
            throw new OtaException("Incomplete release index / 版本摘要不完整");
        if (!Py.sha256Hex(Json.canonical(release)).equals(data.get("sha256")))
            throw new OtaException("Release index checksum mismatch / 版本摘要校验失败");
        Object family = release.get("family");
        if (!"e5".equals(family) && !"mu300".equals(family))
            throw new OtaException("Invalid release index family");
        Object mo = release.get("meta");
        Map<String, Object> meta = mo instanceof Map ? (Map<String, Object>) mo : null;
        boolean metaOk = meta != null && meta.keySet().equals(META);
        if (metaOk) for (Object v : meta.values()) if (!idString(v)) { metaOk = false; break; }
        if (!metaOk) throw new OtaException("Invalid release index identity");
        Object boot = release.get("boot_digest");
        if (!PROFILE.matcher((String) meta.get("profile")).matches() || !(boot instanceof String) || !HEX64.matcher((String) boot).matches())
            throw new OtaException("Invalid release index profile/boot hash");
        Object eo = release.get("entries");
        Map<String, Object> entries = eo instanceof Map ? (Map<String, Object>) eo : null;
        if (entries == null || entries.isEmpty() || entries.size() > 250000)
            throw new OtaException("Invalid release index file table");
        for (Map.Entry<String, Object> e : entries.entrySet()) {
            Ota.safeName(e.getKey());
            Object d = e.getValue();
            Map<String, Object> desc = d instanceof Map ? (Map<String, Object>) d : null;
            if (desc == null || !(desc.containsKey("xattrs") ? desc.get("xattrs") instanceof Map : true) || !DESC.containsAll(desc.keySet()))
                throw new OtaException("Invalid release index descriptor");
            Ota.validateDescriptor(desc);
        }
        Object po = release.get("packages");
        Map<String, Object> packages = po instanceof Map ? (Map<String, Object>) po : null;
        boolean pkgOk = packages != null;
        if (pkgOk) for (Map.Entry<String, Object> e : packages.entrySet()) {
            String k = e.getKey();
            Object v = e.getValue();
            if (k.isEmpty() || Py.pyLen(k) > 256 || !(v instanceof Map) || !((Map<String, Object>) v).keySet().equals(VAD)) { pkgOk = false; break; }
            for (Object x : ((Map<String, Object>) v).values()) {
                if (!(x instanceof String) || Py.pyLen((String) x) > 65536) { pkgOk = false; break; }
            }
            if (!pkgOk) break;
        }
        if (!pkgOk) throw new OtaException("Invalid release index packages");
        return data;
    }

    /** snapshot(release): must run after compare(), which adds the updater files this generator ships. */
    public static Map<String, Object> snapshot(Release release) {
        LinkedHashMap<String, Object> meta = new LinkedHashMap<>();
        for (String k : new String[]{"profile", "image_version", "kernel_release", "openwrt"}) {
            if (release.meta == null || !release.meta.containsKey(k)) throw new OtaException("KeyError: '" + k + "'");
            meta.put(k, release.meta.get(k));
        }
        LinkedHashMap<String, Object> body = new LinkedHashMap<>();
        body.put("family", release.family);
        body.put("meta", meta);
        body.put("entries", release.entries);
        body.put("packages", release.packages);
        body.put("boot_digest", release.bootDigest);
        LinkedHashMap<String, Object> data = new LinkedHashMap<>();
        data.put("format", FORMAT);
        data.put("version", 1L);
        data.put("sha256", Py.sha256Hex(Json.canonical(body)));
        data.put("release", body);
        return validate(data);
    }

    public static Map<String, Object> readIndex(InputStream in) throws IOException {
        byte[] raw = Py.readUpTo(in, MAX_SIZE + 1);
        if (raw.length > MAX_SIZE) throw new OtaException("Release index exceeds 64 MiB");
        try {
            return validate(Json.parseUnique(raw));
        } catch (OtaException e) {
            String m = String.valueOf(e.getMessage());
            if (m.startsWith("UnicodeDecodeError")) throw new OtaException("Invalid release index / 版本摘要损坏");
            throw e;
        } catch (ClassCastException | NullPointerException | IllegalArgumentException | StackOverflowError e) {
            throw new OtaException("Invalid release index / 版本摘要损坏");
        }
    }

    public static Map<String, Object> readIndex(File path) throws IOException {
        try (InputStream in = new FileInputStream(path)) {
            return readIndex(in);
        }
    }

    @SuppressWarnings("unchecked")
    public static Base load(InputStream in) throws IOException {
        Map<String, Object> release = (Map<String, Object>) readIndex(in).get("release");
        Map<String, Map<String, Object>> entries = new LinkedHashMap<>();
        for (Map.Entry<String, Object> e : ((Map<String, Object>) release.get("entries")).entrySet())
            entries.put(e.getKey(), (Map<String, Object>) e.getValue());
        Map<String, Map<String, Object>> packages = new LinkedHashMap<>();
        for (Map.Entry<String, Object> e : ((Map<String, Object>) release.get("packages")).entrySet())
            packages.put(e.getKey(), (Map<String, Object>) e.getValue());
        return new Base((String) release.get("family"), (Map<String, Object>) release.get("meta"), entries, packages,
                (String) release.get("boot_digest"));
    }

    /** canonical(data) + b'\n' */
    public static byte[] serialize(Map<String, Object> data) {
        validate(data);
        byte[] c = Json.canonical(data);
        byte[] raw = Arrays.copyOf(c, c.length + 1);
        raw[c.length] = '\n';
        if (raw.length > MAX_SIZE) throw new OtaException("Release index exceeds 64 MiB");
        return raw;
    }

    public static File writeIndex(File path, Map<String, Object> data, boolean reuse) throws IOException {
        byte[] raw = serialize(data);
        File dir = path.getAbsoluteFile().getParentFile();
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        if (path.exists()) {
            if (reuse && Json.pyEquals(readIndex(path), data)) return path;
            throw new OtaException("Release index destination already exists / 版本摘要目标文件已存在: " + path);
        }
        File temp = File.createTempFile(".release-index-", null, dir);
        try {
            try (FileOutputStream out = new FileOutputStream(temp)) {
                out.write(raw);
                out.flush();
                out.getFD().sync();
            }
            if (!temp.renameTo(path)) throw new OtaException("Cannot move release index into place");
        } finally {
            if (temp.exists()) //noinspection ResultOfMethodCallIgnored
                temp.delete();
        }
        return path;
    }

    public static File saveIndex(Release release, File directory) throws IOException {
        Map<String, Object> data = snapshot(release);
        String version = String.valueOf(release.meta.get("image_version"));
        String label = version.replaceAll("[^A-Za-z0-9._-]", "_");
        if (label.length() > 100) label = label.substring(0, 100);
        File path = new File(directory, "OpenWrt-" + label + "-" + data.get("sha256") + SUFFIX);
        return writeIndex(path, data, true);
    }
}

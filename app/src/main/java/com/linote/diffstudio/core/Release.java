package com.linote.diffstudio.core;

import java.io.Closeable;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.nio.channels.FileChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.GZIPInputStream;

/** Port of ota_package.Release: index a full E5/MU300 release ZIP without mounting. */
public final class Release implements Closeable {
    public interface Progress {
        void emit(String stage, String path);
    }

    /** A random-access release ZIP plus its user-visible name (used for patch naming). */
    public static final class Source {
        public final FileChannel channel;
        public final String displayName;
        public final Closeable owner;

        public Source(FileChannel channel, String displayName, Closeable owner) {
            this.channel = channel;
            this.displayName = displayName;
            this.owner = owner;
        }
    }

    public final Source source;
    private final File scratch;
    private final Progress progress;
    private ZipIn files;
    private String prefix;
    private Set<String> nameSet;

    public String family;
    public Map<String, Object> meta;
    public Map<String, Object> pkg;
    public String bootName;
    public String rootfsName;
    public String bootDigest;
    /** entries: name -> descriptor (insertion ordered) */
    public final LinkedHashMap<String, Map<String, Object>> entries = new LinkedHashMap<>();
    public Map<String, Map<String, Object>> packages = new LinkedHashMap<>();
    public byte[] packageDb = new byte[0];

    private Ext4 extfs;
    private File image;
    private RandomAccessFile imageRaf;
    private final Map<String, Long> extInum = new HashMap<>();

    public Release(Source source, File scratch, Progress progress) throws IOException {
        this.source = source;
        this.scratch = scratch;
        this.progress = progress == null ? (a, b) -> { } : progress;
        try {
            load();
        } catch (IOException | RuntimeException e) {
            close();
            throw e;
        }
    }

    private static Map<String, Object> newDesc(long mode, long uid, long gid) {
        LinkedHashMap<String, Object> d = new LinkedHashMap<>();
        d.put("mode", mode);
        d.put("uid", uid);
        d.put("gid", gid);
        d.put("xattrs", new LinkedHashMap<String, Object>());
        return d;
    }

    @SuppressWarnings("unchecked")
    private void load() throws IOException {
        files = new ZipIn(source.channel, null);
        List<String> names = files.namelist();
        nameSet = new HashSet<>(names);
        if (names.size() != nameSet.size()) throw new OtaException("Duplicate files in full package");
        List<String> matches = new ArrayList<>();
        for (String n : names) if (n.endsWith("files/device-profile.json")) matches.add(n.substring(0, n.length() - "files/device-profile.json".length()));
        for (String n : names) if (n.endsWith("desktop/manifest.json")) matches.add(n.substring(0, n.length() - "desktop/manifest.json".length()));
        if (matches.size() != 1) throw new OtaException("Select a single complete release ZIP");
        prefix = matches.get(0);
        if (exists("desktop/manifest.json")) {
            family = "mu300";
            meta = Json.map(json("desktop/release.json"));
            pkg = Json.map(json("desktop/manifest.json"));
            if (meta == null || pkg == null) throw new OtaException("AttributeError: release metadata is not an object");
            Map<String, Object> mapping = pkg.containsKey("magisk_layout") ? Json.map(pkg.get("magisk_layout")) : new LinkedHashMap<>();
            if (mapping == null) throw new OtaException("AttributeError: magisk_layout is not an object");
            String rootfs = String.valueOf(mapping.getOrDefault("mu300-openwrt.tar.gz", "mu300-openwrt.tar.gz"));
            bootName = String.valueOf(mapping.getOrDefault("boot-linux.img", "boot-linux.img"));
            if (!pkg.containsKey("magisk")) throw new OtaException("KeyError: 'magisk'");
            if (!pkg.containsKey("desktop")) throw new OtaException("KeyError: 'desktop'");
            Map<String, Object> checks = new LinkedHashMap<>(Json.map(pkg.get("magisk")));
            checks.putAll(Json.map(pkg.get("desktop")));
            check(rootfs, need(checks, rootfs));
            check(bootName, need(checks, bootName));
            if (checks.containsKey("desktop/release.json")) check("desktop/release.json", checks.get("desktop/release.json"));
            try (InputStream raw = open(rootfs); GZIPInputStream gz = new GZIPInputStream(raw, 1 << 16)) {
                TarIn tar = new TarIn(gz);
                TarIn.Node node;
                while ((node = tar.next()) != null) {
                    String name = node.name.startsWith("./") ? node.name.substring(2) : node.name;
                    name = Py.rstripChars(name, "/");
                    if (name.isEmpty() || name.equals(".")) continue;
                    Ota.safeName(name);
                    if (entries.containsKey(name)) throw new OtaException("Duplicate rootfs path: " + name);
                    Map<String, Object> d = newDesc(node.mode, node.uid, node.gid);
                    Map<String, Object> xattrs = (Map<String, Object>) d.get("xattrs");
                    for (Map.Entry<String, byte[]> e : node.pax.entrySet()) {
                        if (e.getKey().startsWith("SCHILY.xattr.")) {
                            String k = e.getKey().substring(13);
                            xattrs.remove(k);
                            xattrs.put(k, Py.b64encode(e.getValue()));
                        }
                    }
                    if (node.isDir()) {
                        d.put("kind", "dir");
                    } else if (node.isSym()) {
                        d.put("kind", "symlink");
                        d.put("target", node.linkname);
                    } else if (node.isFile()) {
                        InputStream stream = tar.content();
                        if (name.equals("lib/apk/db/installed")) {
                            byte[] raw2 = Py.readUpTo(stream, 32L << 20);
                            if (raw2.length != node.size) throw new OtaException("Oversized package database");
                            packageDb = raw2;
                            packages = Ota.packageVersions(raw2);
                            d.put("kind", "file");
                            d.put("size", node.size);
                            d.put("sha256", Py.sha256Hex(raw2));
                        } else {
                            d.put("kind", "file");
                            d.put("size", node.size);
                            d.put("sha256", Py.digest(stream));
                        }
                    } else if (node.isLnk()) {
                        String target = node.linkname.startsWith("./") ? node.linkname.substring(2) : node.linkname;
                        Map<String, Object> t = entries.get(target);
                        if (t == null || !"file".equals(t.get("kind"))) throw new OtaException("Unsupported forward tar hardlink: " + name);
                        d = new LinkedHashMap<>(t);
                    } else {
                        continue;
                    }
                    entries.put(name, d);
                    progress.emit("index", name);
                }
            }
            rootfsName = rootfs;
        } else {
            family = "e5";
            meta = Json.map(json("files/RELEASE.json"));
            pkg = Json.map(json("files/device-profile.json"));
            if (meta == null) throw new OtaException("AttributeError: release metadata is not an object");
            Map<String, Object> checks = new LinkedHashMap<>();
            byte[] sums;
            try (InputStream in = open("files/SHA256SUMS")) {
                sums = Py.readAll(in);
            }
            for (String line : Py.splitlines(Py.decodeUtf8Strict(sums))) {
                List<String> parts = Py.splitWhitespace(line, 1);
                if (parts.size() != 2) throw new OtaException("not enough values to unpack (expected 2, got " + parts.size() + ")");
                String n = Py.strip(parts.get(1));
                if (n.startsWith("*")) n = n.substring(1);
                checks.remove(n);
                checks.put(n, parts.get(0));
            }
            bootName = "files/boot.img";
            rootfsName = "files/openwrt.ext4.gz";
            check(rootfsName, need(checks, rootfsName));
            check(bootName, need(checks, bootName));
            for (String name : new String[]{"files/RELEASE.json", "files/device-profile.json"}) {
                if (checks.containsKey(name)) check(name, checks.get(name));
            }
            image = File.createTempFile("tmp", null, scratch);
            image.deleteOnExit();
            imageRaf = new RandomAccessFile(image, "rw");
            try (InputStream compressed = open(rootfsName); GZIPInputStream gz = new GZIPInputStream(compressed, 1 << 16)) {
                long total = 0;
                byte[] block = new byte[4 << 20];
                while (true) {
                    int got = 0;
                    while (got < block.length) {
                        int n = gz.read(block, got, block.length - got);
                        if (n < 0) break;
                        got += n;
                    }
                    if (got == 0) break;
                    total += got;
                    if (total > 16L << 30) throw new OtaException("Root image exceeds 16 GiB");
                    if (scratch.getUsableSpace() < got + (64L << 20)) throw new OtaException("Insufficient temporary disk space");
                    imageRaf.write(block, 0, got);
                    progress.emit("decompress", rootfsName);
                    if (got < block.length) break;
                }
            }
            extfs = new Ext4(imageRaf.getChannel());
            walk(extfs.root(), "", new HashSet<>());
        }
        try (InputStream in = open(bootName)) {
            bootDigest = Py.digest(in);
        }
        for (String k : new String[]{"image_version", "profile", "kernel_release", "openwrt"}) {
            if (!(meta.get(k) instanceof String)) throw new OtaException("Full release has no versioned " + k);
        }
    }

    private static Object need(Map<String, Object> m, String key) {
        if (!m.containsKey(key)) throw new OtaException("KeyError: " + Py.repr(key));
        return m.get(key);
    }

    @SuppressWarnings("unchecked")
    private void walk(Ext4.Inode node, String prefix, Set<Long> seen) throws IOException {
        if (seen.contains(node.inum)) throw new OtaException("Cyclic ext4 directory");
        seen.add(node.inum);
        for (Ext4.Inode child : node.iterdir()) {
            if (child.filename.equals(".") || child.filename.equals("..")) continue;
            String name = Ota.safeName(prefix + child.filename);
            Map<String, Object> d = newDesc(child.mode & 07777, child.uidLow, child.gidLow);
            Map<String, Object> xattrs = (Map<String, Object>) d.get("xattrs");
            for (Object[] a : child.xattrs()) {
                xattrs.remove((String) a[0]);
                xattrs.put((String) a[0], Py.b64encode((byte[]) a[1]));
            }
            int ft = child.filetype();
            if (ft == Ext4.S_IFDIR) {
                d.put("kind", "dir");
            } else if (ft == Ext4.S_IFLNK) {
                d.put("kind", "symlink");
                d.put("target", child.link());
            } else if (ft == Ext4.S_IFREG) {
                try (InputStream f = child.open()) {
                    d.put("kind", "file");
                    d.put("size", child.size);
                    d.put("sha256", Py.digest(f));
                }
                if (name.equals("lib/apk/db/installed")) {
                    try (InputStream f = child.open()) {
                        packageDb = Py.readUpTo(f, 32L << 20);
                    }
                    packages = Ota.packageVersions(packageDb);
                }
            } else {
                continue;
            }
            entries.put(name, d);
            extInum.putIfAbsent(name, child.inum);
            progress.emit("index", name);
            if ("dir".equals(d.get("kind"))) walk(child, name + "/", seen);
        }
        seen.remove(node.inum);
    }

    public boolean exists(String name) {
        return nameSet.contains(prefix + name);
    }

    public InputStream open(String name) throws IOException {
        Ota.safeName(name);
        return files.open(prefix + name);
    }

    public Object json(String name) throws IOException {
        try (InputStream in = open(name)) {
            return Json.parse(Py.readAll(in));
        }
    }

    public void check(String name, Object wanted) throws IOException {
        try (InputStream in = open(name)) {
            if (!Py.digest(in).equals(wanted)) throw new OtaException("Full package checksum mismatch: " + name);
        }
    }

    private static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[1 << 20];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
    }

    /** write_blobs(archive, wanted) */
    public void writeBlobs(ZipOut archive, Set<String> wanted, Progress p) throws IOException {
        Set<String> pending = new java.util.LinkedHashSet<>(wanted);
        if (extfs != null) {
            for (Map.Entry<String, Map<String, Object>> e : entries.entrySet()) {
                Object sha = e.getValue().get("sha256");
                if (sha != null && pending.contains(sha)) {
                    Long inum = extInum.get(e.getKey());
                    Ext4.Inode node = resolve(e.getKey(), inum);
                    try (InputStream src = node.open(); OutputStream dst = archive.openEntry("blobs/" + sha)) {
                        copy(src, dst);
                    }
                    pending.remove(sha);
                    p.emit("write", e.getKey());
                }
            }
        } else {
            try (InputStream raw = open(rootfsName); GZIPInputStream gz = new GZIPInputStream(raw, 1 << 16)) {
                TarIn tar = new TarIn(gz);
                TarIn.Node node;
                while ((node = tar.next()) != null) {
                    String name = node.name.startsWith("./") ? node.name.substring(2) : node.name;
                    name = Py.rstripChars(name, "/");
                    Map<String, Object> d = entries.get(name);
                    Object sha = d == null ? null : d.get("sha256");
                    if (sha == null || !pending.contains(sha) || !node.isFile()) continue;
                    try (OutputStream dst = archive.openEntry("blobs/" + sha)) {
                        copy(tar.content(), dst);
                    }
                    pending.remove(sha);
                    p.emit("write", name);
                }
            }
        }
        if (!pending.isEmpty()) throw new OtaException("Cannot find payload content: " + String.join(", ", pending));
    }

    private Ext4.Inode resolve(String name, Long inum) throws IOException {
        if (inum != null) return extfs.inode(inum);
        throw new OtaException("FileNotFoundError: " + name);
    }

    @Override
    public void close() throws IOException {
        try {
            if (imageRaf != null) imageRaf.close();
        } finally {
            if (image != null) image.delete();
            if (source.owner != null) source.owner.close();
            else source.channel.close();
        }
    }
}

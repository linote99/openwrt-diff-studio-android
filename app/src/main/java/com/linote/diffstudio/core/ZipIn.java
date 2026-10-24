package com.linote.diffstudio.core;

import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.CRC32;
import java.util.zip.DataFormatException;
import java.util.zip.Inflater;

/** Random-access ZIP reader mirroring Python zipfile.ZipFile read semantics. */
public final class ZipIn implements Closeable {
    public static final class Entry {
        public String name;
        public int flags;
        public int method;
        public long crc;
        public long compressedSize;
        public long size;
        public long headerOffset;
    }

    private final FileChannel ch;
    private final Closeable owner;
    private final List<Entry> entries = new ArrayList<>();
    private final Map<String, Entry> byName = new HashMap<>();
    private final List<String> names = new ArrayList<>();

    public ZipIn(FileChannel ch, Closeable owner) throws IOException {
        this.ch = ch;
        this.owner = owner;
        try {
            readCentral();
        } catch (IOException | RuntimeException e) {
            close();
            throw e;
        }
    }

    public static ZipIn open(java.io.File file) throws IOException {
        java.io.RandomAccessFile raf = new java.io.RandomAccessFile(file, "r");
        return new ZipIn(raf.getChannel(), raf);
    }

    public List<String> namelist() {
        return Collections.unmodifiableList(names);
    }

    public List<Entry> entries() {
        return Collections.unmodifiableList(entries);
    }

    public Entry getinfo(String name) {
        Entry e = byName.get(name);
        if (e == null) throw new OtaException("KeyError: \"There is no item named " + Py.repr(name) + " in the archive\"");
        return e;
    }

    public boolean has(String name) {
        return byName.containsKey(name);
    }

    private ByteBuffer read(long pos, int len) throws IOException {
        ByteBuffer b = ByteBuffer.allocate(len).order(ByteOrder.LITTLE_ENDIAN);
        while (b.hasRemaining()) {
            int n = ch.read(b, pos + b.position());
            if (n < 0) throw new EOFException();
        }
        b.flip();
        return b;
    }

    private static final Charset CP437 = cp437();

    private static Charset cp437() {
        try {
            return Charset.forName("IBM437");
        } catch (Exception e) {
            return StandardCharsets.ISO_8859_1;
        }
    }

    private void readCentral() throws IOException {
        long fsize = ch.size();
        if (fsize < 22) throw new OtaException("BadZipFile: File is not a zip file");
        long eocd = -1;
        ByteBuffer tail = read(fsize - 22, 22);
        if (tail.getInt(0) == 0x06054b50 && tail.getShort(20) == 0) {
            eocd = fsize - 22;
        } else {
            int maxComment = (int) Math.min(fsize, 65535 + 22);
            ByteBuffer area = read(fsize - maxComment, maxComment);
            for (int i = maxComment - 22; i >= 0; i--) {
                if (area.getInt(i) == 0x06054b50) { eocd = fsize - maxComment + i; break; }
            }
        }
        if (eocd < 0) throw new OtaException("BadZipFile: File is not a zip file");
        ByteBuffer e = read(eocd, 22);
        long count = e.getShort(10) & 0xffff;
        long cdSize = e.getInt(12) & 0xffffffffL;
        long cdOffset = e.getInt(16) & 0xffffffffL;
        long location = eocd;
        boolean zip64 = false;
        if (eocd >= 20) {
            ByteBuffer loc = read(eocd - 20, 20);
            if (loc.getInt(0) == 0x07064b50) {
                long z64 = loc.getLong(8);
                ByteBuffer z = read(eocd - 20 - 56, 56);
                if (z.getInt(0) == 0x06064b50) {
                    count = z.getLong(32);
                    cdSize = z.getLong(40);
                    cdOffset = z.getLong(48);
                    location = eocd - 20 - 56;
                    zip64 = true;
                } else if (z64 >= 0) {
                    throw new OtaException("BadZipFile: Corrupt zip64 end of central directory locator");
                }
            }
        }
        long concat = location - cdSize - cdOffset;
        if (concat < 0) throw new OtaException("BadZipFile: Bad offset for central directory");
        long pos = cdOffset + concat;
        long end = pos + cdSize;
        if (cdSize > 512L << 20) throw new OtaException("BadZipFile: central directory too large");
        ByteBuffer cd = read(pos, (int) cdSize);
        int p = 0;
        while (p < cdSize) {
            if (p + 46 > cdSize || cd.getInt(p) != 0x02014b50) throw new OtaException("BadZipFile: Bad magic number for central directory");
            Entry en = new Entry();
            en.flags = cd.getShort(p + 8) & 0xffff;
            en.method = cd.getShort(p + 10) & 0xffff;
            en.crc = cd.getInt(p + 16) & 0xffffffffL;
            en.compressedSize = cd.getInt(p + 20) & 0xffffffffL;
            en.size = cd.getInt(p + 24) & 0xffffffffL;
            int nlen = cd.getShort(p + 28) & 0xffff;
            int xlen = cd.getShort(p + 30) & 0xffff;
            int clen = cd.getShort(p + 32) & 0xffff;
            en.headerOffset = cd.getInt(p + 42) & 0xffffffffL;
            byte[] nb = new byte[nlen];
            cd.position(p + 46);
            cd.get(nb);
            String name = (en.flags & 0x800) != 0 ? Py.decodeUtf8Strict(nb) : new String(nb, CP437);
            int nul = name.indexOf('\0');
            if (nul >= 0) name = name.substring(0, nul);
            // The original runs on Windows: zipfile converts os.sep to '/'.
            name = name.replace('\\', '/');
            en.name = name;
            // zip64 extra
            int xp = p + 46 + nlen, xend = xp + xlen;
            while (xp + 4 <= xend) {
                int id = cd.getShort(xp) & 0xffff, ln = cd.getShort(xp + 2) & 0xffff;
                if (id == 1) {
                    int q = xp + 4;
                    if (en.size == 0xffffffffL && q + 8 <= xp + 4 + ln) { en.size = cd.getLong(q); q += 8; }
                    if (en.compressedSize == 0xffffffffL && q + 8 <= xp + 4 + ln) { en.compressedSize = cd.getLong(q); q += 8; }
                    if (en.headerOffset == 0xffffffffL && q + 8 <= xp + 4 + ln) { en.headerOffset = cd.getLong(q); }
                }
                xp += 4 + ln;
            }
            en.headerOffset += concat;
            entries.add(en);
            names.add(name);
            byName.put(name, en);
            p += 46 + nlen + xlen + clen;
        }
        if (!zip64 && count != entries.size() && count != 0xffff) {
            // zipfile does not enforce the count; keep parity.
        }
        if (end > fsize) throw new OtaException("BadZipFile: Truncated central directory");
    }

    public InputStream open(String name) throws IOException {
        return open(getinfo(name));
    }

    public InputStream open(Entry en) throws IOException {
        ByteBuffer lh = read(en.headerOffset, 30);
        if (lh.getInt(0) != 0x04034b50) throw new OtaException("BadZipFile: Bad magic number for file header");
        int nlen = lh.getShort(26) & 0xffff, xlen = lh.getShort(28) & 0xffff;
        if ((en.flags & 1) != 0) throw new OtaException("File " + Py.repr(en.name) + " is encrypted, password required for extraction");
        if (en.method != 0 && en.method != 8) throw new OtaException("NotImplementedError: That compression method is not supported");
        long data = en.headerOffset + 30 + nlen + xlen;
        return new EntryStream(en, data);
    }

    public byte[] read(String name) throws IOException {
        try (InputStream in = open(name)) {
            return Py.readAll(in);
        }
    }

    private final class EntryStream extends InputStream {
        final Entry en;
        long rpos;
        final long rend;
        final Inflater inf;
        final CRC32 crc = new CRC32();
        long produced;
        final byte[] raw = new byte[1 << 16];
        boolean eof;

        EntryStream(Entry en, long data) {
            this.en = en;
            this.rpos = data;
            this.rend = data + en.compressedSize;
            this.inf = en.method == 8 ? new Inflater(true) : null;
        }

        @Override
        public int read() throws IOException {
            byte[] one = new byte[1];
            int n = read(one, 0, 1);
            return n <= 0 ? -1 : one[0] & 0xff;
        }

        private int fill() throws IOException {
            int want = (int) Math.min(raw.length, rend - rpos);
            if (want <= 0) return 0;
            ByteBuffer b = ByteBuffer.wrap(raw, 0, want);
            int got = 0;
            while (b.hasRemaining()) {
                int n = ch.read(b, rpos + got);
                if (n < 0) throw new EOFException("Truncated zip entry " + en.name);
                got += n;
            }
            rpos += got;
            return got;
        }

        @Override
        public int read(byte[] buf, int off, int len) throws IOException {
            if (eof) return -1;
            if (len == 0) return 0;
            long left = en.size - produced;
            if (left <= 0) { finish(); return -1; }
            len = (int) Math.min(len, left);
            int n;
            if (inf == null) {
                int want = (int) Math.min(len, rend - rpos);
                if (want <= 0) throw new EOFException("Truncated zip entry " + en.name);
                ByteBuffer b = ByteBuffer.wrap(buf, off, want);
                n = ch.read(b, rpos);
                if (n < 0) throw new EOFException();
                rpos += n;
            } else {
                try {
                    while ((n = inf.inflate(buf, off, len)) == 0) {
                        if (inf.finished() || inf.needsDictionary()) throw new OtaException("BadZipFile: truncated deflate stream for " + en.name);
                        if (inf.needsInput()) {
                            int got = fill();
                            if (got == 0) throw new EOFException("Compressed file ended before the end-of-stream marker was reached");
                            inf.setInput(raw, 0, got);
                        }
                    }
                } catch (DataFormatException e) {
                    throw new OtaException("zlib.error: Error -3 while decompressing data: " + e.getMessage());
                }
            }
            crc.update(buf, off, n);
            produced += n;
            if (produced >= en.size) finish();
            return n;
        }

        private void finish() {
            if (eof) return;
            eof = true;
            if (crc.getValue() != en.crc) throw new OtaException("BadZipFile: Bad CRC-32 for file " + Py.repr(en.name));
        }

        @Override
        public void close() {
            if (inf != null) inf.end();
        }
    }

    @Override
    public void close() throws IOException {
        if (owner != null) owner.close();
        else ch.close();
    }
}

package com.linote.diffstudio.core;

import java.io.Closeable;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.zip.CRC32;
import java.util.zip.Deflater;

/**
 * ZIP writer equivalent to Python zipfile on a seekable file: DEFLATED level 6, sizes
 * and CRC patched into the local header (no data descriptor) so BusyBox unzip on old
 * devices can extract runtime blobs.
 */
public final class ZipOut implements Closeable {
    private static final class Rec {
        byte[] name;
        long offset, crc, csize, usize;
        int flags, dosTime, dosDate;
    }

    private final RandomAccessFile raf;
    private final List<Rec> recs = new ArrayList<>();
    private boolean open;
    private boolean closed;

    public ZipOut(File file) throws IOException {
        raf = new RandomAccessFile(file, "rw");
        raf.setLength(0);
    }

    private static int[] dosNow() {
        Calendar c = Calendar.getInstance();
        int year = Math.max(1980, c.get(Calendar.YEAR));
        int date = ((year - 1980) << 9) | ((c.get(Calendar.MONTH) + 1) << 5) | c.get(Calendar.DAY_OF_MONTH);
        int time = (c.get(Calendar.HOUR_OF_DAY) << 11) | (c.get(Calendar.MINUTE) << 5) | (c.get(Calendar.SECOND) / 2);
        return new int[]{time, date};
    }

    private void le16(byte[] b, int p, int v) { b[p] = (byte) v; b[p + 1] = (byte) (v >> 8); }

    private void le32(byte[] b, int p, long v) {
        b[p] = (byte) v; b[p + 1] = (byte) (v >> 8); b[p + 2] = (byte) (v >> 16); b[p + 3] = (byte) (v >> 24);
    }

    private byte[] localHeader(Rec r) {
        byte[] h = new byte[30 + r.name.length];
        le32(h, 0, 0x04034b50);
        le16(h, 4, 20);
        le16(h, 6, r.flags);
        le16(h, 8, 8);
        le16(h, 10, r.dosTime);
        le16(h, 12, r.dosDate);
        le32(h, 14, r.crc);
        le32(h, 18, r.csize);
        le32(h, 22, r.usize);
        le16(h, 26, r.name.length);
        le16(h, 28, 0);
        System.arraycopy(r.name, 0, h, 30, r.name.length);
        return h;
    }

    /** archive.open(name, 'w') */
    public OutputStream openEntry(String name) throws IOException {
        if (open) throw new IllegalStateException("Can't write to the ZIP file while there is another write handle open on it.");
        final Rec r = new Rec();
        boolean ascii = name.chars().allMatch(c -> c < 128);
        r.name = name.getBytes(ascii ? StandardCharsets.US_ASCII : StandardCharsets.UTF_8);
        r.flags = ascii ? 0 : 0x800;
        int[] dt = dosNow();
        r.dosTime = dt[0];
        r.dosDate = dt[1];
        r.offset = raf.getFilePointer();
        if (r.offset > 0xffffffffL) throw new OtaException("ZIP archive exceeds 4 GiB");
        raf.write(localHeader(r));
        open = true;
        final Deflater def = new Deflater(6, true);
        final CRC32 crc = new CRC32();
        final byte[] out = new byte[1 << 16];
        return new OutputStream() {
            boolean done;

            @Override
            public void write(int b) throws IOException {
                write(new byte[]{(byte) b}, 0, 1);
            }

            @Override
            public void write(byte[] b, int off, int len) throws IOException {
                if (len == 0) return;
                crc.update(b, off, len);
                r.usize += len;
                if (r.usize > 0xffffffffL) throw new OtaException("File size too large, try using force_zip64");
                def.setInput(b, off, len);
                while (!def.needsInput()) drain(Deflater.NO_FLUSH);
            }

            private void drain(int mode) throws IOException {
                int n = def.deflate(out, 0, out.length, mode);
                if (n > 0) {
                    raf.write(out, 0, n);
                    r.csize += n;
                }
            }

            @Override
            public void close() throws IOException {
                if (done) return;
                done = true;
                def.finish();
                while (!def.finished()) drain(Deflater.NO_FLUSH);
                def.end();
                r.crc = crc.getValue();
                if (r.csize > 0xffffffffL) throw new OtaException("Compressed size too large");
                long end = raf.getFilePointer();
                raf.seek(r.offset);
                raf.write(localHeader(r));
                raf.seek(end);
                recs.add(r);
                open = false;
            }
        };
    }

    /** archive.writestr(name, data) */
    public void writeBytes(String name, byte[] data) throws IOException {
        try (OutputStream o = openEntry(name)) {
            o.write(data, 0, data.length);
        }
    }

    @Override
    public void close() throws IOException {
        if (closed) return;
        closed = true;
        try {
            if (open) throw new IllegalStateException("entry still open");
            long cdStart = raf.getFilePointer();
            for (Rec r : recs) {
                byte[] h = new byte[46 + r.name.length];
                le32(h, 0, 0x02014b50);
                le16(h, 4, 20);           // made by MS-DOS (Python on Windows), version 2.0
                le16(h, 6, 20);
                le16(h, 8, r.flags);
                le16(h, 10, 8);
                le16(h, 12, r.dosTime);
                le16(h, 14, r.dosDate);
                le32(h, 16, r.crc);
                le32(h, 20, r.csize);
                le32(h, 24, r.usize);
                le16(h, 28, r.name.length);
                le32(h, 38, 0600L << 16); // external attributes, as zipfile sets for written entries
                le32(h, 42, r.offset);
                System.arraycopy(r.name, 0, h, 46, r.name.length);
                raf.write(h);
            }
            long cdEnd = raf.getFilePointer();
            if (cdEnd > 0xffffffffL || recs.size() > 0xffff) throw new OtaException("ZIP archive exceeds classic ZIP limits");
            byte[] e = new byte[22];
            le32(e, 0, 0x06054b50);
            le16(e, 8, recs.size());
            le16(e, 10, recs.size());
            le32(e, 12, cdEnd - cdStart);
            le32(e, 16, cdStart);
            raf.write(e);
        } finally {
            raf.close();
        }
    }

    /** Abort without finishing the central directory. */
    public void abort() {
        closed = true;
        try { raf.close(); } catch (IOException ignored) { }
    }
}

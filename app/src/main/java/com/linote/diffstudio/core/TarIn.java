package com.linote.diffstudio.core;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/** Sequential tar reader reproducing Python tarfile ('r|gz') member semantics. */
public final class TarIn {
    public static final class Node {
        public String name = "";
        public long mode, uid, gid, size;
        public char type;
        public String linkname = "";
        /** pax headers: keyword -> raw value bytes */
        public Map<String, byte[]> pax = new LinkedHashMap<>();

        public boolean isFile() { return type == '0' || type == '\0' || type == '7' || type == 'S'; }
        public boolean isDir() { return type == '5'; }
        public boolean isSym() { return type == '2'; }
        public boolean isLnk() { return type == '1'; }
    }

    private final InputStream in;
    private final Map<String, byte[]> globalPax = new LinkedHashMap<>();
    private long offset;
    private long dataLeft;     // unread bytes of current member's data area (including padding)
    private long fileLeft;     // unread bytes of current member's file content
    private boolean done;

    public TarIn(InputStream in) {
        this.in = in;
    }

    private void readFully(byte[] b, int off, int len) throws IOException {
        while (len > 0) {
            int n = in.read(b, off, len);
            if (n < 0) throw new EOFException("unexpected end of data");
            off += n;
            len -= n;
            offset += n;
        }
    }

    private void skip(long n) throws IOException {
        byte[] buf = new byte[1 << 16];
        while (n > 0) {
            int r = in.read(buf, 0, (int) Math.min(buf.length, n));
            if (r < 0) throw new EOFException("unexpected end of data");
            n -= r;
            offset += r;
        }
    }

    private static long block(long size) {
        return (size + 511) / 512 * 512;
    }

    private static String nts(byte[] b, int off, int len) {
        int end = off;
        while (end < off + len && b[end] != 0) end++;
        return Py.decodeSurrogateEscape(b, off, end - off);
    }

    private static long nti(byte[] b, int off, int len) {
        int first = b[off] & 0xff;
        if (first == 0200 || first == 0377) {
            long n = 0;
            for (int i = 1; i < len; i++) n = (n << 8) + (b[off + i] & 0xff);
            if (first == 0377) n = -((1L << (8 * (len - 1))) - n);
            return n;
        }
        int end = off;
        while (end < off + len && b[end] != 0) end++;
        String s = new String(b, off, end - off, StandardCharsets.ISO_8859_1);
        for (int i = 0; i < s.length(); i++) if (s.charAt(i) > 127) throw new InvalidHeader("invalid header");
        s = Py.strip(s);
        if (s.isEmpty()) return 0;
        try {
            return Long.parseLong(s, 8);
        } catch (NumberFormatException e) {
            throw new InvalidHeader("invalid header");
        }
    }

    private static final class InvalidHeader extends RuntimeException {
        InvalidHeader(String m) { super(m); }
    }

    private static final class EofHeader extends RuntimeException {
        EofHeader() { super("end of file header"); }
    }

    /** Returns null at end of archive. */
    public Node next() throws IOException {
        if (done) return null;
        // skip the remainder of the previous member
        if (dataLeft > 0) { skip(dataLeft); dataLeft = 0; fileLeft = 0; }
        long start = offset;
        try {
            Node n = readMember();
            return n;
        } catch (EofHeader e) {
            done = true;
            if (start == 0) throw new OtaException("ReadError: empty file");
            return null;
        } catch (InvalidHeader e) {
            done = true;
            if (start == 0) throw new OtaException("ReadError: " + e.getMessage());
            return null;
        } catch (EOFException e) {
            done = true;
            if (start == 0) throw new OtaException("ReadError: empty file");
            return null;
        }
    }

    private byte[] readHeaderBlock() throws IOException {
        byte[] buf = new byte[512];
        int got = 0;
        while (got < 512) {
            int n = in.read(buf, got, 512 - got);
            if (n < 0) break;
            got += n;
        }
        offset += got;
        if (got == 0) throw new EOFException();
        if (got != 512) throw new InvalidHeader("truncated header");
        boolean zero = true;
        for (byte x : buf) if (x != 0) { zero = false; break; }
        if (zero) throw new EofHeader();
        long chk = nti(buf, 148, 8);
        long unsigned = 256, signed = 256;
        for (int i = 0; i < 512; i++) {
            if (i >= 148 && i < 156) continue;
            unsigned += buf[i] & 0xff;
            signed += buf[i];
        }
        if (chk != unsigned && chk != signed) throw new InvalidHeader("bad checksum");
        return buf;
    }

    private Node frombuf(byte[] buf) {
        Node n = new Node();
        n.name = nts(buf, 0, 100);
        n.mode = nti(buf, 100, 8);
        n.uid = nti(buf, 108, 8);
        n.gid = nti(buf, 116, 8);
        n.size = nti(buf, 124, 12);
        n.type = (char) (buf[156] & 0xff);
        n.linkname = nts(buf, 157, 100);
        String prefix = nts(buf, 345, 155);
        if (n.type == '\0' && n.name.endsWith("/")) n.type = '5';
        if (n.isDir()) n.name = Py.rstripChars(n.name, "/");
        boolean gnu = n.type == 'L' || n.type == 'K' || n.type == 'S';
        if (!prefix.isEmpty() && !gnu) n.name = prefix + "/" + n.name;
        return n;
    }

    private static boolean supported(char t) {
        return "0\0" .indexOf(t) >= 0 || "7S125634LK".indexOf(t) >= 0;
    }

    private Node readMember() throws IOException {
        byte[] buf = readHeaderBlock();
        Node n = frombuf(buf);
        char t = n.type;
        if (t == 'L' || t == 'K') {
            byte[] data = new byte[(int) block(n.size)];
            readFully(data, 0, data.length);
            Node next = readMember();
            String value = nts(data, 0, (int) Math.min(n.size, data.length));
            if (t == 'L') next.name = value;
            else next.linkname = value;
            if (next.isDir()) next.name = next.name.endsWith("/") ? next.name.substring(0, next.name.length() - 1) : next.name;
            return next;
        }
        if (t == 'x' || t == 'g' || t == 'X') {
            byte[] data = new byte[(int) block(n.size)];
            readFully(data, 0, data.length);
            Map<String, byte[]> target = t == 'g' ? globalPax : new LinkedHashMap<>(globalPax);
            parsePax(data, (int) Math.min(n.size, data.length), target);
            Node next = readMember();
            if (t != 'g') applyPax(next, target);
            return next;
        }
        if (t == 'S') throw new OtaException("Unsupported sparse tar member: " + n.name);
        // builtin member
        long dataArea = (n.isFile() || !supported(t)) ? block(n.size) : 0;
        applyPax(n, globalPax);
        if (n.isDir()) n.name = Py.rstripChars(n.name, "/");
        dataLeft = dataArea;
        fileLeft = n.isFile() ? n.size : 0;
        return n;
    }

    private void parsePax(byte[] data, int len, Map<String, byte[]> target) {
        int pos = 0;
        while (pos < len) {
            // regex (\d+) ([^=]+)=
            int p = pos;
            while (p < len && data[p] >= '0' && data[p] <= '9') p++;
            if (p == pos || p >= len || data[p] != ' ') break;
            long length = Long.parseLong(new String(data, pos, p - pos, StandardCharsets.US_ASCII));
            int ks = p + 1, ke = ks;
            while (ke < len && data[ke] != '=') ke++;
            if (ke == ks || ke >= len) break;
            if (length == 0) throw new InvalidHeader("invalid header");
            int vs = ke + 1;
            int ve = (int) Math.min(len, pos + length - 1);
            byte[] value = ve > vs ? java.util.Arrays.copyOfRange(data, vs, ve) : new byte[0];
            String keyword = Py.decodeSurrogateEscape(java.util.Arrays.copyOfRange(data, ks, ke));
            target.remove(keyword);
            target.put(keyword, value);
            pos += (int) length;
        }
    }

    private void applyPax(Node n, Map<String, byte[]> pax) {
        for (Map.Entry<String, byte[]> e : pax.entrySet()) {
            String k = e.getKey();
            String v = Py.decodeSurrogateEscape(e.getValue());
            switch (k) {
                case "path": n.name = Py.rstripChars(v, "/"); break;
                case "linkpath": n.linkname = v; break;
                case "size": n.size = paxInt(v); break;
                case "uid": n.uid = paxInt(v); break;
                case "gid": n.gid = paxInt(v); break;
                default: break;
            }
        }
        n.pax = new LinkedHashMap<>(pax);
    }

    private static long paxInt(String v) {
        try {
            return Long.parseLong(Py.strip(v));
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /** Stream of the current regular member's content. */
    public InputStream content() {
        return new InputStream() {
            @Override
            public int read() throws IOException {
                byte[] one = new byte[1];
                return read(one, 0, 1) <= 0 ? -1 : one[0] & 0xff;
            }

            @Override
            public int read(byte[] b, int off, int len) throws IOException {
                if (fileLeft <= 0) return -1;
                int n = in.read(b, off, (int) Math.min(len, fileLeft));
                if (n < 0) throw new OtaException("ReadError: unexpected end of data");
                fileLeft -= n;
                dataLeft -= n;
                offset += n;
                return n;
            }

            @Override
            public void close() { }
        };
    }
}

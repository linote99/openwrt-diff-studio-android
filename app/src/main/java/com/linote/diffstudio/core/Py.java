package com.linote.diffstudio.core;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/** Small helpers reproducing the exact Python semantics the original tool relies on. */
public final class Py {
    private Py() {}

    /** Python str ordering: by Unicode code point (not UTF-16 unit). */
    public static final Comparator<String> CODEPOINT_ORDER = (a, b) -> {
        int i = 0, j = 0;
        while (i < a.length() && j < b.length()) {
            int ca = a.codePointAt(i), cb = b.codePointAt(j);
            if (ca != cb) return ca < cb ? -1 : 1;
            i += Character.charCount(ca);
            j += Character.charCount(cb);
        }
        return Integer.compare(a.length() - i, b.length() - j);
    };

    public static int pyLen(String s) {
        return s.codePointCount(0, s.length());
    }

    public static MessageDigest sha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    public static String hex(byte[] b) {
        char[] h = "0123456789abcdef".toCharArray();
        char[] out = new char[b.length * 2];
        for (int i = 0; i < b.length; i++) {
            out[i * 2] = h[(b[i] >> 4) & 15];
            out[i * 2 + 1] = h[b[i] & 15];
        }
        return new String(out);
    }

    public static String sha256Hex(byte[] data) {
        return hex(sha256().digest(data));
    }

    /** ota_engine.digest(): sha256 of a stream read to EOF in 1 MiB blocks. */
    public static String digest(InputStream in) throws IOException {
        MessageDigest md = sha256();
        byte[] buf = new byte[1 << 20];
        int n;
        while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
        return hex(md.digest());
    }

    /** stream.read(limit): read up to limit bytes (fewer only at EOF). */
    public static byte[] readUpTo(InputStream in, long limit) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[1 << 16];
        long left = limit;
        while (left > 0) {
            int n = in.read(buf, 0, (int) Math.min(buf.length, left));
            if (n < 0) break;
            out.write(buf, 0, n);
            left -= n;
        }
        return out.toByteArray();
    }

    public static byte[] readAll(InputStream in) throws IOException {
        return readUpTo(in, Long.MAX_VALUE);
    }

    /** bytes.decode('utf-8', 'surrogateescape'). */
    public static String decodeSurrogateEscape(byte[] b, int off, int len) {
        StringBuilder sb = new StringBuilder(len);
        int i = off, end = off + len;
        while (i < end) {
            int c = b[i] & 0xff;
            if (c < 0x80) {
                sb.append((char) c);
                i++;
                continue;
            }
            int need, min2 = 0x80, max2 = 0xbf;
            int cp;
            if (c >= 0xc2 && c <= 0xdf) { need = 1; cp = c & 0x1f; }
            else if (c == 0xe0) { need = 2; cp = c & 0x0f; min2 = 0xa0; }
            else if (c >= 0xe1 && c <= 0xec || c == 0xee || c == 0xef) { need = 2; cp = c & 0x0f; }
            else if (c == 0xed) { need = 2; cp = c & 0x0f; max2 = 0x9f; }
            else if (c == 0xf0) { need = 3; cp = c & 0x07; min2 = 0x90; }
            else if (c >= 0xf1 && c <= 0xf3) { need = 3; cp = c & 0x07; }
            else if (c == 0xf4) { need = 3; cp = c & 0x07; max2 = 0x8f; }
            else { sb.append((char) (0xdc00 + c)); i++; continue; }
            boolean ok = i + need < end;
            if (ok) {
                for (int k = 1; k <= need; k++) {
                    int cc = b[i + k] & 0xff;
                    int lo = k == 1 ? min2 : 0x80, hi = k == 1 ? max2 : 0xbf;
                    if (cc < lo || cc > hi) { ok = false; break; }
                    cp = (cp << 6) | (cc & 0x3f);
                }
            }
            if (!ok) {
                sb.append((char) (0xdc00 + c));
                i++;
                continue;
            }
            sb.appendCodePoint(cp);
            i += need + 1;
        }
        return sb.toString();
    }

    public static String decodeSurrogateEscape(byte[] b) {
        return decodeSurrogateEscape(b, 0, b.length);
    }

    /** str.encode('utf-8', 'surrogateescape'). */
    public static byte[] encodeSurrogateEscape(String s) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(s.length() + 8);
        for (int i = 0; i < s.length(); ) {
            int cp = s.codePointAt(i);
            i += Character.charCount(cp);
            if (cp >= 0xdc80 && cp <= 0xdcff) {
                out.write(cp - 0xdc00);
            } else if (cp >= 0xd800 && cp <= 0xdfff) {
                throw new OtaException("UnicodeEncodeError: surrogates not allowed");
            } else {
                byte[] e = new String(Character.toChars(cp)).getBytes(StandardCharsets.UTF_8);
                out.write(e, 0, e.length);
            }
        }
        return out.toByteArray();
    }

    /** Strict UTF-8 decode (raises like bytes.decode('utf-8')). */
    public static String decodeUtf8Strict(byte[] b) {
        String s = decodeSurrogateEscape(b);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c >= 0xdc80 && c <= 0xdcff && !(i > 0 && Character.isHighSurrogate(s.charAt(i - 1)))) {
                throw new OtaException("UnicodeDecodeError: 'utf-8' codec can't decode byte 0x"
                        + Integer.toHexString(c - 0xdc00) + ": invalid utf-8");
            }
        }
        return s;
    }

    /** bytes.decode('utf-8', 'replace'). */
    public static String decodeUtf8Replace(byte[] b, int off, int len) {
        String s = decodeSurrogateEscape(b, off, len);
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c >= 0xdc80 && c <= 0xdcff && !(i > 0 && Character.isHighSurrogate(s.charAt(i - 1)))) sb.append('\ufffd');
            else sb.append(c);
        }
        return sb.toString();
    }

    /** str.splitlines() */
    public static List<String> splitlines(String s) {
        List<String> out = new ArrayList<>();
        int start = 0, i = 0, n = s.length();
        while (i < n) {
            char c = s.charAt(i);
            boolean br = c == '\n' || c == '\r' || c == 0x0b || c == 0x0c || c == 0x1c || c == 0x1d || c == 0x1e
                    || c == 0x85 || c == 0x2028 || c == 0x2029;
            if (br) {
                out.add(s.substring(start, i));
                if (c == '\r' && i + 1 < n && s.charAt(i + 1) == '\n') i++;
                i++;
                start = i;
            } else {
                i++;
            }
        }
        if (start < n) out.add(s.substring(start));
        return out;
    }

    public static boolean isPySpace(int c) {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0b || c == 0x0c || c == 0x1c || c == 0x1d
                || c == 0x1e || c == 0x1f || c == 0x85 || c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a)
                || c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000;
    }

    public static String strip(String s) {
        int a = 0, b = s.length();
        while (a < b && isPySpace(s.charAt(a))) a++;
        while (b > a && isPySpace(s.charAt(b - 1))) b--;
        return s.substring(a, b);
    }

    public static String rstripChars(String s, String chars) {
        int b = s.length();
        while (b > 0 && chars.indexOf(s.charAt(b - 1)) >= 0) b--;
        return s.substring(0, b);
    }

    /** str.split(None, 1) */
    public static List<String> splitWhitespace(String s, int maxsplit) {
        List<String> out = new ArrayList<>();
        int i = 0, n = s.length();
        while (i < n) {
            while (i < n && isPySpace(s.charAt(i))) i++;
            if (i >= n) break;
            if (maxsplit >= 0 && out.size() == maxsplit) {
                int e = n;
                while (e > i && isPySpace(s.charAt(e - 1))) e--;
                out.add(s.substring(i, e));
                break;
            }
            int j = i;
            while (j < n && !isPySpace(s.charAt(j))) j++;
            out.add(s.substring(i, j));
            i = j;
        }
        return out;
    }

    /** posixpath.normpath for the relative/absolute paths used by ota_runtime. */
    public static String normpath(String path) {
        if (path.isEmpty()) return ".";
        int initial = 0;
        if (path.startsWith("/")) {
            initial = path.startsWith("//") && !path.startsWith("///") ? 2 : 1;
        }
        List<String> out = new ArrayList<>();
        for (String comp : path.split("/", -1)) {
            if (comp.isEmpty() || comp.equals(".")) continue;
            if (!comp.equals("..") || (initial == 0 && out.isEmpty()) || (!out.isEmpty() && out.get(out.size() - 1).equals(".."))) {
                out.add(comp);
            } else if (!out.isEmpty()) {
                out.remove(out.size() - 1);
            }
        }
        String joined = String.join("/", out);
        if (initial > 0) joined = (initial == 2 ? "//" : "/") + joined;
        return joined.isEmpty() ? "." : joined;
    }

    /** posixpath.dirname */
    public static String dirname(String p) {
        int i = p.lastIndexOf('/') + 1;
        String head = p.substring(0, i);
        if (!head.isEmpty() && !head.chars().allMatch(c -> c == '/')) head = rstripChars(head, "/");
        return head;
    }

    /** posixpath.join(a, b) */
    public static String join(String a, String b) {
        if (b.startsWith("/")) return b;
        if (a.isEmpty() || a.endsWith("/")) return a + b;
        return a + "/" + b;
    }

    /** shlex.quote */
    public static String shlexQuote(String s) {
        if (s.isEmpty()) return "''";
        boolean safe = true;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                    || "_@%+=:,./-".indexOf(c) >= 0;
            if (!ok) { safe = false; break; }
        }
        if (safe) return s;
        return "'" + s.replace("'", "'\"'\"'") + "'";
    }

    /** Python repr() of a str (close enough for error messages). */
    public static String repr(Object o) {
        if (!(o instanceof String)) return String.valueOf(o);
        String s = (String) o;
        char q = s.indexOf('\'') >= 0 && s.indexOf('"') < 0 ? '"' : '\'';
        StringBuilder sb = new StringBuilder().append(q);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == q || c == '\\') sb.append('\\').append(c);
            else if (c == '\n') sb.append("\\n");
            else if (c == '\r') sb.append("\\r");
            else if (c == '\t') sb.append("\\t");
            else if (c < 0x20 || c == 0x7f) sb.append(String.format("\\x%02x", (int) c));
            else if (c >= 0xd800 && c <= 0xdfff) sb.append(String.format("\\u%04x", (int) c));
            else sb.append(c);
        }
        return sb.append(q).toString();
    }

    public static String oct(long v) {
        return Long.toOctalString(v);
    }

    // --- strict base64 (base64.b64encode / b64decode(validate=True)) ---
    private static final char[] B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();

    public static String b64encode(byte[] data) {
        StringBuilder sb = new StringBuilder((data.length + 2) / 3 * 4);
        for (int i = 0; i < data.length; i += 3) {
            int b0 = data[i] & 0xff;
            int b1 = i + 1 < data.length ? data[i + 1] & 0xff : 0;
            int b2 = i + 2 < data.length ? data[i + 2] & 0xff : 0;
            sb.append(B64[b0 >> 2]).append(B64[((b0 & 3) << 4) | (b1 >> 4)]);
            sb.append(i + 1 < data.length ? B64[((b1 & 15) << 2) | (b2 >> 6)] : '=');
            sb.append(i + 2 < data.length ? B64[b2 & 63] : '=');
        }
        return sb.toString();
    }

    public static byte[] b64decodeStrict(String s) {
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=';
            if (!ok) throw new OtaException("Non-base64 digit found");
        }
        try {
            return java.util.Base64.getDecoder().decode(s);
        } catch (IllegalArgumentException e) {
            throw new OtaException("Incorrect padding");
        }
    }
}

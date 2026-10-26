package com.linote.diffstudio.core;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * JSON with Python json module semantics: objects are LinkedHashMap, arrays ArrayList,
 * integers Long (BigInteger when large), floats Double, null is Java null.
 */
public final class Json {
    private Json() {}

    // ---------------- parsing ----------------
    public static Object parse(byte[] data) {
        // json.loads(bytes) detects 'utf-8-sig', so a UTF-8 BOM is accepted for byte input.
        if (data.length >= 3 && (data[0] & 0xff) == 0xef && (data[1] & 0xff) == 0xbb && (data[2] & 0xff) == 0xbf)
            data = java.util.Arrays.copyOfRange(data, 3, data.length);
        String s = Py.decodeUtf8Strict(data);
        return parse(s);
    }

    public static Object parse(String s) {
        return parse(s, false);
    }

    /** json.loads(raw, object_pairs_hook=_unique) from release_index.py: duplicate keys are rejected. */
    public static Object parseUnique(byte[] data) {
        if (data.length >= 3 && (data[0] & 0xff) == 0xef && (data[1] & 0xff) == 0xbb && (data[2] & 0xff) == 0xbf)
            data = java.util.Arrays.copyOfRange(data, 3, data.length);
        return parse(Py.decodeUtf8Strict(data), true);
    }

    private static Object parse(String s, boolean unique) {
        Parser p = new Parser(s);
        p.unique = unique;
        p.ws();
        Object v = p.value();
        p.ws();
        if (p.i != s.length()) throw new OtaException("Extra data: char " + p.i);
        return v;
    }

    private static final class Parser {
        final String s;
        int i;
        boolean unique;

        Parser(String s) { this.s = s; }

        void ws() {
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++;
                else break;
            }
        }

        OtaException err(String m) {
            return new OtaException("JSONDecodeError: " + m + ": char " + i);
        }

        Object value() {
            if (i >= s.length()) throw err("Expecting value");
            char c = s.charAt(i);
            switch (c) {
                case '{': return object();
                case '[': return array();
                case '"': return string();
                case 't': return lit("true", Boolean.TRUE);
                case 'f': return lit("false", Boolean.FALSE);
                case 'n': return lit("null", null);
                case 'N': return lit("NaN", Double.NaN);
                case 'I': return lit("Infinity", Double.POSITIVE_INFINITY);
                default:
                    if (c == '-' && s.startsWith("-Infinity", i)) return lit("-Infinity", Double.NEGATIVE_INFINITY);
                    if (c == '-' || (c >= '0' && c <= '9')) return number();
                    throw err("Expecting value");
            }
        }

        Object lit(String word, Object v) {
            if (!s.startsWith(word, i)) throw err("Expecting value");
            i += word.length();
            return v;
        }

        Object number() {
            int st = i;
            if (s.charAt(i) == '-') i++;
            if (i >= s.length()) throw err("Expecting value");
            if (s.charAt(i) == '0') i++;
            else if (s.charAt(i) >= '1' && s.charAt(i) <= '9') { while (i < s.length() && Character.isDigit(s.charAt(i)) && s.charAt(i) < 128) i++; }
            else throw err("Expecting value");
            boolean flt = false;
            if (i < s.length() && s.charAt(i) == '.' && i + 1 < s.length() && isD(s.charAt(i + 1))) {
                flt = true; i++;
                while (i < s.length() && isD(s.charAt(i))) i++;
            }
            if (i < s.length() && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
                int save = i;
                i++;
                if (i < s.length() && (s.charAt(i) == '+' || s.charAt(i) == '-')) i++;
                if (i < s.length() && isD(s.charAt(i))) {
                    flt = true;
                    while (i < s.length() && isD(s.charAt(i))) i++;
                } else i = save;
            }
            String t = s.substring(st, i);
            if (flt) return Double.parseDouble(t);
            BigInteger b = new BigInteger(t);
            if (b.bitLength() < 64) return b.longValue();
            return b;
        }

        boolean isD(char c) { return c >= '0' && c <= '9'; }

        String string() {
            i++;
            StringBuilder sb = new StringBuilder();
            while (true) {
                if (i >= s.length()) throw err("Unterminated string starting at");
                char c = s.charAt(i++);
                if (c == '"') break;
                if (c == '\\') {
                    if (i >= s.length()) throw err("Unterminated string starting at");
                    char e = s.charAt(i++);
                    switch (e) {
                        case '"': sb.append('"'); break;
                        case '\\': sb.append('\\'); break;
                        case '/': sb.append('/'); break;
                        case 'b': sb.append('\b'); break;
                        case 'f': sb.append('\f'); break;
                        case 'n': sb.append('\n'); break;
                        case 'r': sb.append('\r'); break;
                        case 't': sb.append('\t'); break;
                        case 'u':
                            if (i + 4 > s.length()) throw err("Invalid \\uXXXX escape");
                            try {
                                sb.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                            } catch (NumberFormatException ex) {
                                throw err("Invalid \\uXXXX escape");
                            }
                            i += 4;
                            break;
                        default: throw err("Invalid \\escape");
                    }
                } else if (c < 0x20) {
                    throw err("Invalid control character at");
                } else sb.append(c);
            }
            return sb.toString();
        }

        Map<String, Object> object() {
            i++;
            LinkedHashMap<String, Object> m = new LinkedHashMap<>();
            ws();
            if (i < s.length() && s.charAt(i) == '}') { i++; return m; }
            while (true) {
                ws();
                if (i >= s.length() || s.charAt(i) != '"') throw err("Expecting property name enclosed in double quotes");
                String k = string();
                ws();
                if (i >= s.length() || s.charAt(i) != ':') throw err("Expecting ':' delimiter");
                i++;
                ws();
                Object v = value();
                if (unique && m.containsKey(k)) throw new OtaException("Duplicate release index key / 版本摘要存在重复字段");
                m.remove(k);
                m.put(k, v);
                ws();
                if (i < s.length() && s.charAt(i) == ',') { i++; continue; }
                if (i < s.length() && s.charAt(i) == '}') { i++; return m; }
                throw err("Expecting ',' delimiter");
            }
        }

        List<Object> array() {
            i++;
            ArrayList<Object> a = new ArrayList<>();
            ws();
            if (i < s.length() && s.charAt(i) == ']') { i++; return a; }
            while (true) {
                ws();
                a.add(value());
                ws();
                if (i < s.length() && s.charAt(i) == ',') { i++; continue; }
                if (i < s.length() && s.charAt(i) == ']') { i++; return a; }
                throw err("Expecting ',' delimiter");
            }
        }
    }

    // ---------------- serialization ----------------
    /** json.dumps(data, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode() */
    public static byte[] canonical(Object o) {
        StringBuilder sb = new StringBuilder();
        write(sb, o, true);
        return sb.toString().getBytes(StandardCharsets.US_ASCII);
    }

    /** json.dumps(data, ensure_ascii=True) default separators, insertion order (for display/debug). */
    public static String dumps(Object o) {
        StringBuilder sb = new StringBuilder();
        write(sb, o, false);
        return sb.toString();
    }

    @SuppressWarnings("unchecked")
    private static void write(StringBuilder sb, Object o, boolean canonical) {
        if (o == null) sb.append("null");
        else if (o instanceof Boolean) sb.append(((Boolean) o) ? "true" : "false");
        else if (o instanceof Long || o instanceof Integer || o instanceof BigInteger || o instanceof Short) sb.append(o.toString());
        else if (o instanceof Double || o instanceof Float) sb.append(floatRepr(((Number) o).doubleValue()));
        else if (o instanceof String) quote(sb, (String) o);
        else if (o instanceof Map) {
            Map<String, Object> m = (Map<String, Object>) o;
            List<String> keys = new ArrayList<>(m.keySet());
            if (canonical) keys.sort(Py.CODEPOINT_ORDER);
            sb.append('{');
            boolean first = true;
            for (String k : keys) {
                if (!first) sb.append(canonical ? "," : ", ");
                first = false;
                quote(sb, k);
                sb.append(canonical ? ":" : ": ");
                write(sb, m.get(k), canonical);
            }
            sb.append('}');
        } else if (o instanceof List) {
            sb.append('[');
            boolean first = true;
            for (Object v : (List<Object>) o) {
                if (!first) sb.append(canonical ? "," : ", ");
                first = false;
                write(sb, v, canonical);
            }
            sb.append(']');
        } else {
            throw new OtaException("TypeError: Object of type " + o.getClass().getSimpleName() + " is not JSON serializable");
        }
    }

    private static String floatRepr(double d) {
        if (Double.isNaN(d)) return "NaN";
        if (Double.isInfinite(d)) return d > 0 ? "Infinity" : "-Infinity";
        if (d == Math.rint(d) && Math.abs(d) < 1e16) {
            String s = new java.math.BigDecimal(d).toPlainString();
            return s + ".0";
        }
        String s = Double.toString(d);
        if (s.contains("E")) {
            String[] p = s.split("E");
            String mant = p[0].endsWith(".0") ? p[0].substring(0, p[0].length() - 2) : p[0];
            int exp = Integer.parseInt(p[1]);
            if (exp >= -4 && exp < 16) return new java.math.BigDecimal(s).toPlainString();
            return mant + "e" + (exp < 0 ? "-" : "+") + (Math.abs(exp) < 10 ? "0" : "") + Math.abs(exp);
        }
        return s;
    }

    private static void quote(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                default:
                    if (c < 0x20 || c > 0x7e) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        sb.append('"');
    }

    // --------------- typed accessors -----------------
    @SuppressWarnings("unchecked")
    public static Map<String, Object> map(Object o) {
        return o instanceof Map ? (Map<String, Object>) o : null;
    }

    @SuppressWarnings("unchecked")
    public static List<Object> list(Object o) {
        return o instanceof List ? (List<Object>) o : null;
    }

    public static String str(Object o) {
        return o instanceof String ? (String) o : null;
    }

    /** Python: type(v) is int */
    public static boolean isInt(Object o) {
        return o instanceof Long || o instanceof Integer || o instanceof BigInteger;
    }

    public static long asLong(Object o) {
        if (o instanceof BigInteger) {
            BigInteger b = (BigInteger) o;
            return b.signum() < 0 ? Long.MIN_VALUE : Long.MAX_VALUE;
        }
        return ((Number) o).longValue();
    }

    /** Python truthiness. */
    public static boolean truthy(Object o) {
        if (o == null) return false;
        if (o instanceof Boolean) return (Boolean) o;
        if (o instanceof Number) return ((Number) o).doubleValue() != 0;
        if (o instanceof String) return !((String) o).isEmpty();
        if (o instanceof Map) return !((Map<?, ?>) o).isEmpty();
        if (o instanceof List) return !((List<?>) o).isEmpty();
        return true;
    }

    /** Python ==: ints compare by value regardless of boxing. */
    public static boolean pyEquals(Object a, Object b) {
        if (a == b) return true;
        if (a == null || b == null) return false;
        if (isInt(a) && isInt(b)) return new BigInteger(a.toString()).equals(new BigInteger(b.toString()));
        if (a instanceof Map && b instanceof Map) {
            Map<?, ?> x = (Map<?, ?>) a, y = (Map<?, ?>) b;
            if (x.size() != y.size()) return false;
            for (Map.Entry<?, ?> e : x.entrySet()) {
                if (!y.containsKey(e.getKey())) return false;
                if (!pyEquals(e.getValue(), y.get(e.getKey()))) return false;
            }
            return true;
        }
        if (a instanceof List && b instanceof List) {
            List<?> x = (List<?>) a, y = (List<?>) b;
            if (x.size() != y.size()) return false;
            for (int i = 0; i < x.size(); i++) if (!pyEquals(x.get(i), y.get(i))) return false;
            return true;
        }
        return a.equals(b);
    }
}

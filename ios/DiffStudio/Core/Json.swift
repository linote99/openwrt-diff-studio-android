// Json.swift
// Port of com.linote.diffstudio.core.Json (Java, MIT).
//
// JSON with Python `json`-module semantics:
//  * values are JsonValue (.object = insertion-ordered map, .array,
//    .string, .int(Int64), .bigInt(decimal string), .double, .bool, .null)
//  * bare NaN / Infinity / -Infinity are accepted on parse
//  * `parseUnique` rejects duplicate object keys with the exact
//    bilingual message from Java; plain `parse` moves a duplicate key
//    to the end (LinkedHashMap remove-then-put), last value wins
//  * `canonical` is `json.dumps(sort_keys=True, separators=(',',':'),
//    ensure_ascii=True)`; `dumps` uses default separators, insertion order
//  * float formatting reproduces Python's repr (`.0` suffix, `1e+07`
//    style exponents) — Swift's JSONEncoder does not match

import Foundation

public enum JsonValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case bigInt(String) // decimal string, out of Int64 range
    case double(Double)
    case string(String)
    case array([JsonValue])
    case object(JsonObject)

    public var isNull: Bool { if case .null = self { return true }; return false }
}

public enum Json {
    // MARK: - Parsing

    public static func parse(_ data: Data) throws -> JsonValue {
        var bytes = [UInt8](data)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3) // UTF-8 BOM, Python utf-8-sig
        }
        let s = try Py.decodeUtf8Strict(bytes)
        return try parse(s)
    }

    public static func parseUnique(_ data: Data) throws -> JsonValue {
        var bytes = [UInt8](data)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { bytes.removeFirst(3) }
        let s = try Py.decodeUtf8Strict(bytes)
        return try Parser(s, unique: true).parseTop()
    }

    public static func parse(_ s: String) throws -> JsonValue {
        try Parser(s, unique: false).parseTop()
    }

    // MARK: - Serialisation

    public static func canonical(_ value: JsonValue) -> Data {
        Data(dumps(value, canonical: true).utf8)
    }

    public static func dumps(_ value: JsonValue, canonical: Bool = false) -> String {
        var out = ""
        write(&out, value, canonical: canonical)
        return out
    }

    public static func dumps(_ value: JsonValue) -> String { dumps(value, canonical: false) }

    private static func write(_ out: inout String, _ value: JsonValue, canonical: Bool) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .bigInt(let s): out += s
        case .double(let d): out += floatRepr(d)
        case .string(let s): out += quote(s)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += canonical ? "," : ", " }
                write(&out, item, canonical: canonical)
            }
            out += "]"
        case .object(let obj):
            out += "{"
            var pairs = obj.pairs
            if canonical {
                pairs.sort { Py.codepointCompare($0.0, $1.0) == .orderedAscending }
            }
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += canonical ? "," : ", " }
                out += quote(pair.0)
                out += canonical ? ":" : ": "
                write(&out, pair.1, canonical: canonical)
            }
            out += "}"
        }
    }

    /// Python float repr (see Json.java `floatRepr`).
    public static func floatRepr(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d == Double.infinity { return "Infinity" }
        if d == -Double.infinity { return "-Infinity" }
        if d == d.rounded(), abs(d) < 1e16 {
            // BigDecimal(d).toPlainString() + ".0"
            var s = plainDecimal(d)
            if !s.contains(".") { s += ".0" } else { s += "0" } // BigDecimal(double) keeps .0
            // The Java path is: new BigDecimal(d).toPlainString() + ".0"
            // BigDecimal(double) already ends in ".0" for integral values,
            // so the result is e.g. "1.0". Recompute directly:
            return integralFloatString(d)
        }
        let s = String(d) // Swift Double description (shortest round-trip)
        if s.contains("e") || s.contains("E") {
            let parts = s.lowercased().split(separator: "e")
            var mant = String(parts[0])
            let exp = Int(parts[1]) ?? 0
            if mant.hasSuffix(".0") { mant = String(mant.dropLast(2)) }
            if exp >= -4, exp < 16 {
                return plainDecimalString(s)
            }
            let sign = exp < 0 ? "-" : "+"
            let absExp = abs(exp)
            return mant + "e" + sign + (absExp < 10 ? "0" : "") + String(absExp)
        }
        return s
    }

    private static func integralFloatString(_ d: Double) -> String {
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let s = String(format: "%.1f", d)
        return s
    }

    private static func plainDecimal(_ d: Double) -> String {
        // Decimal string without exponent for |d| < 1e16 integral values.
        if d == d.rounded(), abs(d) < 1e16 {
            return String(format: "%.0f", d)
        }
        return String(d)
    }

    private static func plainDecimalString(_ s: String) -> String {
        // Convert a Swift Double description like "1.5e-05" or "12300.0"
        // to a plain decimal string (Python BigDecimal.toPlainString).
        guard let d = Double(s) else { return s }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 30
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: d)) ?? s
    }

    /// JSON string quoting, per UTF-16 code unit (astral chars become
    /// two \uXXXX escapes, exactly as Java).
    public static func quote(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            default:
                if unit < 0x20 || unit > 0x7E {
                    out += String(format: "\\u%04x", unit)
                } else {
                    out.append(Character(UnicodeScalar(unit)!))
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - Typed helpers

    public static func map(_ value: JsonValue?) -> JsonObject? {
        guard let value, case .object(let o) = value else { return nil }
        return o
    }

    public static func list(_ value: JsonValue?) -> [JsonValue]? {
        guard let value, case .array(let a) = value else { return nil }
        return a
    }

    public static func str(_ value: JsonValue?) -> String? {
        guard let value, case .string(let s) = value else { return nil }
        return s
    }

    /// Wrap an ordered map of descriptors (name -> descriptor object)
    /// as a JSON object value, as Java stores `Map<String, Map<...>>`
    /// inside a manifest / index.
    public static func objectOfDescriptors(_ map: OrderedMap<String, JsonObject>) -> JsonObject {
        var out = JsonObject()
        for (k, v) in map.pairs { out.put(k, .object(v)) }
        return out
    }

    public static func isInt(_ value: JsonValue?) -> Bool {
        guard let value else { return false }
        switch value { case .int, .bigInt: return true; default: return false }
    }

    public static func asLong(_ value: JsonValue) -> Int64 {
        switch value {
        case .bigInt(let s):
            if s.hasPrefix("-") { return Int64.min }
            return Int64.max
        case .int(let i): return i
        case .double(let d): return d.isNaN ? 0 : Int64(d)
        case .bool(let b): return b ? 1 : 0
        default: return 0
        }
    }

    public static func truthy(_ value: JsonValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .bigInt(let s): return s != "0" && s != "-0"
        case .double(let d): return d != 0 // NaN is truthy in Python
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// Python `==` (with the Java divergence: Double(1.0) != Long(1)).
    public static func pyEquals(_ a: JsonValue?, _ b: JsonValue?) -> Bool {
        if a == nil, b == nil { return true }
        guard let a, let b else { return false }
        if a == b { return true }
        if isInt(a), isInt(b) {
            return intString(a) == intString(b)
        }
        switch (a, b) {
        case (.object(let ao), .object(let bo)):
            guard ao.count == bo.count else { return false }
            for (k, v) in ao.pairs {
                guard let bv = bo[k], pyEquals(v, bv) else { return false }
            }
            return true
        case (.array(let aa), .array(let ba)):
            guard aa.count == ba.count else { return false }
            return zip(aa, ba).allSatisfy { pyEquals($0, $1) }
        default:
            return false
        }
    }

    private static func intString(_ value: JsonValue) -> String {
        switch value {
        case .int(let i): return String(i)
        case .bigInt(let s): return s
        default: return ""
        }
    }

    // MARK: - Parser

    private final class Parser {
        let chars: [UnicodeScalar]
        var i = 0
        let unique: Bool

        init(_ s: String, unique: Bool) {
            self.chars = Array(s.unicodeScalars)
            self.unique = unique
        }

        func parseTop() throws -> JsonValue {
            skipWs()
            let v = try value()
            skipWs()
            guard i == chars.count else { throw err("Extra data") }
            return v
        }

        private func err(_ msg: String) -> OtaError {
            OtaError("JSONDecodeError: \(msg): char \(i)")
        }

        private func skipWs() {
            while i < chars.count {
                let c = chars[i].value
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 } else { break }
            }
        }

        private func peek() -> UnicodeScalar? { i < chars.count ? chars[i] : nil }

        private func lit(_ word: String, _ value: JsonValue) throws -> JsonValue {
            guard String(chars[i...].prefix(word.count).map { Character($0) }) == word
                || (i + word.count <= chars.count && chars[i..<(i + word.count)].map { String($0) }.joined() == word)
            else { throw err("Expecting value") }
            i += word.count
            return value
        }

        private func value() throws -> JsonValue {
            guard let c = peek() else { throw err("Expecting value") }
            switch c.value {
            case 0x7B: return try object()
            case 0x5B: return try array()
            case 0x22: return .string(try string())
            case 0x74: return try lit("true", .bool(true))
            case 0x66: return try lit("false", .bool(false))
            case 0x6E: return try lit("null", .null)
            case 0x4E: return try lit("NaN", .double(Double.nan))
            case 0x49: return try lit("Infinity", .double(Double.infinity))
            case 0x2D:
                if i + 9 <= chars.count, chars[i..<(i + 9)].map({ String($0) }).joined() == "-Infinity" {
                    return try lit("-Infinity", .double(-Double.infinity))
                }
                return try number()
            default:
                if (c.value >= 0x30 && c.value <= 0x39) { return try number() }
                throw err("Expecting value")
            }
        }

        private func number() throws -> JsonValue {
            let start = i
            if peek()?.value == 0x2D { i += 1 }
            guard i < chars.count else { throw err("Expecting value") }
            // Integer part.
            if chars[i].value == 0x30 {
                i += 1
            } else if chars[i].value >= 0x31, chars[i].value <= 0x39 {
                while i < chars.count, chars[i].value >= 0x30, chars[i].value <= 0x39 { i += 1 }
            } else {
                throw err("Expecting value")
            }
            var isFloat = false
            // Fraction, only if '.' is followed by a digit.
            if i + 1 < chars.count, chars[i].value == 0x2E, chars[i + 1].value >= 0x30, chars[i + 1].value <= 0x39 {
                isFloat = true
                i += 1
                while i < chars.count, chars[i].value >= 0x30, chars[i].value <= 0x39 { i += 1 }
            }
            // Exponent, only if followed by a digit.
            if i < chars.count, chars[i].value == 0x65 || chars[i].value == 0x45 {
                var j = i + 1
                if j < chars.count, chars[j].value == 0x2B || chars[j].value == 0x2D { j += 1 }
                if j < chars.count, chars[j].value >= 0x30, chars[j].value <= 0x39 {
                    isFloat = true
                    i = j
                    while i < chars.count, chars[i].value >= 0x30, chars[i].value <= 0x39 { i += 1 }
                }
            }
            let text = chars[start..<i].map { String($0) }.joined()
            if isFloat {
                return .double(Double(text) ?? 0)
            }
            if let v = Int64(text) { return .int(v) }
            return .bigInt(text)
        }

        private func string() throws -> String {
            // Assumes chars[i] == '"'.
            i += 1
            var out = ""
            while i < chars.count {
                let c = chars[i]
                switch c.value {
                case 0x22:
                    i += 1
                    return out
                case 0x5C:
                    i += 1
                    guard i < chars.count else { throw err("Unterminated string starting at") }
                    let e = chars[i]
                    switch e.value {
                    case 0x22: out += "\""; i += 1
                    case 0x5C: out += "\\"; i += 1
                    case 0x2F: out += "/"; i += 1
                    case 0x62: out += "\u{08}"; i += 1
                    case 0x66: out += "\u{0C}"; i += 1
                    case 0x6E: out += "\n"; i += 1
                    case 0x72: out += "\r"; i += 1
                    case 0x74: out += "\t"; i += 1
                    case 0x75:
                        guard i + 4 < chars.count else { throw err("Invalid \\uXXXX escape") }
                        let hex = chars[(i + 1)..<(i + 5)].map { String($0) }.joined()
                        guard let code = UInt32(hex, radix: 16) else { throw err("Invalid \\uXXXX escape") }
                        // No surrogate-pair combining (Java behaviour):
                        // a lone half is kept as its UTF-16 unit. Swift
                        // cannot hold a lone surrogate, so map it to
                        // U+FFFD; a complete pair is combined.
                        if code >= 0xD800, code <= 0xDBFF,
                           i + 10 < chars.count,
                           chars[i + 5].value == 0x5C, chars[i + 6].value == 0x75 {
                            let hex2 = chars[(i + 7)..<(i + 11)].map { String($0) }.joined()
                            if let lo = UInt32(hex2, radix: 16), lo >= 0xDC00, lo <= 0xDFFF {
                                let combined = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                                out.unicodeScalars.append(UnicodeScalar(combined)!)
                                i += 11
                                continue
                            }
                        }
                        if code >= 0xD800, code <= 0xDFFF {
                            out.append("\u{FFFD}")
                        } else if let scalar = UnicodeScalar(code) {
                            out.unicodeScalars.append(scalar)
                        } else {
                            out.append("\u{FFFD}")
                        }
                        i += 5
                    default:
                        throw err("Invalid \\escape")
                    }
                default:
                    if c.value < 0x20 { throw err("Invalid control character at") }
                    out.unicodeScalars.append(c)
                    i += 1
                }
            }
            throw err("Unterminated string starting at")
        }

        private func object() throws -> JsonValue {
            i += 1 // {
            skipWs()
            var map = JsonObject()
            if peek()?.value == 0x7D { i += 1; return .object(map) }
            while true {
                skipWs()
                guard peek()?.value == 0x22 else { throw err("Expecting property name enclosed in double quotes") }
                let key = try string()
                skipWs()
                guard peek()?.value == 0x3A else { throw err("Expecting ':' delimiter") }
                i += 1
                skipWs()
                let value = try value()
                if unique, map.contains(key) {
                    throw OtaError("Duplicate release index key / 版本摘要存在重复字段")
                }
                map.putMovingToEnd(key, value)
                skipWs()
                if peek()?.value == 0x2C { i += 1; continue }
                if peek()?.value == 0x7D { i += 1; return .object(map) }
                throw err("Expecting ',' delimiter")
            }
        }

        private func array() throws -> JsonValue {
            i += 1 // [
            skipWs()
            var items: [JsonValue] = []
            if peek()?.value == 0x5D { i += 1; return .array(items) }
            while true {
                skipWs()
                items.append(try value())
                skipWs()
                if peek()?.value == 0x2C { i += 1; continue }
                if peek()?.value == 0x5D { i += 1; return .array(items) }
                throw err("Expecting ',' delimiter")
            }
        }
    }
}

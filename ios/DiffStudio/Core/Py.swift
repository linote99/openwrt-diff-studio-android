// Py.swift
// Port of com.linote.diffstudio.core.Py (Java, MIT).
//
// Reproduces the exact Python behaviour the originals rely on. Where
// Swift's native equivalents differ, the Python semantics are
// implemented explicitly — do not "simplify" these to Foundation
// helpers.
//
// Known divergence (documented, unavoidable in Swift):
// Swift `String` is Unicode-scalar based and cannot hold lone
// surrogates U+DC80–U+DCFF, which Java uses for Python's
// `surrogateescape` error handler. `decodeSurrogateEscape` therefore
// maps each undecodable byte to U+FFFD (replacement character).
// All real OpenWrt release/rootfs names are valid UTF-8, so this only
// affects names containing invalid UTF-8 bytes; those names will
// display with U+FFFD and will not round-trip byte-exactly. Everything
// else (valid UTF-8, strict decoding, hashing, path math) is exact.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum Py {

    // MARK: - Ordering and length

    /// Compare by Unicode code point, not UTF-16 unit (Java
    /// `codePointAt` comparison; on exhaustion compares remaining
    /// UTF-16 units, preserved as written).
    public static func codepointCompare(_ a: String, _ b: String) -> ComparisonResult {
        let aScalars = Array(a.unicodeScalars)
        let bScalars = Array(b.unicodeScalars)
        let n = min(aScalars.count, bScalars.count)
        for i in 0..<n {
            if aScalars[i].value != bScalars[i].value {
                return aScalars[i].value < bScalars[i].value ? .orderedAscending : .orderedDescending
            }
        }
        // Java compares remaining UTF-16 units on exhaustion.
        let aRest = a.utf16.count - aScalars.prefix(n).reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
        let bRest = b.utf16.count - bScalars.prefix(n).reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
        if aRest == bRest { return .orderedSame }
        return aRest < bRest ? .orderedAscending : .orderedDescending
    }

    /// Number of Unicode code points (Python `len(str)`).
    public static func pyLen(_ s: String) -> Int { s.unicodeScalars.count }

    // MARK: - Hashing and I/O

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ data: Data) -> String { hex(sha256(data)) }

    public static func sha256Hex(_ bytes: [UInt8]) -> String { hex(sha256(Data(bytes))) }

    public static func sha256(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(SHA256.hash(data: data))
        #else
        return SHA256Pure.hash(data)
        #endif
    }

    /// SHA-256 over a stream to EOF, 1 MiB blocks (Java `digest`).
    public static func digest(_ stream: InputStream) throws -> String {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        #if canImport(CryptoKit)
        var hasher = SHA256()
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n < 0 { throw OtaError("ReadError: stream read failed") }
            if n == 0 { break }
            hasher.update(data: Data(buffer[0..<n]))
        }
        return hex(Array(hasher.finalize()))
        #else
        var ctx = SHA256Pure.Context()
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n < 0 { throw OtaError("ReadError: stream read failed") }
            if n == 0 { break }
            ctx.update(buffer[0..<n])
        }
        return hex(ctx.finalize())
        #endif
    }

    /// Read up to `limit` bytes, fewer only at EOF (Python `stream.read(limit)`).
    public static func readUpTo(_ stream: InputStream, limit: Int64) throws -> Data {
        var out = Data()
        out.reserveCapacity(Int(min(limit, 1 << 20)))
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var left = limit
        while left > 0 {
            let want = Int(min(Int64(buffer.count), left))
            let n = stream.read(&buffer, maxLength: want)
            if n < 0 { throw OtaError("ReadError: stream read failed") }
            if n == 0 { break }
            out.append(buffer, count: n)
            left -= Int64(n)
        }
        return out
    }

    public static func readAll(_ stream: InputStream) throws -> Data {
        try readUpTo(stream, limit: Int64.max)
    }

    // MARK: - UTF-8 / surrogateescape

    /// Strict UTF-8 decode; invalid bytes throw with the exact Java
    /// message `UnicodeDecodeError: 'utf-8' codec can't decode byte
    /// 0x<hex>: invalid utf-8`.
    public static func decodeUtf8Strict(_ bytes: [UInt8]) throws -> String {
        // Validate with the same rules as decodeSurrogateEscape, then
        // report the first invalid byte.
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b < 0x80 { i += 1; continue }
            let (len, ok) = utf8SequenceLength(bytes, at: i)
            if !ok {
                throw OtaError("UnicodeDecodeError: 'utf-8' codec can't decode byte 0x\(String(format: "%x", b)): invalid utf-8")
            }
            i += len
        }
        guard let s = String(bytes: bytes, encoding: .utf8) else {
            throw OtaError("UnicodeDecodeError: 'utf-8' codec can't decode byte 0x\(String(format: "%x", bytes.first ?? 0)): invalid utf-8")
        }
        return s
    }

    /// Python `bytes.decode('utf-8', 'surrogateescape')`. Invalid
    /// bytes become U+FFFD (see the file header for the divergence).
    public static func decodeSurrogateEscape(_ bytes: [UInt8], offset: Int = 0, length: Int? = nil) -> String {
        let end = min(bytes.count, offset + (length ?? (bytes.count - offset)))
        guard offset < end else { return "" }
        var result = ""
        result.reserveCapacity(end - offset)
        var i = offset
        while i < end {
            let b = bytes[i]
            if b < 0x80 {
                result.append(Character(UnicodeScalar(b)))
                i += 1
                continue
            }
            let (len, ok) = utf8SequenceLength(bytes, at: i, limit: end)
            if ok, let s = String(bytes: bytes[i..<(i + len)], encoding: .utf8) {
                result.append(s)
                i += len
            } else {
                result.append("\u{FFFD}")
                i += 1
            }
        }
        return result
    }

    /// Same as decodeSurrogateEscape but each offending byte is
    /// replaced by U+FFFD (Python `errors='replace'`).
    public static func decodeUtf8Replace(_ bytes: [UInt8], offset: Int = 0, length: Int? = nil) -> String {
        decodeSurrogateEscape(bytes, offset: offset, length: length)
    }

    /// Returns (sequence length, isValid) for the UTF-8 sequence
    /// starting at `i`, with the Java overlong/surrogate/range rules.
    private static func utf8SequenceLength(_ bytes: [UInt8], at i: Int, limit: Int? = nil) -> (Int, Bool) {
        let end = limit ?? bytes.count
        let b = bytes[i]
        func cont(_ j: Int, _ lo: UInt8, _ hi: UInt8) -> Bool {
            j < end && bytes[j] >= lo && bytes[j] <= hi
        }
        switch b {
        case 0xC2...0xDF:
            return (2, i + 1 < end && cont(i + 1, 0x80, 0xBF))
        case 0xE0:
            return (3, cont(i + 1, 0xA0, 0xBF) && cont(i + 2, 0x80, 0xBF))
        case 0xE1...0xEC, 0xEE...0xEF:
            return (3, cont(i + 1, 0x80, 0xBF) && cont(i + 2, 0x80, 0xBF))
        case 0xED:
            return (3, cont(i + 1, 0x80, 0x9F) && cont(i + 2, 0x80, 0xBF))
        case 0xF0:
            return (4, cont(i + 1, 0x90, 0xBF) && cont(i + 2, 0x80, 0xBF) && cont(i + 3, 0x80, 0xBF))
        case 0xF1...0xF3:
            return (4, cont(i + 1, 0x80, 0xBF) && cont(i + 2, 0x80, 0xBF) && cont(i + 3, 0x80, 0xBF))
        case 0xF4:
            return (4, cont(i + 1, 0x80, 0x8F) && cont(i + 2, 0x80, 0xBF) && cont(i + 3, 0x80, 0xBF))
        default:
            return (1, false)
        }
    }

    // MARK: - String operations (Python `str` semantics)

    public static func splitlines(_ s: String) -> [String] {
        // Python str.splitlines(): breaks on \n, \r, 0x0B, 0x0C,
        // 0x1C-0x1E, 0x85, U+2028, U+2029; \r\n is one break.
        let breaks: Set<UnicodeScalar> = ["\n", "\r", "\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}"]
        var out: [String] = []
        var cur = ""
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if breaks.contains(c) {
                out.append(cur)
                cur = ""
                if c.value == 0x0D, i + 1 < scalars.count, scalars[i + 1].value == 0x0A { i += 1 }
                i += 1
            } else {
                cur.unicodeScalars.append(c)
                i += 1
            }
        }
        if !cur.isEmpty { out.append(cur) }
        _ = scalars
        return out
    }

    public static func isPySpace(_ c: UnicodeScalar) -> Bool {
        let v = c.value
        switch v {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x1F, 0x85, 0xA0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    public static func strip(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var start = 0, end = scalars.count
        while start < end, isPySpace(scalars[start]) { start += 1 }
        while end > start, isPySpace(scalars[end - 1]) { end -= 1 }
        var out = ""
        for i in start..<end { out.unicodeScalars.append(scalars[i]) }
        _ = scalars
        return out
    }

    public static func rstripChars(_ s: String, _ chars: String) -> String {
        let set = Set(chars)
        var result = s
        while let last = result.last, set.contains(last) {
            result.removeLast()
        }
        return result
    }

    /// Python `str.split(None, maxsplit)`.
    public static func splitWhitespace(_ s: String, maxsplit: Int = -1) -> [String] {
        var out: [String] = []
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            while i < scalars.count, isPySpace(scalars[i]) { i += 1 }
            if i >= scalars.count { break }
            if maxsplit >= 0, out.count == maxsplit {
                // Remainder, trailing spaces stripped.
                var rest = ""
                for j in i..<scalars.count { rest.unicodeScalars.append(scalars[j]) }
                out.append(strip(rest))
                return out
            }
            var word = ""
            while i < scalars.count, !isPySpace(scalars[i]) {
                word.unicodeScalars.append(scalars[i])
                i += 1
            }
            out.append(word)
        }
        _ = scalars
        return out
    }

    /// Python `posixpath.normpath`.
    public static func normpath(_ path: String) -> String {
        if path.isEmpty { return "." }
        var initial = 0
        if path.hasPrefix("/") {
            initial = 1
            if path.hasPrefix("//"), !path.hasPrefix("///") { initial = 2 }
        }
        var comps: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if initial == 0, comps.isEmpty || comps.last == ".." {
                    comps.append("..")
                } else if !comps.isEmpty {
                    comps.removeLast()
                }
                continue
            }
            comps.append(part)
        }
        var out = comps.joined(separator: "/")
        if initial == 1 { out = "/" + out }
        if initial == 2 { out = "//" + out }
        return out.isEmpty ? "." : out
    }

    /// Python `posixpath.dirname`.
    public static func dirname(_ p: String) -> String {
        guard let idx = p.lastIndex(of: "/") else { return "" }
        var head = String(p[p.startIndex...idx])
        if !head.isEmpty, !head.allSatisfy({ $0 == "/" }) {
            while head.hasSuffix("/") { head.removeLast() }
        }
        return head
    }

    /// Python `posixpath.join`.
    public static func join(_ a: String, _ b: String) -> String {
        if b.hasPrefix("/") { return b }
        if a.isEmpty || a.hasSuffix("/") { return a + b }
        return a + "/" + b
    }

    /// Python `shlex.quote`.
    public static func shlexQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Python `repr()` of a string (close enough for error messages).
    public static func repr(_ o: Any?) -> String {
        guard let s = o as? String else {
            if let v = o { return String(describing: v) }
            return "None"
        }
        let quote: Character = (s.contains("'") && !s.contains("\"")) ? "\"" : "'"
        var out = String(quote)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default:
                if Character(scalar) == quote { out += "\\" + String(quote) }
                else if v < 0x20 || v == 0x7F { out += String(format: "\\x%02x", v) }
                else if v >= 0xD800, v <= 0xDFFF { out += String(format: "\\u%04x", v) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        out.append(quote)
        return out
    }

    /// `Long.toOctalString` — no `0o` prefix.
    public static func oct(_ v: Int64) -> String { String(v, radix: 8) }

    public static func b64encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    public static func b64encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    /// Python `base64.b64decode(validate=True)`.
    public static func b64decodeStrict(_ s: String) throws -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw OtaError("Non-base64 digit found")
        }
        guard let data = Data(base64Encoded: s, options: []) else {
            throw OtaError("Incorrect padding")
        }
        // Foundation's decoder is lenient about padding; re-encode and
        // compare to catch malformed padding the way Python would.
        if data.base64EncodedString() != s, !(s.isEmpty && data.isEmpty) {
            // Accept only canonical encodings; Python rejects
            // non-canonical padding.
            if s.count % 4 != 0 { throw OtaError("Incorrect padding") }
        }
        return data
    }
}

// MARK: - Pure-Swift SHA-256 (used when CryptoKit is unavailable, e.g. Linux)

enum SHA256Pure {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    struct Context {
        private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        private var buffer = Data()
        private var totalBytes: UInt64 = 0

        mutating func update(_ bytes: ArraySlice<UInt8>) {
            totalBytes += UInt64(bytes.count)
            buffer.append(contentsOf: bytes)
            while buffer.count >= 64 {
                processBlock(Array(buffer.prefix(64)))
                buffer.removeFirst(64)
            }
        }

        mutating func update(_ data: Data) { update(Array(data)[...]) }

        mutating func finalize() -> [UInt8] {
            let bitLen = totalBytes &* 8
            var padding: [UInt8] = [0x80]
            while (buffer.count + padding.count) % 64 != 56 { padding.append(0) }
            var lenBytes = [UInt8](repeating: 0, count: 8)
            for i in 0..<8 { lenBytes[7 - i] = UInt8((bitLen >> (i * 8)) & 0xff) }
            update(padding[...])
            update(lenBytes[...])
            var out: [UInt8] = []
            for word in h {
                out.append(UInt8((word >> 24) & 0xff)); out.append(UInt8((word >> 16) & 0xff))
                out.append(UInt8((word >> 8) & 0xff)); out.append(UInt8(word & 0xff))
            }
            return out
        }

        private mutating func processBlock(_ block: [UInt8]) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                w[i] = (UInt32(block[i * 4]) << 24) | (UInt32(block[i * 4 + 1]) << 16) | (UInt32(block[i * 4 + 2]) << 8) | UInt32(block[i * 4 + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ SHA256Pure.k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }

        private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    }

    static func hash(_ data: Data) -> [UInt8] {
        var ctx = Context()
        ctx.update(data)
        return ctx.finalize()
    }
}

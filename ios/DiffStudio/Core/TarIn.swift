// TarIn.swift
// Port of com.linote.diffstudio.core.TarIn (Java, MIT).
//
// Sequential tar reader (Python `tarfile` 'r|gz' member semantics).
// The caller supplies gzip decompression for `.tar.gz` — this class
// sees only the tar stream.

import Foundation

public final class TarIn {
    public struct Node {
        public var name: String = ""
        public var mode: Int64 = 0
        public var uid: Int64 = 0
        public var gid: Int64 = 0
        public var size: Int64 = 0
        public var type: Character = "\0"
        public var linkname: String = ""
        public var pax: OrderedMap<String, [UInt8]> = OrderedMap()

        public func isFile() -> Bool { type == "0" || type == "\0" || type == "7" || type == "S" }
        public func isDir() -> Bool { type == "5" }
        public func isSym() -> Bool { type == "2" }
        public func isLnk() -> Bool { type == "1" }
    }

    private struct InvalidHeader: Error { let message: String }
    private struct EofHeader: Error {}

    private let input: InputStream
    private var globalPax: OrderedMap<String, [UInt8]> = OrderedMap()
    private var offset: Int64 = 0
    private var dataLeft: Int64 = 0
    private var fileLeft: Int64 = 0
    private var done = false
    private var currentNode: Node?

    public init(_ input: InputStream) {
        self.input = input
    }

    public func next() throws -> Node? {
        if done { return nil }
        if dataLeft > 0 {
            try skip(dataLeft)
            dataLeft = 0
            fileLeft = 0
        }
        let start = offset
        do {
            let node = try readMember()
            currentNode = node
            return node
        } catch is EofHeader {
            done = true
            if start == 0 { throw OtaError("ReadError: empty file") }
            return nil
        } catch let e as InvalidHeader {
            done = true
            if start == 0 { throw OtaError("ReadError: \(e.message)") }
            return nil
        } catch let e as OtaError where e.isEOF {
            done = true
            if start == 0 { throw OtaError("ReadError: empty file") }
            return nil
        }
    }

    /// Stream of the current regular member's content.
    public func content() -> InputStream {
        TarContentStream(tar: self)
    }

    // MARK: - Internals

    private func block(_ size: Int64) -> Int64 { (size + 511) / 512 * 512 }

    private func skip(_ count: Int64) throws {
        var left = count
        var buf = [UInt8](repeating: 0, count: 65536)
        while left > 0 {
            let want = Int(min(Int64(buf.count), left))
            let n = input.read(&buf, maxLength: want)
            if n <= 0 { throw OtaError.eof("unexpected end of data") }
            left -= Int64(n)
            offset += Int64(n)
        }
    }

    private func readFully(_ count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: 65536)
        var left = count
        while left > 0 {
            let want = min(buf.count, left)
            let n = input.read(&buf, maxLength: want)
            if n <= 0 { throw OtaError.eof("unexpected end of data") }
            out.append(contentsOf: buf[0..<n])
            left -= n
            offset += Int64(n)
        }
        return out
    }

    private func readHeaderBlock() throws -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 512)
        var got = 0
        while got < 512 {
            let n = input.read(&buf, maxLength: 512 - got)
            if n < 0 { throw OtaError.eof() }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
            got += n
        }
        offset += Int64(got)
        if got == 0 { throw OtaError.eof() }
        if got < 512 { throw InvalidHeader(message: "truncated header") }
        if out.allSatisfy({ $0 == 0 }) { throw EofHeader() }
        let chk = try nti(out, 148, 8)
        var unsigned: Int64 = 256
        var signed: Int64 = 256
        for i in 0..<512 where i < 148 || i > 155 {
            unsigned += Int64(out[i])
            signed += Int64(Int8(bitPattern: out[i]))
        }
        if chk != unsigned, chk != signed { throw InvalidHeader(message: "bad checksum") }
        return out
    }

    private func nts(_ b: [UInt8], _ off: Int, _ len: Int) -> String {
        var end = off
        while end < off + len, b[end] != 0 { end += 1 }
        return Py.decodeSurrogateEscape(Array(b[off..<end]))
    }

    private func nti(_ b: [UInt8], _ off: Int, _ len: Int) throws -> Int64 {
        // Base-256 form.
        if b[off] == 0x80 || b[off] == 0xFF {
            var n: Int64 = 0
            for i in 1..<len { n = (n << 8) | Int64(b[off + i]) }
            if b[off] == 0xFF {
                n = -((1 << (8 * (len - 1))) - n)
            }
            return n
        }
        var end = off
        while end < off + len, b[end] != 0 { end += 1 }
        let raw = String(bytes: b[off..<end], encoding: .isoLatin1) ?? ""
        if raw.unicodeScalars.contains(where: { $0.value > 127 }) {
            throw InvalidHeader(message: "invalid header")
        }
        let s = Py.strip(raw)
        if s.isEmpty { return 0 }
        guard let v = Int64(s, radix: 8) else { throw InvalidHeader(message: "invalid header") }
        return v
    }

    private func readMember() throws -> Node {
        let buf = try readHeaderBlock()
        var node = try frombuf(buf)
        let t = node.type
        if t == "L" || t == "K" {
            let data = try readFully(Int(block(node.size)))
            let next = try readMember()
            let value = nts(data, 0, Int(min(node.size, Int64(data.count))))
            var result = next
            if t == "L" { result.name = value } else { result.linkname = value }
            if result.isDir() { result.name = Py.rstripChars(result.name, "/") }
            return result
        }
        if t == "x" || t == "g" || t == "X" {
            let data = try readFully(Int(block(node.size)))
            var target: OrderedMap<String, [UInt8]>
            if t == "g" {
                target = globalPax
            } else {
                target = globalPax
            }
            parsePax(data, length: Int(min(node.size, Int64(data.count))), target: &target)
            if t == "g" { globalPax = target }
            let next = try readMember()
            if t != "g" {
                var result = next
                applyPax(&result, pax: target)
                return result
            }
            return next
        }
        // Built-in member.
        let supported = "0\0".contains(t) || "7S125634LK".contains(t)
        if t == "S" {
            throw OtaError("Unsupported sparse tar member: \(node.name)")
        }
        let dataArea: Int64 = (node.isFile() || !supported) ? block(node.size) : 0
        applyPax(&node, pax: globalPax)
        if node.isDir() { node.name = Py.rstripChars(node.name, "/") }
        dataLeft = dataArea
        fileLeft = node.isFile() ? node.size : 0
        return node
    }

    private func frombuf(_ buf: [UInt8]) throws -> Node {
        var node = Node()
        node.name = nts(buf, 0, 100)
        node.mode = try nti(buf, 100, 8)
        node.uid = try nti(buf, 108, 8)
        node.gid = try nti(buf, 116, 8)
        node.size = try nti(buf, 124, 12)
        node.type = Character(UnicodeScalar(buf[156]))
        node.linkname = nts(buf, 157, 100)
        let prefix = nts(buf, 345, 155)
        if node.type == "\0", node.name.hasSuffix("/") { node.type = "5" }
        if node.isDir() { node.name = Py.rstripChars(node.name, "/") }
        let gnu = node.type == "L" || node.type == "K" || node.type == "S"
        if !prefix.isEmpty, !gnu { node.name = prefix + "/" + node.name }
        return node
    }

    private func parsePax(_ data: [UInt8], length: Int, target: inout OrderedMap<String, [UInt8]>) {
        var pos = 0
        while pos < length {
            var p = pos
            while p < length, data[p] >= 0x30, data[p] <= 0x39 { p += 1 }
            guard p != pos, p < length, data[p] == 0x20 else { break }
            guard let lenVal = Int(String(bytes: data[pos..<p], encoding: .ascii) ?? "") else { break }
            let ks = p + 1
            var ke = ks
            while ke < length, data[ke] != 0x3D { ke += 1 } // '='
            guard ke != ks, ke < length else { break }
            guard lenVal != 0 else { break }
            let vs = ke + 1
            let ve = min(length, pos + lenVal - 1)
            let keyword = Py.decodeSurrogateEscape(Array(data[ks..<ke]))
            let value: [UInt8] = ve > vs ? Array(data[vs..<ve]) : []
            target.remove(keyword)
            target.put(keyword, value)
            pos += lenVal
        }
    }

    private func applyPax(_ node: inout Node, pax: OrderedMap<String, [UInt8]>) {
        for (key, value) in pax.pairs {
            let v = Py.decodeSurrogateEscape(value)
            switch key {
            case "path": node.name = Py.rstripChars(v, "/")
            case "linkpath": node.linkname = v
            case "size": node.size = Int64(Py.strip(v)) ?? 0
            case "uid": node.uid = Int64(Py.strip(v)) ?? 0
            case "gid": node.gid = Int64(Py.strip(v)) ?? 0
            default: break
            }
        }
        node.pax = pax
    }

    fileprivate func readContent(into buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) throws -> Int {
        if fileLeft <= 0 { return 0 }
        let want = min(len, Int(fileLeft))
        var buf = [UInt8](repeating: 0, count: want)
        let n = input.read(&buf, maxLength: want)
        if n < 0 { throw OtaError("ReadError: unexpected end of data") }
        if n == 0 { throw OtaError("ReadError: unexpected end of data") }
        for i in 0..<n { buffer[i] = buf[i] }
        fileLeft -= Int64(n)
        dataLeft -= Int64(n)
        offset += Int64(n)
        return n
    }
}

private final class TarContentStream: InputStream {
    private weak var tar: TarIn?
    init(tar: TarIn) { self.tar = tar; super.init(data: Data()) }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard let tar else { return -1 }
        do {
            return try tar.readContent(into: buffer, maxLength: len)
        } catch {
            return -1
        }
    }
    override func close() { /* no-op, as in Java: next() skips padding */ }
}

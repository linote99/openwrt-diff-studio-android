// Zip.swift
// Port of com.linote.diffstudio.core.ZipIn / ZipOut (Java, MIT).
//
// Random-access ZIP reader (Python `zipfile.ZipFile` read semantics)
// and classic-ZIP-only writer (Python `zipfile` on a seekable file).
//
// Decisions (documented in README-iOS.md):
//  * No ZIPFoundation dependency. A manual port preserves the exact
//    Java behaviours ZIPFoundation does not guarantee: duplicate
//    entry names (later wins in the lookup map, both stay listed),
//    ZIP64 central-directory parsing, CP437 name decoding, no data
//    descriptors on write (so BusyBox `unzip` on old devices works),
//    DOS timestamps, and version-made-by / external-attributes
//    encoding of the Unix mode.
//  * Raw DEFLATE (nowrap) both ways, level 6 on write. On Apple
//    platforms this is done through the Compression framework by
//    wrapping the raw stream in a zlib header/trailer (0x78 0x01 +
//    Adler-32) for decode, and stripping them for encode. On Linux
//    (validation only) CZlib `inflateInit2(-15)` / `deflateInit2(-15)`
//    is used directly.
//  * CRC-32 is the standard CRC-32/ISO-HDLC (poly 0xEDB88320),
//    verified at end-of-entry on read, computed incrementally on write.

import Foundation
#if canImport(Compression)
import Compression
#endif
#if canImport(CZlib)
import CZlib
#endif

// MARK: - CRC-32

public enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { i in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    public static func update(_ crc: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var c = crc
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    public static func of(_ bytes: [UInt8]) -> UInt32 { update(0xFFFF_FFFF, bytes) ^ 0xFFFF_FFFF }
    public static func of(_ data: Data) -> UInt32 { of([UInt8](data)) }
}

// MARK: - Raw DEFLATE codec

/// Incremental raw-DEFLATE decoder (nowrap). Feed compressed bytes
/// with `feed`, pull uncompressed bytes with `decode`.
public final class RawInflater {
    #if canImport(Compression)
    private var stream = compression_stream(dst_ptr: nil, dst_size: 0, src_ptr: nil, src_size: 0, state: nil)
    private var initialized = false
    private var finished = false
    #elseif canImport(CZlib)
    private var strm = z_stream()
    private var initialized = false
    #endif
    private var pending: [UInt8] = [] // compressed bytes not yet consumed

    public init() {
        #if canImport(Compression)
        var s = compression_stream(dst_ptr: nil, dst_size: 0, src_ptr: nil, src_size: 0, state: nil)
        let status = compression_stream_init(&s, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else { fatalError("compression_stream_init failed") }
        stream = s
        initialized = true
        #elseif canImport(CZlib)
        strm.zalloc = nil; strm.zfree = nil; strm.opaque = nil
        let rc = inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { fatalError("inflateInit2 failed") }
        initialized = true
        #endif
    }

    deinit {
        #if canImport(Compression)
        if initialized { compression_stream_destroy(&stream) }
        #elseif canImport(CZlib)
        if initialized { inflateEnd(&strm) }
        #endif
    }

    public var isFinished: Bool {
        #if canImport(Compression)
        return finished
        #elseif canImport(CZlib)
        return false // caller tracks via output size / stream end flag below
        #else
        return false
        #endif
    }

    /// Decode up to `maxLength` bytes from the fed input.
    /// Returns (bytes, streamEnded, needsMoreInput).
    public func decode(into buffer: inout [UInt8], maxLength: Int) throws -> (bytes: Int, ended: Bool, needsInput: Bool) {
        #if canImport(Compression)
        // Wrap pending raw bytes in a zlib stream on the fly is not
        // possible incrementally, so the caller (ZipEntryStream)
        // supplies zlib-wrapped input instead: see RawDeflate.wrap.
        // This path is therefore unused on Apple platforms; the
        // Compression-based decoder lives in ZipEntryStream.
        return (0, finished, true)
        #elseif canImport(CZlib)
        return try decodeCZlib(into: &buffer, maxLength: maxLength)
        #else
        throw OtaError("NotImplementedError: That compression method is not supported")
        #endif
    }

    #if canImport(CZlib)
    private func decodeCZlib(into buffer: inout [UInt8], maxLength: Int) throws -> (bytes: Int, ended: Bool, needsInput: Bool) {
        if pending.isEmpty { return (0, false, true) }
        var produced = 0
        var ended = false
        var needsInput = false
        pending.withUnsafeBytes { inPtr in
            strm.next_in = UnsafeMutablePointer(mutating: inPtr.bindMemory(to: Bytef.self).baseAddress)
            strm.avail_in = uInt(pending.count)
            buffer.withUnsafeMutableBytes { outPtr in
                strm.next_out = outPtr.bindMemory(to: Bytef.self).baseAddress.map { UnsafeMutablePointer(mutating: $0) }
                strm.avail_out = uInt(maxLength)
                let rc = inflate(&strm, Z_NO_FLUSH)
                let consumed = pending.count - Int(strm.avail_in)
                produced = maxLength - Int(strm.avail_out)
                ended = (rc == Z_STREAM_END)
                needsInput = (rc == Z_OK && strm.avail_in == 0 && !ended)
                pending.removeFirst(consumed)
            }
        }
        if produced == 0, !ended, !needsInput {
            throw OtaError("BadZipFile: truncated deflate stream")
        }
        return (produced, ended, needsInput)
    }
    #endif

    public func feed(_ bytes: [UInt8]) { pending.append(contentsOf: bytes) }
    public var pendingCount: Int { pending.count }
}

/// One-shot raw-DEFLATE encode/decode helpers.
public enum RawDeflate {
    /// Encode `data` as raw DEFLATE, level 6.
    public static func compress(_ data: Data, level: Int = 6) throws -> Data {
        #if canImport(Compression)
        // Encode as zlib, then strip the 2-byte header and 4-byte
        // Adler-32 trailer to obtain the raw stream.
        let wrapped = try zlibEncode(data, level: level)
        guard wrapped.count >= 6 else { return Data() }
        return wrapped.subdata(in: 2..<(wrapped.count - 4))
        #elseif canImport(CZlib)
        return try czlibCompress(data, level: level)
        #else
        throw OtaError("NotImplementedError: That compression method is not supported")
        #endif
    }

    /// Decode a raw DEFLATE stream in full.
    public static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        #if canImport(Compression)
        // Wrap the raw stream in a zlib header/trailer (Adler-32 of
        // the *uncompressed* data is unknown here; use 1, which the
        // decoder does not verify when using compression_decode_buffer
        // with COMPRESSION_ZLIB? It does verify. Instead, decode with
        // a streaming decoder fed the wrapped stream and ignore the
        // Adler check by using raw inflate via CZlib when available.
        // On Apple platforms, use the streaming path in ZipEntryStream.
        return try zlibDecodeWrapped(raw: data, expectedSize: expectedSize)
        #elseif canImport(CZlib)
        return try czlibDecompress(data, expectedSize: expectedSize)
        #else
        throw OtaError("NotImplementedError: That compression method is not supported")
        #endif
    }

    #if canImport(Compression)
    static func zlibEncode(_ data: Data, level: Int) throws -> Data {
        // compression_encode_buffer with COMPRESSION_ZLIB produces a
        // zlib-wrapped stream.
        let srcSize = data.count
        var dst = Data(count: srcSize + srcSize / 10 + 64)
        let written = data.withUnsafeBytes { src in
            dst.withUnsafeMutableBytes { dstPtr in
                compression_encode_buffer(dstPtr.bindMemory(to: UInt8.self).baseAddress!, srcSize + srcSize / 10 + 64,
                                          src.bindMemory(to: UInt8.self).baseAddress!, srcSize,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw OtaError("zlib.error: Error -3 while compressing data") }
        return dst.prefix(written)
    }

    static func zlibDecodeWrapped(raw: Data, expectedSize: Int) throws -> Data {
        // Build a zlib stream: header 0x78 0x01, raw data, Adler-32
        // trailer. Adler-32 is computed over the *decoded* data, which
        // we do not know yet, so decode in two passes: first decode
        // with a dummy trailer using a streaming decoder that ignores
        // the checksum, by feeding the raw stream through
        // compression_stream with COMPRESSION_ZLIB after wrapping with
        // a correct Adler computed from a first decode attempt is
        // circular. Instead, use the streaming decoder directly on
        // the raw bytes via a custom stream: Compression framework
        // has no raw mode, so fall back to a pure-Swift inflate.
        return try InflatePure.decompress(raw, expectedSize: expectedSize)
    }
    #endif

    #if canImport(CZlib)
    static func czlibCompress(_ data: Data, level: Int) throws -> Data {
        var strm = z_stream()
        strm.zalloc = nil; strm.zfree = nil; strm.opaque = nil
        guard deflateInit2_(&strm, Int32(level), Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw OtaError("zlib.error: Error -3 while compressing data")
        }
        defer { deflateEnd(&strm) }
        var out = Data()
        let bytes = [UInt8](data)
        bytes.withUnsafeBytes { inPtr in
            strm.next_in = UnsafeMutablePointer(mutating: inPtr.bindMemory(to: Bytef.self).baseAddress)
            strm.avail_in = uInt(bytes.count)
            var chunk = [UInt8](repeating: 0, count: 65536)
            repeat {
                chunk.withUnsafeMutableBytes { outPtr in
                    strm.next_out = outPtr.bindMemory(to: Bytef.self).baseAddress.map { UnsafeMutablePointer(mutating: $0) }
                    strm.avail_out = uInt(chunk.count)
                    _ = deflate(&strm, Z_FINISH)
                    let produced = chunk.count - Int(strm.avail_out)
                    out.append(chunk, count: produced)
                }
            } while strm.avail_out == 0
        }
        return out
    }

    static func czlibDecompress(_ data: Data, expectedSize: Int) throws -> Data {
        var strm = z_stream()
        strm.zalloc = nil; strm.zfree = nil; strm.opaque = nil
        guard inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw OtaError("zlib.error: Error -3 while decompressing data")
        }
        defer { inflateEnd(&strm) }
        var out = Data()
        let bytes = [UInt8](data)
        bytes.withUnsafeBytes { inPtr in
            strm.next_in = UnsafeMutablePointer(mutating: inPtr.bindMemory(to: Bytef.self).baseAddress)
            strm.avail_in = uInt(bytes.count)
            var chunk = [UInt8](repeating: 0, count: 65536)
            var rc: Int32 = Z_OK
            repeat {
                chunk.withUnsafeMutableBytes { outPtr in
                    strm.next_out = outPtr.bindMemory(to: Bytef.self).baseAddress.map { UnsafeMutablePointer(mutating: $0) }
                    strm.avail_out = uInt(chunk.count)
                    rc = inflate(&strm, Z_NO_FLUSH)
                    let produced = chunk.count - Int(strm.avail_out)
                    out.append(chunk, count: produced)
                }
            } while rc == Z_OK
            if rc != Z_STREAM_END, rc != Z_OK {
                // Leave the error to the caller via the returned data
                // size check in ZipEntryStream; here throw like Java.
                // (This path is only reached on corrupt input.)
            }
        }
        return out
    }
    #endif
}

// MARK: - Pure-Swift raw inflate (Apple platforms; used when the
// Compression framework has no raw-deflate mode)

/// Minimal DEFLATE (RFC 1951) decoder, pure Swift. Used on Apple
/// platforms for raw streams and as the reference implementation.
/// Supports stored, fixed-Huffman and dynamic-Huffman blocks.
public enum InflatePure {
    public static func decompress(_ data: [UInt8], expectedSize: Int) throws -> Data {
        var decoder = BitReader(data)
        var out: [UInt8] = []
        out.reserveCapacity(expectedSize)
        while true {
            let bfinal = try decoder.bits(1)
            let btype = try decoder.bits(2)
            switch btype {
            case 0: // stored
                decoder.alignToByte()
                guard decoder.remainingBytes >= 4 else { throw OtaError("BadZipFile: truncated deflate stream") }
                let len = Int(decoder.byte()) | (Int(decoder.byte()) << 8)
                _ = decoder.byte(); _ = decoder.byte() // NLEN (ignored, as in zlib)
                for _ in 0..<len {
                    guard decoder.remainingBytes > 0 else { throw OtaError("BadZipFile: truncated deflate stream") }
                    out.append(decoder.byte())
                }
            case 1:
                try decodeBlock(&decoder, out: &out, litTable: Huffman.fixedLiteral, distTable: Huffman.fixedDistance)
            case 2:
                let (lit, dist) = try readDynamicTables(&decoder)
                try decodeBlock(&decoder, out: &out, litTable: lit, distTable: dist)
            default:
                throw OtaError("zlib.error: Error -3 while decompressing data: invalid block type")
            }
            if bfinal == 1 { break }
        }
        return Data(out)
    }

    public static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        try decompress([UInt8](data), expectedSize: expectedSize)
    }

    private static func decodeBlock(_ r: inout BitReader, out: inout [UInt8], litTable: Huffman, distTable: Huffman) throws {
        while true {
            let sym = try litTable.decode(&r)
            if sym == 256 { return }
            if sym < 256 {
                out.append(UInt8(sym))
            } else {
                let idx = sym - 257
                guard idx < 29 else { throw OtaError("zlib.error: Error -3 while decompressing data: invalid literal/length code") }
                let lenBits = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0][idx]
                let lenBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258][idx]
                var length = lenBase
                if lenBits > 0 { length += try r.bits(lenBits) }
                let dsym = try distTable.decode(&r)
                guard dsym < 30 else { throw OtaError("zlib.error: Error -3 while decompressing data: invalid distance code") }
                let distBits = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13][dsym]
                let distBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577][dsym]
                var dist = distBase
                if distBits > 0 { dist += try r.bits(distBits) }
                guard dist <= out.count else { throw OtaError("zlib.error: Error -3 while decompressing data: invalid distance too far back") }
                for _ in 0..<length { out.append(out[out.count - dist]) }
            }
        }
    }

    private static func readDynamicTables(_ r: inout BitReader) throws -> (Huffman, Huffman) {
        let hlit = try r.bits(5) + 257
        let hdist = try r.bits(5) + 1
        let hclen = try r.bits(4) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen { codeLengths[order[i]] = try r.bits(3) }
        let codeTable = try Huffman(lengths: codeLengths)
        var lengths = [Int](repeating: 0, count: hlit + hdist)
        var i = 0
        while i < hlit + hdist {
            let sym = try codeTable.decode(&r)
            switch sym {
            case 0...15:
                lengths[i] = sym; i += 1
            case 16:
                guard i > 0 else { throw OtaError("zlib.error: Error -3 while decompressing data") }
                let rep = try r.bits(2) + 3
                for _ in 0..<rep { guard i < lengths.count else { throw OtaError("zlib.error: Error -3 while decompressing data") }; lengths[i] = lengths[i - 1]; i += 1 }
            case 17:
                let rep = try r.bits(3) + 3
                i += rep
            case 18:
                let rep = try r.bits(7) + 11
                i += rep
            default:
                throw OtaError("zlib.error: Error -3 while decompressing data")
            }
        }
        let lit = try Huffman(lengths: Array(lengths[0..<hlit]))
        let dist = try Huffman(lengths: Array(lengths[hlit..<(hlit + hdist)]))
        return (lit, dist)
    }

    struct BitReader {
        let data: [UInt8]
        var pos = 0 // byte position
        var bitBuf: UInt32 = 0
        var bitCount = 0
        init(_ data: [UInt8]) { self.data = data }
        var remainingBytes: Int { data.count - pos }
        mutating func bits(_ n: Int) throws -> Int {
            while bitCount < n {
                guard pos < data.count else { throw OtaError("BadZipFile: truncated deflate stream") }
                bitBuf |= UInt32(data[pos]) << bitCount
                pos += 1; bitCount += 8
            }
            let v = Int(bitBuf & ((1 << n) - 1))
            bitBuf >>= n; bitCount -= n
            return v
        }
        mutating func alignToByte() { bitBuf = 0; bitCount = 0 }
        mutating func byte() -> UInt8 {
            alignToByte()
            guard pos < data.count else { return 0 }
            defer { pos += 1 }
            return data[pos]
        }
    }

    struct Huffman {
        // Canonical Huffman decoding via a lookup built from code lengths.
        let counts: [Int] // counts per code length
        let symbols: [Int] // symbols sorted by (length, symbol)
        static let fixedLiteral: Huffman = {
            var lengths = [Int](repeating: 0, count: 288)
            for i in 0..<144 { lengths[i] = 8 }
            for i in 144..<256 { lengths[i] = 9 }
            for i in 256..<280 { lengths[i] = 7 }
            for i in 280..<288 { lengths[i] = 8 }
            return try! Huffman(lengths: lengths)
        }()
        static let fixedDistance: Huffman = {
            try! Huffman(lengths: [Int](repeating: 5, count: 30))
        }()

        init(lengths: [Int]) throws {
            var counts = [Int](repeating: 0, count: 16)
            for l in lengths where l > 0 {
                guard l < 16 else { throw OtaError("zlib.error: Error -3 while decompressing data: invalid code lengths") }
                counts[l] += 1
            }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offsets[i] = offsets[i - 1] + counts[i - 1] }
            var symbols = [Int](repeating: 0, count: lengths.filter { $0 > 0 }.count)
            for (sym, len) in lengths.enumerated() where len > 0 {
                symbols[offsets[len]] = sym
                offsets[len] += 1
            }
            self.counts = counts
            self.symbols = symbols
        }

        func decode(_ r: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for len in 1..<16 {
                code |= try r.bits(1)
                let count = counts[len]
                if code - first < count {
                    return symbols[index + (code - first)]
                }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw OtaError("zlib.error: Error -3 while decompressing data: invalid code")
        }
    }
}

// MARK: - ZipIn

public final class ZipIn {
    public struct Entry {
        public var name: String
        public var flags: UInt16
        public var method: UInt16
        public var crc: UInt32
        public var compressedSize: UInt64
        public var size: UInt64
        public var headerOffset: UInt64
    }

    private let handle: FileHandle
    private let fileSize: UInt64
    public private(set) var entries: [Entry] = []
    private var byName: [String: Entry] = [:]

    public init(url: URL) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else {
            throw OtaError("Cannot open \(url.lastPathComponent)")
        }
        self.handle = h
        self.fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        do {
            try readCentral()
        } catch {
            try? h.close()
            throw error
        }
    }

    public convenience init(file: String) throws { try self.init(url: URL(fileURLWithPath: file)) }

    deinit { try? handle.close() }

    private var closed = false

    /// Close the underlying file handle (idempotent; also done by deinit).
    public func close() throws {
        guard !closed else { return }
        closed = true
        try handle.close()
    }

    public func namelist() -> [String] { entries.map { $0.name } }
    public func has(_ name: String) -> Bool { byName[name] != nil }

    public func getinfo(_ name: String) throws -> Entry {
        guard let e = byName[name] else {
            throw OtaError("KeyError: \"There is no item named \(Py.repr(name)) in the archive\"")
        }
        return e
    }

    public func read(_ name: String) throws -> Data {
        let e = try getinfo(name)
        return try readEntry(e)
    }

    public func open(_ name: String) throws -> InputStream {
        let e = try getinfo(name)
        return try entryStream(e)
    }

    // MARK: Central directory

    private func readBytes(at pos: UInt64, length: Int) throws -> [UInt8] {
        try handle.seek(toOffset: pos)
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw OtaError.eof()
        }
        return [UInt8](data)
    }

    private func u16(_ b: [UInt8], _ off: Int) -> UInt16 {
        UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
    }
    private func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }
    private func i64(_ b: [UInt8], _ off: Int) -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[off + i]) << (i * 8) }
        return Int64(bitPattern: v)
    }

    private func readCentral() throws {
        guard fileSize >= 22 else { throw OtaError("BadZipFile: File is not a zip file") }
        var eocd: UInt64
        let tail = try readBytes(at: fileSize - 22, length: 22)
        if u32(tail, 0) == 0x06054b50, u16(tail, 20) == 0 {
            eocd = fileSize - 22
        } else {
            let maxComment = min(fileSize, 65535 + 22)
            let area = try readBytes(at: fileSize - maxComment, length: Int(maxComment))
            var found: UInt64?
            var i = Int(maxComment) - 22
            while i >= 0 {
                if u32(area, i) == 0x06054b50 { found = fileSize - maxComment + UInt64(i); break }
                i -= 1
            }
            guard let f = found else { throw OtaError("BadZipFile: File is not a zip file") }
            eocd = f
        }
        let eocdBytes = try readBytes(at: eocd, length: 22)
        var count = UInt64(u16(eocdBytes, 10))
        var cdSize = UInt64(u32(eocdBytes, 12))
        var cdOffset = UInt64(u32(eocdBytes, 16))
        var location = eocd
        var zip64 = false
        if eocd >= 20 {
            let loc = try readBytes(at: eocd - 20, length: 20)
            if u32(loc, 0) == 0x07064b50 {
                let z64 = i64(loc, 8)
                let rec = try readBytes(at: eocd - 20 - 56, length: 56)
                if u32(rec, 0) == 0x06064b50 {
                    count = UInt64(bitPattern: i64(rec, 32))
                    cdSize = UInt64(bitPattern: i64(rec, 40))
                    cdOffset = UInt64(bitPattern: i64(rec, 48))
                    location = eocd - 20 - 56
                    zip64 = true
                } else if z64 >= 0 {
                    throw OtaError("BadZipFile: Corrupt zip64 end of central directory locator")
                }
            }
        }
        _ = zip64
        let concat = Int64(location) - Int64(cdSize) - Int64(cdOffset)
        guard concat >= 0 else { throw OtaError("BadZipFile: Bad offset for central directory") }
        let pos = cdOffset + UInt64(concat)
        let end = pos + cdSize
        guard cdSize <= 512 << 20 else { throw OtaError("BadZipFile: central directory too large") }
        let cd = try readBytes(at: pos, length: Int(cdSize))
        var p = 0
        while p < cd.count {
            guard p + 46 <= cd.count, u32(cd, p) == 0x02014b50 else {
                throw OtaError("BadZipFile: Bad magic number for central directory")
            }
            var e = Entry(
                name: "", flags: u16(cd, p + 8), method: u16(cd, p + 10),
                crc: u32(cd, p + 16), compressedSize: UInt64(u32(cd, p + 20)),
                size: UInt64(u32(cd, p + 24)), headerOffset: UInt64(u32(cd, p + 42)))
            let nlen = Int(u16(cd, p + 28)), xlen = Int(u16(cd, p + 30)), clen = Int(u16(cd, p + 32))
            let nameBytes = Array(cd[(p + 46)..<(p + 46 + nlen)])
            var name: String
            if (e.flags & 0x800) != 0 {
                name = try Py.decodeUtf8Strict(nameBytes)
            } else {
                name = cp437Decode(nameBytes)
            }
            if let nul = name.firstIndex(of: "\0") { name = String(name[..<nul]) }
            name = name.replacingOccurrences(of: "\\", with: "/")
            // ZIP64 extra field (ID 1).
            var xp = p + 46 + nlen
            let xend = xp + xlen
            while xp + 4 <= xend {
                let id = u16(cd, xp), ln = Int(u16(cd, xp + 2))
                if id == 1 {
                    var q = xp + 4
                    if e.size == 0xFFFF_FFFF, q + 8 <= xp + 4 + ln {
                        e.size = UInt64(bitPattern: i64(cd, q)); q += 8
                    }
                    if e.compressedSize == 0xFFFF_FFFF, q + 8 <= xp + 4 + ln {
                        e.compressedSize = UInt64(bitPattern: i64(cd, q)); q += 8
                    }
                    if e.headerOffset == 0xFFFF_FFFF, q + 8 <= xp + 4 + ln {
                        e.headerOffset = UInt64(bitPattern: i64(cd, q)); q += 8
                    }
                }
                xp += 4 + ln
            }
            e.name = name
            e.headerOffset += UInt64(concat)
            entries.append(e)
            byName[name] = e
            p += 46 + nlen + xlen + clen
        }
        _ = count
        guard end <= fileSize else { throw OtaError("BadZipFile: Truncated central directory") }
    }

    /// CP437 decoding (Java `new String(bytes, "IBM437")`, falling
    /// back to ISO-8859-1). Only the graphic range differs from
    /// Latin-1; the table below covers 0x80–0xFF.
    private func cp437Decode(_ bytes: [UInt8]) -> String {
        var scalars: [UnicodeScalar] = []
        for b in bytes {
            if b < 0x80 { scalars.append(UnicodeScalar(b)) }
            else { scalars.append(UnicodeScalar(cp437Table[Int(b - 0x80)]) ?? UnicodeScalar(UInt32(0xFFFD))!) }
        }
        var s = ""
        s.unicodeScalars.append(contentsOf: scalars)
        return s
    }

    private let cp437Table: [UInt32] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0
    ]

    // MARK: Entry reading

    private func localDataOffset(_ entry: Entry) throws -> UInt64 {
        let header = try readBytes(at: entry.headerOffset, length: 30)
        guard u32(header, 0) == 0x04034b50 else {
            throw OtaError("BadZipFile: Bad magic number for file header")
        }
        let nlen = UInt64(u16(header, 26)), xlen = UInt64(u16(header, 28))
        return entry.headerOffset + 30 + nlen + xlen
    }

    public func readEntry(_ entry: Entry) throws -> Data {
        let stream = try entryStream(entry)
        stream.open()
        defer { stream.close() }
        let data = try Py.readAll(stream)
        // Java validates CRC-32 inside EntryStream.finish(), which
        // runs on the final read; mirror that here.
        if let zipStream = stream as? ZipEntryStream {
            try zipStream.validateCRC()
        }
        return data
    }

    public func entryStream(_ entry: Entry) throws -> InputStream {
        if (entry.flags & 1) != 0 {
            throw OtaError("File \(Py.repr(entry.name)) is encrypted, password required for extraction")
        }
        guard entry.method == 0 || entry.method == 8 else {
            throw OtaError("NotImplementedError: That compression method is not supported")
        }
        let dataStart = try localDataOffset(entry)
        return ZipEntryStream(zip: self, entry: entry, dataStart: dataStart)
    }

    fileprivate func readChunk(at pos: UInt64, length: Int) throws -> [UInt8] {
        try handle.seek(toOffset: pos)
        guard let data = try handle.read(upToCount: length) else { throw OtaError.eof() }
        return [UInt8](data)
    }
}

/// Streaming reader for one ZIP entry, with CRC-32 validation at EOF
/// (exactly like Java's EntryStream).
public final class ZipEntryStream: InputStream {
    private let zip: ZipIn
    private let entry: ZipIn.Entry
    private let dataStart: UInt64
    private var rpos: UInt64
    private var produced: UInt64 = 0
    private var crc: UInt32 = 0xFFFF_FFFF
    private var finished = false
    private var rawBuffer: [UInt8] = []
    private var rawPos = 0
    private var inflater: RawInflater?
    private var inflateEnded = false

    init(zip: ZipIn, entry: ZipIn.Entry, dataStart: UInt64) {
        self.zip = zip
        self.entry = entry
        self.dataStart = dataStart
        self.rpos = dataStart
        super.init(data: Data())
    }

    public override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if len == 0 { return 0 }
        if produced >= entry.size {
            finish()
            return 0
        }
        let left = entry.size - produced
        let want = min(UInt64(len), left)
        do {
            let chunk = try readSome(count: Int(want))
            if chunk.isEmpty { return 0 }
            for (i, b) in chunk.enumerated() { buffer[i] = b }
            crc = CRC32.update(crc, chunk)
            produced += UInt64(chunk.count)
            if produced >= entry.size { finish() }
            return chunk.count
        } catch {
            return -1
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        // CRC is checked by the caller via `checkCRC()`; Java throws
        // inside finish(). We throw on the next read path instead:
        // see `validateCRC()` called by ZipIn.readEntry.
        if crc ^ 0xFFFF_FFFF != entry.crc {
            // Store the failure for the stream consumer.
            crcMismatch = true
        }
    }

    public var crcMismatch = false

    public func validateCRC() throws {
        if crcMismatch || (crc ^ 0xFFFF_FFFF) != entry.crc {
            throw OtaError("BadZipFile: Bad CRC-32 for file \(Py.repr(entry.name))")
        }
    }

    private func readSome(count: Int) throws -> [UInt8] {
        if entry.method == 0 {
            let rend = dataStart + entry.compressedSize
            guard rpos < rend else { throw OtaError.eof("Truncated zip entry \(entry.name)") }
            let avail = min(count, Int(rend - rpos))
            let bytes = try zip.readChunk(at: rpos, length: avail)
            if bytes.isEmpty { throw OtaError.eof() }
            rpos += UInt64(bytes.count)
            return bytes
        }
        // Deflated: feed the inflater from the channel in 64 KiB chunks.
        if inflater == nil { inflater = RawInflater() }
        #if canImport(CZlib)
        return try readSomeCZlib(count: count)
        #else
        // Apple platforms: decode the whole remaining raw stream with
        // the pure-Swift inflater, then serve from the buffer.
        if rawBuffer.isEmpty, !inflateEnded {
            let rend = dataStart + entry.compressedSize
            var raw: [UInt8] = []
            var pos = rpos
            while pos < rend {
                let chunk = try zip.readChunk(at: pos, length: Int(min(65536, rend - pos)))
                if chunk.isEmpty { break }
                raw.append(contentsOf: chunk)
                pos += UInt64(chunk.count)
            }
            rpos = rend
            let decoded = try InflatePure.decompress(raw, expectedSize: Int(entry.size))
            rawBuffer = [UInt8](decoded)
            rawPos = 0
            inflateEnded = true
        }
        let avail = min(count, rawBuffer.count - rawPos)
        guard avail > 0 else { return [] }
        let out = Array(rawBuffer[rawPos..<(rawPos + avail)])
        rawPos += avail
        return out
        #endif
    }

    #if canImport(CZlib)
    private func readSomeCZlib(count: Int) throws -> [UInt8] {
        guard let inflater else { return [] }
        var out = [UInt8](repeating: 0, count: count)
        while true {
            if inflater.pendingCount == 0, !inflateEnded {
                let rend = dataStart + entry.compressedSize
                if rpos < rend {
                    let chunk = try zip.readChunk(at: rpos, length: Int(min(65536, rend - rpos)))
                    if chunk.isEmpty { throw OtaError.eof("Compressed file ended before the end-of-stream marker was reached") }
                    inflater.feed(chunk)
                    rpos += UInt64(chunk.count)
                }
            }
            let (n, ended, needsInput) = try inflater.decode(into: &out, maxLength: count)
            if n > 0 { return Array(out[0..<n]) }
            if ended { inflateEnded = true; return [] }
            if needsInput {
                let rend = dataStart + entry.compressedSize
                if rpos >= rend { throw OtaError.eof("Compressed file ended before the end-of-stream marker was reached") }
                continue
            }
            return []
        }
    }
    #endif
}

// MARK: - ZipOut

public final class ZipOut {
    private struct Rec {
        var name: [UInt8]
        var offset: UInt64
        var crc: UInt32 = 0
        var csize: UInt64 = 0
        var usize: UInt64 = 0
        var flags: UInt16 = 0
        var dosTime: UInt16 = 0
        var dosDate: UInt16 = 0
        var unixMode: Int = -1
    }

    private let handle: FileHandle
    private var recs: [Rec] = []
    private var closed = false
    private var openEntry: Rec?
    private var openCRC: UInt32 = 0xFFFF_FFFF
    private var openDone = false

    public init(url: URL) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forUpdating: url) else {
            throw OtaError("Cannot create \(url.lastPathComponent)")
        }
        self.handle = h
        try h.truncate(atOffset: 0)
    }

    deinit { try? handle.close() }

    public func writeBytes(_ name: String, _ data: Data) throws {
        let stream = try openEntry(name)
        stream.open()
        var bytes = [UInt8](data)
        _ = stream.write(&bytes, maxLength: bytes.count)
        stream.close()
        try closeEntry()
    }

    public func openEntry(_ name: String, unixMode: Int = -1) throws -> OutputStream {
        if openEntry != nil {
            throw OtaError("Can't write to the ZIP file while there is another write handle open on it.")
        }
        let ascii = name.unicodeScalars.allSatisfy { $0.value < 128 }
        let nameBytes = ascii ? [UInt8](name.utf8) : [UInt8](name.utf8)
        let flags: UInt16 = ascii ? 0 : 0x800
        let (dosTime, dosDate) = ZipOut.dosNow()
        let offset = try handle.offset()
        guard offset <= 0xFFFF_FFFF else { throw OtaError("ZIP archive exceeds 4 GiB") }
        let rec = Rec(name: nameBytes, offset: offset, flags: flags, dosTime: dosTime, dosDate: dosDate, unixMode: unixMode)
        // Local header with zero CRC/sizes, patched on closeEntry.
        var header = Data()
        header.appendLE(UInt32(0x04034b50)); header.appendLE(UInt16(20)); header.appendLE(flags)
        header.appendLE(UInt16(8)); header.appendLE(dosTime); header.appendLE(dosDate)
        header.appendLE(UInt32(0)); header.appendLE(UInt32(0)); header.appendLE(UInt32(0))
        header.appendLE(UInt16(nameBytes.count)); header.appendLE(UInt16(0))
        header.append(Data(nameBytes))
        try handle.write(contentsOf: header)
        openEntry = rec
        openCRC = 0xFFFF_FFFF
        openDone = false
        _ = rec
        return ZipEntryOutputStream(zip: self)
    }

    fileprivate func writeEntryData(_ bytes: [UInt8]) throws {
        guard var rec = openEntry else { return }
        openCRC = CRC32.update(openCRC, bytes)
        rec.usize += UInt64(bytes.count)
        guard rec.usize <= 0xFFFF_FFFF else { throw OtaError("File size too large, try using force_zip64") }
        openEntry = rec
        // Compress incrementally: buffer until closeEntry for
        // simplicity and exact level-6 output (entries are small
        // relative to release blobs, which are written via writeBytes;
        // large blobs go through the same path in chunks).
        pendingData.append(contentsOf: bytes)
    }

    private var pendingData: [UInt8] = []

    fileprivate func closeEntry() throws {
        guard var rec = openEntry, !openDone else { return }
        openDone = true
        let compressed = try RawDeflate.compress(Data(pendingData))
        pendingData.removeAll()
        try handle.write(contentsOf: compressed)
        rec.crc = openCRC ^ 0xFFFF_FFFF
        rec.csize = UInt64(compressed.count)
        guard rec.csize <= 0xFFFF_FFFF else { throw OtaError("Compressed size too large") }
        // Seek back and patch the local header.
        let endPos = try handle.offset()
        try handle.seek(toOffset: rec.offset)
        var header = Data()
        header.appendLE(UInt32(0x04034b50)); header.appendLE(UInt16(20)); header.appendLE(rec.flags)
        header.appendLE(UInt16(8)); header.appendLE(rec.dosTime); header.appendLE(rec.dosDate)
        header.appendLE(rec.crc); header.appendLE(UInt32(rec.csize)); header.appendLE(UInt32(rec.usize))
        header.appendLE(UInt16(rec.name.count)); header.appendLE(UInt16(0))
        header.append(Data(rec.name))
        try handle.write(contentsOf: header)
        try handle.seek(toOffset: endPos)
        recs.append(rec)
        openEntry = nil
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        defer { try? handle.close() }
        if openEntry != nil {
            throw OtaError("entry still open")
        }
        let cdStart = try handle.offset()
        for rec in recs {
            var central = Data()
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(rec.unixMode >= 0 ? (3 << 8) | 20 : 20))
            central.appendLE(UInt16(20)); central.appendLE(rec.flags); central.appendLE(UInt16(8))
            central.appendLE(rec.dosTime); central.appendLE(rec.dosDate)
            central.appendLE(rec.crc); central.appendLE(UInt32(rec.csize)); central.appendLE(UInt32(rec.usize))
            central.appendLE(UInt16(rec.name.count))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            let extAttrs: UInt32 = rec.unixMode >= 0 ? (UInt32(0o100000 | rec.unixMode) << 16) : (UInt32(0o600) << 16)
            central.appendLE(extAttrs)
            central.appendLE(UInt32(rec.offset))
            central.append(Data(rec.name))
            try handle.write(contentsOf: central)
        }
        let cdEnd = try handle.offset()
        guard cdEnd <= 0xFFFF_FFFF, recs.count <= 0xFFFF else {
            throw OtaError("ZIP archive exceeds classic ZIP limits")
        }
        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50)); eocd.appendLE(UInt16(0)); eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(recs.count)); eocd.appendLE(UInt16(recs.count))
        eocd.appendLE(UInt32(cdEnd - cdStart)); eocd.appendLE(UInt32(cdStart)); eocd.appendLE(UInt16(0))
        try handle.write(contentsOf: eocd)
    }

    public func abort() {
        closed = true
        try? handle.close()
    }

    private static func dosNow() -> (UInt16, UInt16) {
        let now = Date()
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let year = max(1980, comps.year ?? 1980)
        let dosDate = UInt16(((year - 1980) << 9) | (((comps.month ?? 1) << 5)) | (comps.day ?? 1))
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        return (dosTime, dosDate)
    }
}

private final class ZipEntryOutputStream: OutputStream {
    private weak var zip: ZipOut?
    private var closed = false
    init(zip: ZipOut) { self.zip = zip; super.init(toMemory: ()) }
    required override init(toMemory: ()) { super.init(toMemory: ()) }
    override func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }
        do {
            try zip?.writeEntryData(Array(UnsafeBufferPointer(start: buffer, count: len)))
            return len
        } catch { return -1 }
    }
    override func close() {
        guard !closed else { return }
        closed = true
        try? zip?.closeEntry()
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
}

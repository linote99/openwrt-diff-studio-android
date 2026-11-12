// Gzip.swift
// Streaming gzip member reader — the Swift equivalent of Java's
// GZIPInputStream, used for `openwrt.ext4.gz` and `*.tar.gz` inside
// release ZIPs.
//
// One gzip member is read; trailing data after the member is ignored,
// exactly like GZIPInputStream. The CRC-32 and ISIZE trailer are
// verified (by zlib on the CZlib path, explicitly on the Apple path).
//
// Platform notes:
//  * Linux (CZlib): true streaming via inflateInit2(31).
//  * Apple (Compression framework): the compressed member is buffered
//    in memory and decoded with the pure-Swift inflater, because
//    Compression has no raw-deflate streaming mode. The *decompressed*
//    output is still served incrementally, so the (large) ext4 image
//    is written to disk progressively. Typical members are tens of MB.

import Foundation

#if canImport(CZlib)
import CZlib
#endif

public final class GzipInputStream: InputStream {
    private let source: InputStream
    private var ended = false
    private var headerDone = false

    #if canImport(CZlib)
    private var strm = z_stream()
    private var initialized = false
    private var inBuf: [UInt8] = []
    private var inPos = 0
    #else
    private var buffer: [UInt8] = []
    private var pos = 0
    private var loaded = false
    #endif

    public init(_ source: InputStream) {
        self.source = source
        super.init(data: Data())
        #if canImport(CZlib)
        strm.zalloc = nil; strm.zfree = nil; strm.opaque = nil
        let rc = inflateInit2_(&strm, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        if rc == Z_OK { initialized = true }
        #endif
    }

    deinit {
        #if canImport(CZlib)
        if initialized { inflateEnd(&strm) }
        #endif
    }

    public override func open() { source.open() }
    public override func close() { source.close() }

    public override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if ended { return 0 }
        if len == 0 { return 0 }
        #if canImport(CZlib)
        return readCZlib(buffer, maxLength: len)
        #else
        return readBuffered(buffer, maxLength: len)
        #endif
    }

    // MARK: - CZlib streaming path

    #if canImport(CZlib)
    private func fillInput() throws -> Bool {
        if inPos < inBuf.count { return true }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = source.read(&chunk, maxLength: chunk.count)
        if n < 0 { throw OtaError("ReadError: unexpected end of data") }
        if n == 0 { return false }
        inBuf = Array(chunk[0..<n])
        inPos = 0
        return true
    }

    private func readCZlib(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard initialized else { return -1 }
        do {
            while true {
                if inPos >= inBuf.count, !ended {
                    guard try fillInput() else {
                        throw OtaError("ReadError: unexpected end of data")
                    }
                }
                var produced = 0
                var streamEnd = false
                var rc: Int32 = Z_OK
                inBuf.withUnsafeBytes { inPtr in
                    strm.next_in = UnsafeMutablePointer(mutating: inPtr.baseAddress!.advanced(by: inPos).assumingMemoryBound(to: Bytef.self))
                    strm.avail_in = uInt(inBuf.count - inPos)
                    buffer.withMemoryRebound(to: Bytef.self, capacity: len) { outPtr in
                        strm.next_out = outPtr
                        strm.avail_out = uInt(len)
                        rc = inflate(&strm, Z_NO_FLUSH)
                        let consumed = (inBuf.count - inPos) - Int(strm.avail_in)
                        inPos += consumed
                        produced = len - Int(strm.avail_out)
                        streamEnd = (rc == Z_STREAM_END)
                    }
                }
                if rc != Z_OK, rc != Z_STREAM_END, rc != Z_BUF_ERROR {
                    throw OtaError("GZIP error: zlib returned \(rc)")
                }
                if streamEnd { ended = true }
                if produced > 0 { return produced }
                if ended { return 0 }
                if rc == Z_BUF_ERROR {
                    // No progress and no input left: truncated stream.
                    if inPos >= inBuf.count {
                        guard try fillInput() else { throw OtaError("ReadError: unexpected end of data") }
                        continue
                    }
                    throw OtaError("GZIP error: no progress")
                }
            }
        } catch {
            ended = true
            return -1
        }
    }
    #endif

    // MARK: - Apple buffered path

    #if !canImport(CZlib)
    private func readBuffered(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if !loaded {
            loaded = true
            do {
                let raw = try Py.readAll(source)
                self.buffer = try decodeMember([UInt8](raw))
                pos = 0
            } catch {
                ended = true
                return -1
            }
        }
        if pos >= self.buffer.count { ended = true; return 0 }
        let n = min(len, self.buffer.count - pos)
        for i in 0..<n { buffer[i] = self.buffer[pos + i] }
        pos += n
        return n
    }

    /// Parse one gzip member: header, raw DEFLATE body, CRC-32 + ISIZE.
    private func decodeMember(_ raw: [UInt8]) throws -> [UInt8] {
        guard raw.count >= 18, raw[0] == 0x1F, raw[1] == 0x8B, raw[2] == 8 else {
            throw OtaError("GZIP error: bad magic")
        }
        let flags = raw[3]
        var p = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard p + 2 <= raw.count else { throw OtaError("GZIP error: truncated header") }
            let xlen = Int(raw[p]) | (Int(raw[p + 1]) << 8)
            p += 2 + xlen
        }
        if flags & 0x08 != 0 { // FNAME
            while p < raw.count, raw[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while p < raw.count, raw[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x02 != 0 { p += 2 } // FHCRC
        guard p + 8 <= raw.count else { throw OtaError("GZIP error: truncated member") }
        let bodyEnd = raw.count - 8
        guard bodyEnd >= p else { throw OtaError("GZIP error: truncated member") }
        let body = Array(raw[p..<bodyEnd])
        let decoded = try InflatePure.decompress(Data(body), expectedSize: 0)
        let crc = CRC32.of([UInt8](decoded))
        let wantCrc = UInt32(raw[bodyEnd]) | (UInt32(raw[bodyEnd + 1]) << 8) | (UInt32(raw[bodyEnd + 2]) << 16) | (UInt32(raw[bodyEnd + 3]) << 24)
        let wantSize = UInt32(raw[bodyEnd + 4]) | (UInt32(raw[bodyEnd + 5]) << 8) | (UInt32(raw[bodyEnd + 6]) << 16) | (UInt32(raw[bodyEnd + 7]) << 24)
        if crc != wantCrc || UInt32(decoded.count) != wantSize {
            throw OtaError("GZIP error: CRC mismatch")
        }
        return [UInt8](decoded)
    }
    #endif
}

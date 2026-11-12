// Ext4.swift
//
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is a port of com.linote.diffstudio.core.Ext4 (Java) and,
// like the original, is licensed under the GNU Affero General Public
// License v3.0 or later (see LICENSES/AGPL-3.0.txt). It is NOT covered
// by the MIT licence of the rest of the app. Do not relicense it.
//
// Read-only ext2/3/4 parser (dissect.extfs behaviour, no mounting).

import Foundation

public final class Ext4 {
    public static let S_IFMT: Int = 0o170000
    public static let S_IFDIR: Int = 0o040000
    public static let S_IFREG: Int = 0o100000
    public static let S_IFLNK: Int = 0o120000

    private static let filetypes: [Int] = [0, 0o100000, 0o040000, 0o020000, 0o060000, 0o010000, 0o140000, 0o120000]

    private let handle: FileHandle
    private let blockSize: Int
    private let inodesCount: Int64
    private let inodesPerGroup: Int64
    private let lastBlock: Int64
    private let groupsCount: Int64
    private let groupsOffset: Int64
    private let inodeSize: Int
    private let descSize: Int
    private let desc64: Bool
    private let dirFileType: Int

    public init(url: URL) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else {
            throw OtaError("Cannot open \(url.lastPathComponent)")
        }
        self.handle = h
        // Superblock at offset 1024, length 1024, little-endian.
        let sb = try Ext4.read(handle: h, pos: 1024, len: 1024)
        func u16(_ p: Int) -> UInt16 { UInt16(sb[p]) | (UInt16(sb[p + 1]) << 8) }
        func u32(_ p: Int) -> UInt64 { UInt64(sb[p]) | (UInt64(sb[p + 1]) << 8) | (UInt64(sb[p + 2]) << 16) | (UInt64(sb[p + 3]) << 24) }
        guard u16(0x38) == 0xEF53 else {
            throw OtaError("Not a valid ExtFS filesystem (magic mismatch)")
        }
        inodesCount = Int64(u32(0x0))
        guard inodesCount >= 10 else {
            throw OtaError("Not a valid ExtFS filesystem (inum count < 10)")
        }
        let blocksPerGroup = u32(0x20)
        inodesPerGroup = Int64(u32(0x28))
        guard blocksPerGroup != 0, inodesPerGroup != 0 else {
            throw OtaError("Not a valid ExtFS filesystem (blocks or inodes per group is 0)")
        }
        let logBlock = u32(0x18)
        let logCluster = u32(0x1c)
        guard logBlock == logCluster else {
            throw OtaError("NotImplementedError: Different size cluster than blocks is currently not supported")
        }
        guard logBlock <= 16 else {
            throw OtaError("Not a valid ExtFS filesystem (invalid block size)")
        }
        blockSize = 1024 << Int(logBlock)
        let incompat = u32(0x60)
        dirFileType = (incompat & 0x2) != 0 ? 2 : 1
        let blockCount = (u32(0x150) << 32) | u32(0x4)
        lastBlock = Int64(blockCount) - 1
        let sDesc = u16(0xfe)
        let ext4 = (incompat & 0x40) != 0
        desc64 = ext4 && (incompat & 0x80) != 0 && sDesc >= 64
        descSize = sDesc != 0 ? Int(sDesc) : (desc64 ? 64 : 32)
        var goff = Int64(1024 + descSize)
        goff = goff % Int64(blockSize) == 0 ? goff : goff + Int64(blockSize) - goff % Int64(blockSize)
        groupsOffset = goff
        let firstData = u32(0x14)
        groupsCount = (lastBlock - Int64(firstData)) / Int64(blocksPerGroup) + 1
        inodeSize = Int(u16(0x58))
        // Root must be readable or construction fails.
        _ = try inode(2)
    }

    deinit { try? handle.close() }

    static func read(handle: FileHandle, pos: Int64, len: Int) throws -> [UInt8] {
        if len == 0 { return [] }
        try handle.seek(toOffset: UInt64(pos))
        guard let data = try handle.read(upToCount: len), data.count == len else {
            throw OtaError.eof("ext4 read beyond image end")
        }
        return [UInt8](data)
    }

    func read(pos: Int64, len: Int) throws -> [UInt8] {
        try Ext4.read(handle: handle, pos: pos, len: len)
    }

    public func root() throws -> Inode { try inode(2) }

    public func inode(_ inum: Int64) throws -> Inode {
        guard inum >= 1, inum <= inodesCount else {
            throw OtaError("inum out of range 1-\(inodesCount): \(inum)")
        }
        let group = (inum - 1) / inodesPerGroup
        let index = (inum - 1) % inodesPerGroup
        guard group < groupsCount else {
            throw OtaError("Group number exceeds amount of groups")
        }
        let desc = try read(pos: groupsOffset + group * Int64(descSize), len: desc64 ? 64 : 32)
        func u32d(_ p: Int) -> UInt64 { UInt64(desc[p]) | (UInt64(desc[p + 1]) << 8) | (UInt64(desc[p + 2]) << 16) | (UInt64(desc[p + 3]) << 24) }
        var table = u32d(8)
        if desc64 { table |= u32d(0x28) << 32 }
        let blockBitmap = u32d(0) | (desc64 ? u32d(0x20) << 32 : 0)
        let inodeBitmap = u32d(4) | (desc64 ? u32d(0x24) << 32 : 0)
        guard blockBitmap <= UInt64(lastBlock), inodeBitmap <= UInt64(lastBlock), table <= UInt64(lastBlock) else {
            throw OtaError("Group descriptor block locations exceed last block")
        }
        let raw = try read(pos: Int64(table) * Int64(blockSize) + index * Int64(inodeSize), len: 256)
        return Inode(ext4: self, inum: inum, raw: raw, filename: "", direntType: 0)
    }

    public final class Inode {
        public let inum: Int64
        public let filename: String
        public let mode: Int
        public let uidLow: Int
        public let gidLow: Int
        public let flags: Int32
        public let size: Int64
        private let ext4: Ext4
        fileprivate let raw: [UInt8]
        private let iblock: [UInt8]
        private var direntType: Int

        init(ext4: Ext4, inum: Int64, raw: [UInt8], filename: String, direntType: Int) {
            self.ext4 = ext4
            self.inum = inum
            self.raw = raw
            self.filename = filename
            self.direntType = direntType
            func u16(_ p: Int) -> Int { Int(raw[p]) | (Int(raw[p + 1]) << 8) }
            func u32(_ p: Int) -> UInt64 { UInt64(raw[p]) | (UInt64(raw[p + 1]) << 8) | (UInt64(raw[p + 2]) << 16) | (UInt64(raw[p + 3]) << 24) }
            mode = u16(0)
            uidLow = u16(2)
            gidLow = u16(24)
            flags = Int32(bitPattern: UInt32(u32(32)))
            size = Int64((u32(108) << 32) + u32(4))
            iblock = Array(raw[40..<100])
        }

        public func filetype() -> Int {
            direntType != 0 ? direntType : (mode & Ext4.S_IFMT)
        }

        public func open() throws -> InputStream {
            if (flags & 0x10000000) != 0 || (filetype() == Ext4.S_IFLNK && size < 60) {
                let n = Int(min(size, 60))
                return InputStream(data: Data(iblock[0..<n]))
            }
            return RunStream(ext4: ext4, runs: try dataruns(), size: size)
        }

        public func link() throws -> String {
            guard filetype() == Ext4.S_IFLNK else { throw OtaError("not a symlink") }
            let stream = try open()
            stream.open()
            defer { stream.close() }
            let data = try Py.readAll(stream)
            return Py.decodeSurrogateEscape([UInt8](data))
        }

        public func iterdir() throws -> [Inode] {
            guard filetype() == Ext4.S_IFDIR else { throw OtaError("not a directory") }
            let stream = try open()
            stream.open()
            defer { stream.close() }
            let data = [UInt8](try Py.readAll(stream))
            var out: [Inode] = []
            var off = 0
            func u32d(_ p: Int) -> UInt64 { UInt64(data[p]) | (UInt64(data[p + 1]) << 8) | (UInt64(data[p + 2]) << 16) | (UInt64(data[p + 3]) << 24) }
            func u16d(_ p: Int) -> Int { Int(data[p]) | (Int(data[p + 1]) << 8) }
            while off < Int(size) - 12 {
                guard off + 8 <= data.count else { throw OtaError("EOFError: directory entry beyond data") }
                let ino = Int64(u32d(off))
                let recLen = u16d(off + 4)
                let nameLen: Int
                let ftype: Int
                if ext4.dirFileType == 2 {
                    nameLen = Int(data[off + 6])
                    ftype = Int(data[off + 7])
                } else {
                    nameLen = u16d(off + 6)
                    ftype = 0
                }
                if recLen == 0 { return out }
                if ino > 0, ino < ext4.inodesCount {
                    let nl = min(nameLen, max(0, data.count - off - 8))
                    let name = Py.decodeSurrogateEscape(Array(data[(off + 8)..<(off + 8 + nl)]))
                    var ft = 0
                    if ftype != 0 {
                        guard ftype < Ext4.filetypes.count else { throw OtaError("KeyError: \(ftype)") }
                        ft = Ext4.filetypes[ftype]
                    }
                    out.append(try ext4.inodeWithName(ino, name: name, direntType: ft))
                }
                off += recLen
            }
            return out
        }

        public func xattrs() throws -> [(String, [UInt8])] {
            var out: [(String, [UInt8])] = []
            let extraIsize = Int(raw[128]) | (Int(raw[129]) << 8)
            let extraLen = 128 - extraIsize
            if extraLen < 0 { throw OtaError("Invalid inode extra size") }
            let extra = Array(raw[160..<min(160 + min(extraLen, 96), raw.count)])
            if extra.contains(where: { $0 != 0 }) {
                guard extra.count >= 4,
                      UInt32(extra[0]) | (UInt32(extra[1]) << 8) | (UInt32(extra[2]) << 16) | (UInt32(extra[3]) << 24) == 0xEA020000
                else { throw OtaError("Invalid xattr magic value") }
                try iterXattr(buf: extra, offset: 4, end: extra.count, valueOffset: 4, out: &out)
            }
            func u32r(_ p: Int) -> UInt64 { UInt64(raw[p]) | (UInt64(raw[p + 1]) << 8) | (UInt64(raw[p + 2]) << 16) | (UInt64(raw[p + 3]) << 24) }
            let aclLo = u32r(104)
            if aclLo != 0 {
                let blk = (UInt64(raw[118]) | (UInt64(raw[119]) << 8)) << 32 | aclLo
                let bb = try ext4.read(pos: Int64(blk) * Int64(ext4.blockSize), len: ext4.blockSize)
                guard UInt32(bb[0]) | (UInt32(bb[1]) << 8) | (UInt32(bb[2]) << 16) | (UInt32(bb[3]) << 24) == 0xEA020000
                else { throw OtaError("Invalid xattr magic value") }
                try iterXattr(buf: bb, offset: 32, end: ext4.blockSize, valueOffset: 0, out: &out)
            }
            return out
        }

        private func iterXattr(buf: [UInt8], offset: Int, end: Int, valueOffset: Int, out: inout [(String, [UInt8])]) throws {
            var off = offset
            while true {
                if off > end { break }
                if off + 16 > buf.count { break }
                let nameLen = Int(buf[off])
                let index = Int(buf[off + 1])
                let valueOffs = Int(buf[off + 2]) | (Int(buf[off + 3]) << 8)
                let valueInum = UInt32(buf[off + 4]) | (UInt32(buf[off + 5]) << 8) | (UInt32(buf[off + 6]) << 16) | (UInt32(buf[off + 7]) << 24)
                let valueSize = Int(UInt32(buf[off + 8]) | (UInt32(buf[off + 9]) << 8) | (UInt32(buf[off + 10]) << 16) | (UInt32(buf[off + 11]) << 24))
                if nameLen == 0, index == 0, valueOffs == 0 { break }
                if off + 16 + nameLen > buf.count { break }
                let nameBytes = Array(buf[(off + 16)..<(off + 16 + nameLen)])
                let value: [UInt8]
                if valueInum != 0 {
                    let stream = try ext4.inode(Int64(valueInum)).open()
                    stream.open()
                    defer { stream.close() }
                    value = [UInt8](try Py.readUpTo(stream, limit: Int64(valueSize)))
                } else {
                    let start = valueOffset + valueOffs
                    let stop = min(buf.count, start + valueSize)
                    value = start < stop ? Array(buf[start..<stop]) : []
                }
                out.append((Ext4.xattrName(index, nameBytes), value))
                off += (16 + nameLen + 3) & ~3
            }
        }

        // MARK: Block mapping

        private func dataruns() throws -> [[Int64]] {
            let expected = (size + Int64(ext4.blockSize) - 1) / Int64(ext4.blockSize)
            if (flags & 0x80000) != 0 {
                var out: [[Int64]] = []
                try parseExtents(buf: iblock, out: &out, depthGuard: 0)
                var runs: [[Int64]] = []
                var runOffset: Int64 = 0
                for e in out {
                    let eeBlock = e[0], eeLen = e[1], start = e[2]
                    if eeLen > 0x8000 {
                        runs.append([-1, eeLen - 0x8000])
                        runOffset += eeLen - 0x8000
                        continue
                    }
                    if eeBlock != runOffset {
                        runs.append([-1, eeBlock - runOffset])
                        runOffset = eeBlock
                    }
                    runs.append([start, eeLen])
                    runOffset += eeLen
                }
                if runOffset < expected { runs.append([-1, expected - runOffset]) }
                return runs
            }
            // Indirect blocks.
            var blocks: [Int64] = []
            var numBlocks = expected
            let direct = min(numBlocks, 12)
            for i in 0..<direct {
                blocks.append(Int64(u32ib(Int(i * 4))))
            }
            numBlocks -= direct
            for level in 0..<3 where numBlocks > 0 {
                let ind = Int64(u32ib(Int((Int(direct) + level) * 4)))
                let parsed = try parseIndirect(offset: ind, numBlocks: numBlocks, level: level + 1)
                blocks.append(contentsOf: parsed)
                numBlocks -= Int64(parsed.count)
            }
            // Coalesce into runs (bug-compatible asymmetry preserved).
            var runs: [[Int64]] = []
            var runOff: Int64 = -1
            var runSize: Int64 = 0
            for b in blocks {
                if runSize == 0 {
                    runOff = b; runSize = 1
                } else if b == runOff + runSize {
                    runSize += 1
                } else {
                    runs.append([runOff == 0 ? -1 : runOff, runSize])
                    runOff = b; runSize = 1
                }
            }
            if runSize > 0 { runs.append([runOff, runSize]) }
            return runs
        }

        private func u32ib(_ p: Int) -> UInt32 {
            UInt32(iblock[p]) | (UInt32(iblock[p + 1]) << 8) | (UInt32(iblock[p + 2]) << 16) | (UInt32(iblock[p + 3]) << 24)
        }

        private func parseExtents(buf: [UInt8], out: inout [[Int64]], depthGuard: Int) throws {
            guard depthGuard <= 8 else { throw OtaError("Invalid extent tree depth") }
            func u16b(_ p: Int) -> Int { Int(buf[p]) | (Int(buf[p + 1]) << 8) }
            func u32b(_ p: Int) -> UInt64 { UInt64(buf[p]) | (UInt64(buf[p + 1]) << 8) | (UInt64(buf[p + 2]) << 16) | (UInt64(buf[p + 3]) << 24) }
            guard u16b(0) == 0xF30A else { throw OtaError("Invalid extent_header magic") }
            let entries = u16b(2)
            let depth = u16b(6)
            for i in 0..<entries {
                let p = 12 + i * 12
                guard p + 12 <= buf.count else { throw OtaError("EOFError: extent entries beyond node") }
                if depth == 0 {
                    let eeBlock = Int64(u32b(p))
                    let eeLen = Int64(u16b(p + 4))
                    let start = Int64((u16b(p + 6) << 32) | Int(u32b(p + 8)))
                    out.append([eeBlock, eeLen, start])
                } else {
                    let child = Int64((u16b(p + 8) << 32) | Int(u32b(p + 4)))
                    let childBuf = try ext4.read(pos: child * Int64(ext4.blockSize), len: ext4.blockSize)
                    try parseExtents(buf: childBuf, out: &out, depthGuard: depthGuard + 1)
                }
            }
        }

        private func parseIndirect(offset: Int64, numBlocks: Int64, level: Int) throws -> [Int64] {
            let perBlock = Int64(ext4.blockSize / 4)
            if level == 1 {
                let readBlocks = min(numBlocks, perBlock)
                if offset == 0 { return [Int64](repeating: 0, count: Int(readBlocks)) }
                let bytes = try ext4.read(pos: offset * Int64(ext4.blockSize), len: Int(readBlocks * 4))
                var out: [Int64] = []
                for i in 0..<Int(readBlocks) {
                    out.append(Int64(UInt32(bytes[i * 4]) | (UInt32(bytes[i * 4 + 1]) << 8) | (UInt32(bytes[i * 4 + 2]) << 16) | (UInt32(bytes[i * 4 + 3]) << 24)))
                }
                return out
            }
            var maxLevel: Int64 = 1
            for _ in 0..<level { maxLevel *= perBlock }
            let perNest = maxLevel / perBlock
            let readBlocks = min((numBlocks + perNest - 1) / perNest, perBlock)
            let bytes = try ext4.read(pos: offset * Int64(ext4.blockSize), len: Int(readBlocks * 4))
            var out: [Int64] = []
            var remaining = numBlocks
            for i in 0..<Int(readBlocks) where remaining > 0 {
                let ptr = Int64(UInt32(bytes[i * 4]) | (UInt32(bytes[i * 4 + 1]) << 8) | (UInt32(bytes[i * 4 + 2]) << 16) | (UInt32(bytes[i * 4 + 3]) << 24))
                let parsed = try parseIndirect(offset: ptr, numBlocks: remaining, level: level - 1)
                out.append(contentsOf: parsed)
                remaining -= Int64(parsed.count)
            }
            return out
        }
    }

    fileprivate func inodeWithName(_ inum: Int64, name: String, direntType: Int) throws -> Inode {
        // Same construction as inode(_:), but with the directory-entry
        // name and mapped file type attached.
        let base = try inode(inum)
        return Inode(ext4: self, inum: base.inum, raw: base.raw, filename: name, direntType: direntType)
    }

    static func xattrName(_ index: Int, _ nameBytes: [UInt8]) -> String {
        let n = Py.decodeSurrogateEscape(nameBytes)
        switch index {
        case 1: return "user." + n
        case 2: return "system.posix_acl_access"
        case 3: return "system.posix_acl_default"
        case 4: return "trusted." + n
        case 6: return "security." + n
        case 7: return "system." + n
        default: return "unknown_prefix" + n
        }
    }
}

private final class RunStream: InputStream {
    private let ext4: Ext4
    private let runs: [[Int64]]
    private var left: Int64
    private var run = 0
    private var runPos: Int64 = 0

    init(ext4: Ext4, runs: [[Int64]], size: Int64) {
        self.ext4 = ext4
        self.runs = runs
        self.left = size
        super.init(data: Data())
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if left <= 0 { return 0 }
        while run < runs.count {
            let count = runs[run][1] * Int64(ext4BlockSize)
            if runPos < count { break }
            run += 1
            runPos = 0
        }
        guard run < runs.count else { left = 0; return 0 }
        let avail = runs[run][1] * Int64(ext4BlockSize) - runPos
        let n = Int(min(Int64(len), min(avail, left)))
        let block = runs[run][0]
        if block < 0 {
            for i in 0..<n { buffer[i] = 0 }
        } else {
            do {
                let bytes = try ext4.read(pos: block * Int64(ext4BlockSize) + runPos, len: n)
                for i in 0..<n { buffer[i] = bytes[i] }
            } catch {
                return -1
            }
        }
        runPos += Int64(n)
        left -= Int64(n)
        return n
    }

    private var ext4BlockSize: Int { ext4.blockSizeValue }
}

extension Ext4 {
    fileprivate var blockSizeValue: Int { blockSize }
}

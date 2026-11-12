// AppIO.swift
// Port of com.linote.diffstudio.AndroidIo (Java, MIT) for iOS.
//
// Storage and network helpers. Differences from Android, documented:
//  * iOS document-picker URLs are security-scoped file URLs and are
//    directly readable/seekable, so openRelease() prefers direct use
//    and only copies to scratch when the file is not directly readable
//    (Android copies providers without seekable descriptors).
//  * iOS has no public API to pick a network interface by route the
//    way AndroidIo.connect() does (longest-prefix route, skip VPN).
//    iOS routes LAN traffic to Wi-Fi automatically when connected to
//    the device's network, so Remote connects with the system default
//    route; resolve() below only turns a hostname into an address.
//  * The Android save-dialog name-shortening workaround (fixSavedName)
//    is kept for exported files renamed by the Files picker.

import Foundation

#if canImport(Network)
import Network
#endif

public enum AppIO {
    public static func displayName(_ url: URL) -> String {
        url.lastPathComponent
    }

    /// Restore the intended name/extension on an exported file when
    /// the Files picker shortened or re-suffixed it (Android vendor
    /// save dialogs do this; iOS rarely does, but the repair is the
    /// same). A name the user typed themselves is kept; only its
    /// extension is corrected. Returns the (possibly new) file URL.
    public static func fixSavedName(_ url: URL, intended: String) -> URL {
        guard !intended.isEmpty else { return url }
        let actual = displayName(url)
        guard actual != intended else { return url }
        let dot = intended.lastIndex(of: ".")
        let ext = dot.map { String(intended[$0...]) } ?? ""
        let stem = dot.map { String(intended[..<($0)]) } ?? intended
        var base = actual
        let extOk = !ext.isEmpty && base.lowercased().hasSuffix(ext.lowercased())
        if extOk {
            base = String(base.dropLast(ext.count))
        } else if let m = base.range(of: "\\.[A-Za-z0-9]{1,5}$", options: .regularExpression) {
            base = String(base[..<m.lowerBound])
        }
        let core = base.replacingOccurrences(of: " \\(\\d+\\)$", with: "", options: .regularExpression)
        let suffix = String(base.dropFirst(core.count))
        let wantedStem: String
        if core.isEmpty || stem.hasPrefix(core) {
            wantedStem = stem + suffix // shortened by the dialog
        } else if extOk {
            return url // the user chose a different, valid name
        } else {
            wantedStem = base // the user's own name with a wrong extension
        }
        var tries = [wantedStem + ext]
        for i in 1...20 { tries.append(wantedStem + " (\(i))" + ext) }
        let dir = url.deletingLastPathComponent()
        for name in tries {
            if name == actual { return url }
            let dest = dir.appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            } catch {
                let msg = error.localizedDescription.lowercased()
                if !(msg.contains("exist") || msg.contains("already") || msg.contains("conflict") || msg.contains("unique")) {
                    return url
                }
            }
        }
        return url
    }

    /// Largest writable scratch directory (the E5 root image is
    /// decompressed there temporarily).
    public static func scratch() -> URL {
        let fm = FileManager.default
        let candidates = [fm.temporaryDirectory, fm.urls(for: .cachesDirectory, in: .userDomainMask).first]
            .compactMap { $0 }
        var best = candidates.first ?? fm.temporaryDirectory
        var bestFree: Int64 = -1
        for dir in candidates {
            if let attrs = try? fm.attributesOfFileSystem(forPath: dir.path),
               let free = attrs[.systemFreeSize] as? Int64, free > bestFree {
                bestFree = free
                best = dir
            }
        }
        let dir = best.appendingPathComponent("work", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Random-access release source; files that are not directly
    /// readable are copied to scratch first.
    public static func openRelease(url: URL, scratch: URL) throws -> Release.Source {
        let name = displayName(url)
        #if os(iOS) || os(macOS)
        let accessible = url.startAccessingSecurityScopedResource()
        defer { if accessible { url.stopAccessingSecurityScopedResource() } }
        #endif
        let direct: Bool = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64, size > 0,
                  FileManager.default.isReadableFile(atPath: url.path) else { return false }
            return true
        }()
        if direct {
            // The security-scoped URL stays valid while the picker
            // grant is held by the caller (see DocumentPicker).
            return Release.Source(url: url, displayName: name)
        }
        let copy = scratch.appendingPathComponent("release-\(UUID().uuidString).zip")
        do {
            guard let input = InputStream(url: url) else {
                throw OtaError("Cannot open \(name)")
            }
            _ = FileManager.default.createFile(atPath: copy.path, contents: nil)
            guard let output = OutputStream(url: copy, append: false) else {
                throw OtaError("Cannot open \(name)")
            }
            input.open()
            defer { input.close() }
            output.open()
            defer { output.close() }
            var buf = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let n = input.read(&buf, maxLength: buf.count)
                if n < 0 { throw OtaError("ReadError: stream read failed") }
                if n == 0 { break }
                var written = 0
                while written < n {
                    let w = buf.withUnsafeBytes { ptr in
                        output.write(ptr.baseAddress!.advanced(by: written).assumingMemoryBound(to: UInt8.self), maxLength: n - written)
                    }
                    guard w > 0 else { throw OtaError("WriteError: failed to copy release") }
                    written += w
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
        return Release.Source(url: copy, displayName: name, cleanup: {
            try? FileManager.default.removeItem(at: copy)
        })
    }

    public static func copyToFile(from: URL, to: URL) throws {
        guard let input = InputStream(url: from) else {
            throw OtaError("Cannot open the selected file")
        }
        _ = FileManager.default.createFile(atPath: to.path, contents: nil)
        guard let output = OutputStream(url: to, append: false) else {
            throw OtaError("Cannot write the selected destination")
        }
        input.open()
        defer { input.close() }
        output.open()
        defer { output.close() }
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = input.read(&buf, maxLength: buf.count)
            if n < 0 { throw OtaError("ReadError: stream read failed") }
            if n == 0 { break }
            var written = 0
            while written < n {
                let w = buf.withUnsafeBytes { ptr in
                    output.write(ptr.baseAddress!.advanced(by: written).assumingMemoryBound(to: UInt8.self), maxLength: n - written)
                }
                guard w > 0 else { throw OtaError("WriteError: failed to copy") }
                written += w
            }
        }
    }

    public static func copyToURL(from: URL, to: URL) throws {
        try copyToFile(from: from, to: to)
    }

    /// Resolve a hostname to its first IP address string (getaddrinfo).
    /// Used to log/verify the device address before an SSH connection.
    public static func resolve(host: String) throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0, let res else {
            throw OtaError("Unable to resolve \(host)")
        }
        defer { freeaddrinfo(res) }
        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc2 = getnameinfo(res.pointee.ai_addr, res.pointee.ai_addrlen,
                              &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST)
        guard rc2 == 0 else {
            throw OtaError("Unable to resolve \(host)")
        }
        return String(cString: hostBuf)
    }
}

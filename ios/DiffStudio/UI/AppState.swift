// AppState.swift
// Port of MainActivity's state (St) and command flow (Java).
//
// One serial work queue (like Java's single-thread WORK executor):
// one operation at a time, progress throttled, errors reported through
// ErrorExplain. All Remote calls run off the main thread; UI updates
// are dispatched back to it.
//
// iOS differences from Android, documented:
//  * No foreground service / wake lock: analysis and upload run while
//    the app is in the foreground. The device-side transaction
//    continues on its own if the app is backgrounded (as on Android);
//    the 2 s status poll only runs while the app is active.
//  * Save dialogs use SwiftUI fileExporter (pick destination, then
//    generate), matching Android's order.
//  * Document access uses security-scoped URLs retained by AppState
//    until the file is replaced.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// UI state and command flow. Not @MainActor as a whole: long work
/// runs on a serial background queue and only touches @Published
/// state through `Task { @MainActor in ... }` (see run()).
public final class AppState: ObservableObject {
    // Assigned once during initialization and read only to dispatch onto MainActor.
    private final class RemoteEventTarget: @unchecked Sendable {
        weak var appState: AppState?
    }

    public static let defaultE5 = "192.168.9.1"
    public static let defaultMU300 = "192.168.77.1"

    // MARK: - Persistent preferences
    @AppStorage("language") public var language = "" // "" = zh, "en" = English
    @AppStorage("mode") public var mode = 0 // 0 = Diff Studio, 1 = OpenWrt Updater
    @AppStorage("darkOverride") public var darkOverride = "" // "" = system, "dark", "light"
    @AppStorage("autoReboot") public var autoReboot = true

    public var english: Bool { language == "en" }
    public var colorScheme: ColorScheme? {
        switch darkOverride {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    public func tr(_ key: String) -> String {
        Strings.localized(key, english: english)
    }

    // MARK: - Transient state
    @Published public var about = false
    @Published public var busy = false
    @Published public var monitoring = false
    @Published public var progress = ""

    // studio
    @Published public var oldURL: URL?
    @Published public var newURL: URL?
    @Published public var oldName = ""
    @Published public var newName = ""
    @Published public var analyzedOld: URL?
    @Published public var analyzedNew: URL?
    @Published public var analyzedOldIndex = false
    @Published public var analysis: OtaPackage.Analysis?
    @Published public var indexPath: URL?
    @Published public var studioError = ""
    @Published public var studioNotice = ""

    // updater
    @Published public var patchURL: URL?
    @Published public var patchName = ""
    @Published public var manifest: JsonObject?
    @Published public var review: JsonObject?
    @Published public var canReboot = false
    @Published public var host = defaultE5
    @Published public var password = ""

    @Published public var updaterError = ""
    @Published public var updaterNotice = ""

    // export / index sheets
    @Published public var exportRequest: ExportRequest?
    @Published public var showSavedIndexes = false
    @Published public var confirmDeleteIndex: URL?
    @Published public var confirmRebootAlert = false
    @Published public var indexActionSheet: URL?

    public struct ExportRequest: Identifiable, Equatable {
        public let id = UUID()
        public let kind: Kind
        public let suggestedName: String
        public enum Kind: Equatable { case bundleZip, otaOnly, index(URL) }
    }

    public let remote: Remote
    private let workQueue = DispatchQueue(label: "com.linote.diffstudio.work", qos: .userInitiated)
    private var lastProgress: UInt64 = 0
    private var lastUploadReport: UInt64 = 0
    private var pollTimer: Timer?
    private var scopedAccess = [URL: Bool]()

    public init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let eventTarget = RemoteEventTarget()
        self.remote = Remote(root: support) { data in
            Task { @MainActor in eventTarget.appState?.onRemoteProgress(data) }
        }
        eventTarget.appState = self
        // Restore the host default preference from the previous run.
        if let savedHost = UserDefaults.standard.string(forKey: "host"), !savedHost.isEmpty {
            host = savedHost
        }
    }

    // MARK: - Directories

    public func appSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    public func indexDir() -> URL {
        let dir = appSupport().appendingPathComponent("release-indexes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func patchesDir() -> URL {
        let dir = appSupport().appendingPathComponent("patches", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Security-scoped access

    private func retainAccess(_ url: URL) {
        if url.startAccessingSecurityScopedResource() {
            scopedAccess[url] = true
        }
    }

    private func releaseAccess(_ url: URL?) {
        guard let url, scopedAccess.removeValue(forKey: url) != nil else { return }
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - Work plumbing

    /// run(): one operation at a time, clears messages, reports the error string.
    public func run(_ task: @escaping () throws -> Void) {
        let modeAtStart = mode
        busy = true
        if modeAtStart == 0 { studioError = ""; studioNotice = "" } else { updaterError = ""; updaterNotice = "" }
        progress = ""
        updateIdleTimer()
        workQueue.async { [weak self] in
            var err: String?
            do {
                try task()
            } catch {
                err = Self.describe(error)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                if let err {
                    if modeAtStart == 0 { self.studioError = err } else { self.updaterError = err }
                }
                if !self.monitoring { self.updateIdleTimer() }
            }
        }
    }

    public static func describe(_ error: Error) -> String {
        if let e = error as? OtaError { return e.message }
        let msg = (error as NSError).localizedDescription
        let raw = String(describing: error)
        let text = msg.isEmpty ? raw : msg
        if raw.contains("Auth") || text.contains("Auth fail") || text.contains("USERAUTH") {
            return "Authentication failed. (\(text))"
        }
        if text.localizedCaseInsensitiveContains("timed out") || text.localizedCaseInsensitiveContains("timeout") {
            return "Connection timed out (\(text))"
        }
        if text.localizedCaseInsensitiveContains("unknown host") || raw.contains("DNS") {
            return "Unable to connect: unknown host \(text)"
        }
        if text.localizedCaseInsensitiveContains("No route to host") {
            return "No route to host (\(text))"
        }
        if text.localizedCaseInsensitiveContains("Connection refused") || text.localizedCaseInsensitiveContains("Unable to connect") {
            return "Unable to connect (\(text))"
        }
        if text.localizedCaseInsensitiveContains("BadZipFile") || raw.contains("ZipException") {
            return "BadZipFile: \(text)"
        }
        return text
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = busy || monitoring
    }

    public func onProgress(stage: String, path: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastProgress < 400_000_000 { return }
        lastProgress = now
        let p = path.isEmpty ? stage : path
        Task { @MainActor in self.progress = p }
    }

    private func onRemoteProgress(_ data: JsonObject) {
        guard case .string(let stage) = data["stage"], stage == "upload" else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let done = data["done"].flatMap { Json.isInt($0) ? Json.asLong($0) : nil } ?? 0
        let total = data["total"].flatMap { Json.isInt($0) ? Json.asLong($0) : nil } ?? 0
        if now - lastUploadReport < 200_000_000, done != total { return }
        lastUploadReport = now
        progress = "↑ " + Self.bytes(done) + " / " + Self.bytes(total)
    }

    public static func bytes(_ value: JsonValue?) -> String {
        let n: Int64 = {
            guard let value, Json.isInt(value) else { return 0 }
            return Json.asLong(value)
        }()
        return bytes(n)
    }

    public static func bytes(_ n: Int64) -> String {
        if n >= 1_048_576 {
            return String(format: "%.1f MiB", Double(n) / 1_048_576.0)
        }
        return String(format: "%.1f KiB", Double(n) / 1_024.0)
    }

    public static func str(_ value: JsonValue?) -> String {
        guard let value else { return "" }
        if case .string(let s) = value { return s }
        if case .int(let i) = value { return String(i) }
        if case .bool(let b) = value { return b ? "true" : "false" }
        return ""
    }

    // MARK: - Support files

    public struct AssetSupportFiles: OtaRuntime.SupportFiles {
        public init() {}
        public func read(family: String, name: String) throws -> Data {
            guard family == "e5" || family == "mu300" else {
                throw OtaError("Unsupported device family: \(family)")
            }
            let asset = name == "engine.py" ? "ota/\(family)/engine.py" : "ota/\(name)"
            guard let base = Foundation.Bundle.main.resourceURL?.appendingPathComponent("Assets"),
                  let data = try? Data(contentsOf: base.appendingPathComponent(asset)) else {
                throw OtaError("Missing support file: \(asset)")
            }
            return data
        }
    }

    /// Updater files bundled with an exported patch, matching that family's desktop edition.
    public struct MappedBundleFiles: Bundle.Files {
        public let family: String
        public init(family: String) { self.family = family }
        public func open(_ name: String) throws -> InputStream {
            guard family == "e5" || family == "mu300" else {
                throw OtaError("Unsupported device family: \(family)")
            }
            let asset: String
            if name == "files.json" { asset = "bundle/\(family)/files.json" }
            else if name == "backend/ota_engine.py" { asset = "ota/\(family)/engine.py" }
            else { asset = "bundle/common/\(name)" }
            guard let base = Foundation.Bundle.main.resourceURL?.appendingPathComponent("Assets"),
                  let stream = InputStream(url: base.appendingPathComponent(asset)) else {
                throw OtaError("Missing or unsafe native runtime file")
            }
            return stream
        }
    }

    // MARK: - Choosing files

    public func choose(kind: String, url: URL, name: String) {
        let want: (String) -> Bool = { n in
            let lower = n.lowercased()
            switch kind {
            case "patch": return lower.hasSuffix(".ota")
            case "old": return lower.hasSuffix(".zip") || lower.hasSuffix(".json")
            default: return lower.hasSuffix(".zip")
            }
        }
        if !want(name) {
            let msg: String
            switch kind {
            case "patch": msg = tr("Select an .ota patch.")
            case "old": msg = tr("Select an old ZIP or version index JSON.")
            default: msg = tr("The new release must be a full ZIP.")
            }
            if kind == "patch" { updaterError = msg } else { studioError = msg }
            return
        }
        if kind == "patch" { updaterError = "" } else { studioError = "" }
        review = nil
        analysis = nil
        indexPath = nil
        studioNotice = ""
        updaterNotice = ""
        canReboot = false
        if kind == "old" {
            releaseAccess(oldURL)
            oldURL = url
            oldName = name
            retainAccess(url)
        } else if kind == "new" {
            releaseAccess(newURL)
            newURL = url
            newName = name
            retainAccess(url)
        } else {
            patchName = name
            manifest = nil
            retainAccess(url)
            let pickedURL = url
            let pickedName = name
            run {
                let dir = self.patchesDir()
                if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for f in old { try? FileManager.default.removeItem(at: f) }
                }
                let safe = pickedName.map { c in
                    (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "_"
                }
                let dest = dir.appendingPathComponent(safe.isEmpty ? "update.ota" : String(safe))
                try AppIO.copyToFile(from: pickedURL, to: dest)
                let patch = try Ota.Patch(url: dest)
                let man = patch.manifest
                try? patch.close()
                self.remote.selectPatch(dest)
                Task { @MainActor in
                    self.releaseAccess(self.patchURL)
                    self.patchURL = dest
                    self.manifest = man
                    if self.host == Self.defaultE5 || self.host == Self.defaultMU300 {
                        if case .string(let family) = man["family"] {
                            self.host = family == "mu300" ? Self.defaultMU300 : Self.defaultE5
                        }
                    }
                }
            }
        }
    }

    /// Open-URL routing (mirrors handleViewIntent): .ota -> updater,
    /// .zip -> studio (old slot first, then new), .json -> old slot.
    public func handleOpenURL(_ url: URL) {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        if lower.hasSuffix(".ota") {
            mode = 1
            choose(kind: "patch", url: url, name: name)
        } else if lower.hasSuffix(".zip") {
            mode = 0
            choose(kind: oldURL == nil ? "old" : "new", url: url, name: name)
        } else if lower.hasSuffix(".json") {
            mode = 0
            choose(kind: "old", url: url, name: name)
        }
    }

    /// Host/password edits invalidate the review (mirrors Watcher).
    public func hostOrPasswordChanged() {
        review = nil
        canReboot = false
        UserDefaults.standard.set(host, forKey: "host")
    }

    // MARK: - Diff Studio commands

    private static func isIndex(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".json")
    }

    private func analyzeInputs(oldURL: URL, oldIsIndex: Bool, newURL: URL, output: URL?) throws -> OtaPackage.Analysis {
        let scratch = AppIO.scratch()
        var index: ReleaseIndex.Base?
        var oldSrc: Release.Source?
        if oldIsIndex {
            let accessing = oldURL.startAccessingSecurityScopedResource()
            defer { if accessing { oldURL.stopAccessingSecurityScopedResource() } }
            guard let stream = InputStream(url: oldURL) else {
                throw OtaError("Cannot open version index")
            }
            index = try ReleaseIndex.load(stream)
        } else {
            oldSrc = try AppIO.openRelease(url: oldURL, scratch: scratch)
        }
        let newSrc: Release.Source
        do {
            newSrc = try AppIO.openRelease(url: newURL, scratch: scratch)
        } catch {
            oldSrc?.cleanup?()
            throw error
        }
        return try OtaPackage.analyze(oldSrc: oldSrc, oldIndex: index, newSrc: newSrc,
                                      output: output, progress: { [weak self] stage, path in
                                          self?.onProgress(stage: stage, path: path)
                                      },
                                      support: AssetSupportFiles(), scratch: scratch,
                                      indexDirectory: indexDir())
    }

    public func analyze() {
        guard let oldURL, let newURL else { return }
        let oldIsIndex = Self.isIndex(oldName)
        indexPath = nil
        analysis = nil
        run {
            let r = try self.analyzeInputs(oldURL: oldURL, oldIsIndex: oldIsIndex, newURL: newURL, output: nil)
            Task { @MainActor in
                self.analyzedOld = oldURL
                self.analyzedOldIndex = oldIsIndex
                self.analyzedNew = newURL
                self.analysis = r
                self.indexPath = r.indexPath
            }
        }
    }

    public func requestExport(bundle: Bool) {
        guard let r = analysis else { return }
        exportRequest = ExportRequest(kind: bundle ? .bundleZip : .otaOnly,
                                      suggestedName: bundle ? r.suggestedName
                                          : r.suggestedName.replacingOccurrences(of: "(?i)\\.zip$", with: ".ota", options: .regularExpression))
    }

    public func export(to dest: URL, bundle: Bool, intendedName: String) {
        guard let oldURL = analyzedOld, let newURL = analyzedNew else {
            studioError = tr("Analyze the old and new release first")
            return
        }
        let oldIsIndex = analyzedOldIndex
        indexPath = nil
        run {
            let target = AppIO.fixSavedName(dest, intended: intendedName)
            let scratch = AppIO.scratch()
            let dir = scratch.appendingPathComponent("export-\(UInt64(DispatchTime.now().uptimeNanoseconds))", isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
                throw OtaError("Cannot create temporary export directory")
            }
            defer {
                if let left = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for f in left { try? FileManager.default.removeItem(at: f) }
                }
                try? FileManager.default.removeItem(at: dir)
            }
            let patch = dir.appendingPathComponent("update.ota")
            let r = try self.analyzeInputs(oldURL: oldURL, oldIsIndex: oldIsIndex, newURL: newURL, output: patch)
            Task { @MainActor in self.indexPath = r.indexPath }
            var out = patch
            if bundle {
                self.onProgress(stage: "bundle", path: "README.md")
                guard case .string(let family) = r.manifest["family"] else {
                    throw OtaError("Invalid OTA family/profile")
                }
                out = dir.appendingPathComponent("bundle.zip")
                try Bundle.export(patch: patch, output: out, runtime: MappedBundleFiles(family: family))
            }
            try AppIO.copyToFile(from: out, to: target)
            let shown = AppIO.displayName(target)
            let ext = bundle ? ".zip" : ".ota"
            let extOk = shown.lowercased().hasSuffix(ext)
            Task { @MainActor in
                self.studioNotice = String(format: self.tr("Patch saved: %@"), shown)
                    + (extOk ? "" : "\n" + String(format: self.tr("This location does not allow renaming; change the file extension to %@ in your file manager."), ext))
            }
        }
    }

    // MARK: - Version indexes

    public func listIndexes() -> [URL] {
        let dir = indexDir()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(ReleaseIndex.SUFFIX) }
            .sorted {
                let da = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    public func indexLabel(_ url: URL) -> String {
        var label = url.lastPathComponent
        label = String(label.dropLast(ReleaseIndex.SUFFIX.count))
        if label.hasPrefix("OpenWrt-") { label = String(label.dropFirst(8)) }
        if label.count > 65, label[label.index(label.endIndex, offsetBy: -65)] == "-" {
            label = String(label.dropLast(65))
        }
        return label
    }

    public func exportIndex(_ index: URL) {
        exportRequest = ExportRequest(kind: .index(index), suggestedName: index.lastPathComponent)
    }

    public func exportIndexFile(_ index: URL, to dest: URL, intendedName: String) {
        run {
            guard FileManager.default.isReadableFile(atPath: index.path) else {
                throw OtaError("Analyze a compatible release first / 请先完成兼容版本的差异分析")
            }
            let raw = try ReleaseIndex.serialize(ReleaseIndex.readIndex(url: index))
            let target = AppIO.fixSavedName(dest, intended: intendedName)
            let tmp = AppIO.scratch().appendingPathComponent("index-\(UInt64(DispatchTime.now().uptimeNanoseconds)).json")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try raw.write(to: tmp)
            try AppIO.copyToFile(from: tmp, to: target)
            let shown = AppIO.displayName(target)
            let extOk = shown.lowercased().hasSuffix(".json")
            Task { @MainActor in
                self.studioNotice = String(format: self.tr("Version index exported: %@"), shown)
                    + (extOk ? "" : "\n" + self.tr("This location does not allow renaming; change the file extension to .json in your file manager."))
            }
        }
    }

    public func deleteIndex(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if indexPath == url { indexPath = nil }
        if oldURL == url {
            releaseAccess(oldURL)
            oldURL = nil
            oldName = ""
            analysis = nil
        }
    }

    // MARK: - Updater commands

    public func probe() {
        let host = host, pw = password
        let patch = patchURL
        run {
            let r = try self.remote.probe(host: host, password: pw, path: patch)
            Task { @MainActor in self.review = r }
        }
    }

    public func apply() {
        guard let j = review else { return }
        let host = host, pw = password
        let auto = autoReboot
        let token = Json.str(j["token"])
        run {
            _ = try self.remote.apply(host: host, password: pw, token: token, autoReboot: auto)
            Task { @MainActor in
                self.canReboot = false
                self.monitoring = true
                self.review = nil
                self.schedulePoll()
            }
        }
    }

    public func checkStatus() {
        let host = host, pw = password
        let patch = patchURL
        run {
            let r = try self.remote.status(host: host, password: pw, path: patch)
            Task { @MainActor in
                let job = Json.map(r["job"])
                let running = Json.str(job?["status"]) == "running"
                let was = self.monitoring
                self.monitoring = running
                self.handleStatus(r)
                if running, !was { self.schedulePoll() }
            }
        }
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        updateIdleTimer()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        updateIdleTimer()
    }

    private func poll() {
        guard monitoring else { return }
        let host = host, pw = password
        let patch = patchURL
        workQueue.async { [weak self] in
            guard let self else { return }
            var again = true
            do {
                let r = try self.remote.status(host: host, password: pw, path: patch)
                let tx = Json.map(r["transaction"])
                let job = Json.map(r["job"])
                if let tx {
                    let p = Self.str(tx["started"]) + " / " + Self.str(tx["total"])
                    Task { @MainActor in self.progress = p }
                } else if let job, case .string(let phase) = job["phase"] {
                    let p = self.phaseLabel(phase)
                    Task { @MainActor in self.progress = p }
                }
                if job == nil || Json.str(job?["status"]) != "running" {
                    again = false
                    Task { @MainActor in
                        self.monitoring = false
                        self.stopPolling()
                        self.handleStatus(r)
                    }
                }
            } catch {
                Task { @MainActor in
                    self.progress = self.tr("Connection interrupted. The device continues processing; check status again later.")
                }
            }
            if again {
                // Timer keeps firing every 2 s while monitoring.
            }
        }
    }

    public func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "queued": return tr("Started; waiting for the device…")
        case "staging": return tr("Preparing update files…")
        case "runtime": return tr("Preparing the update…")
        case "applying": return tr("Updating the system…")
        default: return phase
        }
    }

    /// handleStatus(): interpret a status result.
    public func handleStatus(_ l: JsonObject) {
        let job = Json.map(l["job"])
        let tx = Json.map(l["transaction"])
        let reboot = Json.map(l["reboot"])
        let activation = Json.map(l["activation"])
        let jobStatus = Json.str(job?["status"])
        let txStatus = tx.flatMap { Json.str($0["status"]) } ?? ""
        let complete = jobStatus == "complete" && (txStatus == "complete" || txStatus == "rolled_back")
        updaterNotice = ""
        updaterError = ""
        canReboot = complete
        if jobStatus == "failed" {
            let res = Json.map(job?["result"])
            let e = res.flatMap { Json.str($0["error"]) }
            updaterError = (e != nil && !e!.isEmpty) ? e! : tr("Update incomplete. Review device transaction status.")
            return
        }
        if let reboot, Json.str(reboot["status"]) == "rebooting" {
            canReboot = false
            updaterNotice = tr("Update complete. The device is rebooting. Check its status again shortly.")
        } else if let reboot, Json.truthy(reboot["error"]) {
            updaterError = String(format: tr("Update completed, but reboot failed. Retry below: %@"), Self.str(reboot["error"]))
        } else if complete {
            updaterNotice = txStatus == "rolled_back"
                ? tr("Rollback complete. Reboot the device here.")
                : tr("Update complete. Reboot the device here to activate the update.")
        } else if jobStatus != "running" {
            let identity = Json.map(l["identity"])
            updaterNotice = String(format: tr("Device status loaded. Current version: %@"), identity.flatMap { Self.str($0["version"]) } ?? "")
        }
        if let activation, Json.str(activation["status"]) == "warning" {
            updaterError = String(format: tr("System files are updated, but web plugin reload failed: %@"), Self.str(activation["error"]))
        }
    }

    public func rebootDevice() {
        let host = host, pw = password
        run {
            _ = try self.remote.reboot(host: host, password: pw)
            Task { @MainActor in
                self.canReboot = false
                self.updaterNotice = self.tr("Reboot requested. The device is restarting.")
            }
        }
    }

    public var analyzeEnabled: Bool { oldURL != nil && newURL != nil && !busy && !monitoring }
    public var connectEnabled: Bool { patchURL != nil && !host.isEmpty && !busy && !monitoring }
    public var statusEnabled: Bool { !host.isEmpty && !busy }
}

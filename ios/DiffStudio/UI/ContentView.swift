// ContentView.swift
// App shell mirroring MainActivity.fullRender(): header, mode tabs,
// intro, the two tool pages, messages, footer, and the About page.

import SwiftUI
import UniformTypeIdentifiers

// SwiftUI's fileExporter requires a FileDocument to present the save picker.
// AppState replaces this empty placeholder with the generated file on completion.
private struct ExportPlaceholderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .zip, .json, .ota] }
    static var writableContentTypes: [UTType] { readableContentTypes }

    init() {}
    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

public struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var exportPresented = false
    @State private var exportKind: AppState.ExportRequest.Kind = .bundleZip
    @State private var exportName = ""

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if state.about {
                    AboutView()
                } else {
                    tabs
                    intro
                    if state.mode == 0 {
                        DiffStudioView()
                    } else {
                        UpdaterView()
                    }
                    messages
                    footer
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $state.showSavedIndexes) {
            SavedIndexesSheet()
                .environmentObject(state)
        }
        .alert(isPresented: $state.confirmRebootAlert) {
            Alert(
                title: Text(state.tr("Reboot device?")),
                message: Text(state.tr("The update is complete. Rebooting briefly disconnects networking; settings and data are retained.")),
                primaryButton: .default(Text(state.tr("Confirm reboot"))) { state.rebootDevice() },
                secondaryButton: .cancel(Text(state.tr("Cancel")))
            )
        }
        .fileExporter(isPresented: $exportPresented,
                      document: ExportPlaceholderDocument(),
                      contentType: exportContentType,
                      defaultFilename: exportName) { result in
            if case .success(let url) = result {
                switch exportKind {
                case .bundleZip:
                    state.export(to: url, bundle: true, intendedName: exportName)
                case .otaOnly:
                    state.export(to: url, bundle: false, intendedName: exportName)
                case .index(let index):
                    state.exportIndexFile(index, to: url, intendedName: exportName)
                }
            }
            state.exportRequest = nil
        }
        .onChange(of: state.exportRequest) { request in
            if let request {
                exportKind = request.kind
                exportName = request.suggestedName
                exportPresented = true
            }
        }
    }

    private var exportContentType: UTType {
        switch exportKind {
        case .bundleZip: return .zip
        case .otaOnly: return .ota
        case .index: return .json
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(state.mode == 0 ? "Δ" : "↻")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.mode == 0 ? "OpenWrt Diff Studio" : "OpenWrt Updater")
                    .font(.system(size: 16, weight: .bold))
                Text(state.tr("Keep your data · Update changed files"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(state.english ? "中文" : "English") {
                state.language = state.english ? "" : "en"
            }
            .buttonStyle(.bordered)
            .frame(height: 40)
            .disabled(state.busy || state.monitoring)
            Button(state.about ? "✕" : "ⓘ") {
                state.about.toggle()
            }
            .buttonStyle(.bordered)
            .frame(width: 44, height: 40)
            Button(state.darkOverride == "dark" ? "☀" : "☾") {
                state.darkOverride = state.darkOverride == "dark" ? "light" : "dark"
            }
            .buttonStyle(.bordered)
            .frame(width: 44, height: 40)
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { i in
                Button(state.tr(i == 0 ? "Create patch" : "Update device")) {
                    if state.mode != i {
                        state.mode = i
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: state.mode == i ? .bold : .regular))
                .foregroundColor(state.mode == i ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(state.mode == i ? Color(.secondarySystemGroupedBackground) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(4)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.top, 14)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.mode == 0 ? "RELEASE TO PATCH" : "DIFFERENTIAL SYSTEM UPDATE")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.accentColor)
                .tracking(1.5)
                .padding(.top, 20)
            Text(state.mode == 0
                 ? state.tr("Two releases. One compact update.")
                 : state.tr("Update the system. Keep your setup."))
                .font(.system(size: 25, weight: .bold))
            Text(state.mode == 0
                 ? state.tr("Use an old full ZIP or saved version index, and a new full ZIP. A new index is saved after analysis.")
                 : state.tr("Import a trusted patch and connect to a running OpenWrt device. Review before applying."))
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding(.bottom, 18)
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.busy || state.monitoring {
                NoticeBoxView(
                    message: state.monitoring
                        ? state.tr("Device is writing. Closing this app does not cancel its transaction.")
                        : state.tr("Processing…"),
                    spinner: true,
                    small: state.progress.isEmpty ? nil : state.progress)
            }
            let error = state.mode == 0 ? state.studioError : state.updaterError
            let notice = state.mode == 0 ? state.studioNotice : state.updaterNotice
            if !error.isEmpty {
                ErrorBoxView(raw: error)
            }
            if !notice.isEmpty {
                NoticeBoxView(message: notice)
            }
            if state.mode == 1, state.canReboot {
                Button("⏻  " + state.tr("Reboot device")) {
                    state.confirmRebootAlert = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.top, 12)
                .disabled(state.busy || state.monitoring)
            }
        }
    }

    private var footer: some View {
        Text("ⓘ  " + state.tr("Settings, extra packages and user data are retained. Recovery copies precede writes. Kernel and modules can update together. Import trusted patches only."))
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .padding(.top, 22)
    }
}

private struct SavedIndexesSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var actionURL: URL?
    @State private var deleteURL: URL?

    var body: some View {
        NavigationView {
            List {
                let files = state.listIndexes()
                if files.isEmpty {
                    Text(state.tr("No saved indexes yet. After a successful analysis the new release's index is saved here."))
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    Button {
                        actionURL = url
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.indexLabel(url))
                                .font(.system(size: 14))
                                .lineLimit(2)
                            Text(indexMeta(url))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(state.tr("Saved version indexes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.tr("Close")) { state.showSavedIndexes = false }
                }
            }
            .confirmationDialog("", isPresented: Binding(
                get: { actionURL != nil },
                set: { if !$0 { actionURL = nil } }
            )) {
                Button(state.tr("Use as old release")) {
                    if let url = actionURL {
                        state.choose(kind: "old", url: url, name: url.lastPathComponent)
                        state.showSavedIndexes = false
                    }
                }
                Button(state.tr("Export")) {
                    if let url = actionURL {
                        state.exportIndex(url)
                    }
                }
                Button(state.tr("Delete"), role: .destructive) {
                    deleteURL = actionURL
                }
                Button(state.tr("Cancel"), role: .cancel) {}
            } message: {
                Text(actionURL?.lastPathComponent ?? "")
            }
            .alert(isPresented: Binding(
                get: { deleteURL != nil },
                set: { if !$0 { deleteURL = nil } }
            )) {
                Alert(
                    title: Text(state.tr("Delete this version index?")),
                    message: Text(deleteURL?.lastPathComponent ?? ""),
                    primaryButton: .destructive(Text(state.tr("Delete"))) {
                        if let url = deleteURL {
                            state.deleteIndex(url)
                            deleteURL = nil
                        }
                    },
                    secondaryButton: .cancel(Text(state.tr("Cancel")))
                )
            }
        }
    }

    private func indexMeta(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: date) + " · " + AppState.bytes(size)
    }
}

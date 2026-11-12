// DiffStudioView.swift
// "Create patch" tab: card 1 (select releases + analyze) and card 2
// (review + export), mirroring MainActivity's mode 0 rendering.

import SwiftUI
import UniformTypeIdentifiers

public struct DiffStudioView: View {
    @EnvironmentObject private var state: AppState
    @State private var pickingOld = false
    @State private var pickingNew = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardView {
                HeadingView(number: "1", title: state.tr("Select releases"))
                SectionLabel(state.tr("Old full release or version index"))
                PickerButton(value: state.oldName, placeholder: state.tr("Select ZIP or version index JSON")) {
                    pickingOld = true
                }
                .disabled(state.busy || state.monitoring)
                Button(state.tr("Saved version indexes")) {
                    state.showSavedIndexes = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .disabled(state.busy || state.monitoring)
                Text("↓")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                SectionLabel(state.tr("New full release"))
                PickerButton(value: state.newName, placeholder: state.tr("Select ZIP file")) {
                    pickingNew = true
                }
                .disabled(state.busy || state.monitoring)
                Button(state.tr("Analyze changes")) {
                    state.analyze()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .disabled(!state.analyzeEnabled)
            }

            CardView {
                HeadingView(number: "2", title: state.tr("Review and continue"))
                if let manifest = state.analysis?.manifest {
                    releaseInfo(manifest)
                    if Json.truthy(manifest["boot"]) {
                        NoticeBoxView(message: state.tr("Includes kernel/boot update and matching module changes. User packages, settings and data are retained."))
                    }
                    if let analysis = state.analysis {
                        stats(analysis)
                        if !analysis.blockers.isEmpty {
                            blockersBox(analysis)
                        }
                        fileList(analysis)
                        Button(state.tr("Export patch")) {
                            state.requestExport(bundle: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                        .disabled(state.busy || state.monitoring || !analysis.canExport)
                        Button(state.tr("Export .ota only")) {
                            state.requestExport(bundle: false)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .disabled(state.busy || state.monitoring || !analysis.canExport)
                    }
                    if let indexPath = state.indexPath {
                        indexSavedBox(indexPath)
                    }
                } else {
                    Text("◎\n" + state.tr("Select files to review versions and compatibility here."))
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                }
            }
        }
        .fileImporter(isPresented: $pickingOld, allowedContentTypes: [.zip, .json]) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.choose(kind: "old", url: url, name: url.lastPathComponent)
            }
        }
        .fileImporter(isPresented: $pickingNew, allowedContentTypes: [.zip]) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.choose(kind: "new", url: url, name: url.lastPathComponent)
            }
        }
    }

    private func releaseInfo(_ man: JsonObject) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(state.tr("Target profile"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(AppState.str(man["profile"]))
                    .font(.system(size: 14, weight: .bold))
            }
            Text(AppState.str(man["kernel_release"]))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(AppState.str(man["base_version"]) + "\n→ " + AppState.str(man["target_version"]))
                .font(.system(size: 14, design: .monospaced))
                .padding(.top, 8)
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 14)
    }

    private func stats(_ analysis: OtaPackage.Analysis) -> some View {
        HStack(spacing: 6) {
            StatView(value: String(analysis.files), caption: state.tr("Changed files"))
            StatView(value: AppState.bytes(analysis.payloadBytes), caption: state.tr("Uncompressed payload"))
            StatView(value: "\(analysis.added) / \(analysis.removed)", caption: state.tr("Added / removed"))
        }
        .padding(.top, 12)
    }

    private func blockersBox(_ analysis: OtaPackage.Analysis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(analysis.blockers, id: \.self) { b in
                Text(ErrorExplain.explain(b, english: state.english).message)
                    .font(.system(size: 14))
                    .foregroundColor(.red)
            }
            DetailsView(summary: state.tr("Technical details"), body: analysis.blockers.joined(separator: "\n"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 12)
    }

    private func fileList(_ analysis: OtaPackage.Analysis) -> some View {
        let ops = Json.list(analysis.manifest["operations"]) ?? []
        var lines: [String] = []
        var shown = 0
        for oo in ops {
            guard let op = Json.map(oo) else { continue }
            if shown == 4000 {
                lines.append("… +\(ops.count - shown)")
                break
            }
            let before = op["before"]
            let after = op["after"]
            let mark: String
            if before != nil, before != .null {
                mark = (after != nil && after != .null) ? "~" : "−"
            } else {
                mark = "+"
            }
            lines.append(mark + " " + AppState.str(op["path"]))
            shown += 1
        }
        return DetailsView(summary: state.tr("View file list"), body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func indexSavedBox(_ indexPath: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.tr("New version index saved"))
                .font(.system(size: 14, weight: .bold))
            Text(state.tr("Use it as the old input next time. Saving an index does not mean the device was updated."))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text(indexPath.lastPathComponent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            Button(state.tr("Export version index")) {
                state.exportIndex(indexPath)
            }
            .buttonStyle(.bordered)
            .padding(.top, 10)
            .disabled(state.busy || state.monitoring)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 14)
    }
}

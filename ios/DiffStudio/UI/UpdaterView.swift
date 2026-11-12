// UpdaterView.swift
// "Update device" tab: card 1 (patch + device) and card 2 (review +
// apply), mirroring MainActivity's mode 1 rendering.

import SwiftUI
import UniformTypeIdentifiers

public extension UTType {
    /// .ota is declared in Info.plist (UTExportedTypeDeclarations);
    /// fall back to generic data when the declaration is unavailable.
    static var ota: UTType {
        UTType(filenameExtension: "ota") ?? .data
    }
}

public struct UpdaterView: View {
    @EnvironmentObject private var state: AppState
    @State private var pickingPatch = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardView {
                HeadingView(number: "1", title: state.tr("Select patch and device"))
                PickerButton(value: state.patchName, placeholder: state.tr("Select .ota patch")) {
                    pickingPatch = true
                }
                .disabled(state.busy || state.monitoring)
                .padding(.top, 8)
                SectionLabel(state.tr("Device management address"))
                TextField(state.tr("Device management address"), text: $state.host)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(.top, 6)
                    .disabled(state.busy || state.monitoring)
                    .onChange(of: state.host) { _ in state.hostOrPasswordChanged() }
                SectionLabel("SSH root " + state.tr("password"))
                SecureField(state.tr("password"), text: $state.password)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 6)
                    .disabled(state.busy || state.monitoring)
                    .onChange(of: state.password) { _ in state.hostOrPasswordChanged() }
                Button(state.tr("Connect and review")) {
                    state.probe()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .disabled(!state.connectEnabled)
                Button(state.tr("Check device status")) {
                    state.checkStatus()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .disabled(!state.statusEnabled)
            }

            CardView {
                HeadingView(number: "2", title: state.tr("Review and continue"))
                if let manifest = state.manifest {
                    releaseInfo(manifest)
                    if Json.truthy(manifest["boot"]) {
                        NoticeBoxView(message: state.tr("Includes kernel/boot update and matching module changes. User packages, settings and data are retained."))
                    }
                } else {
                    Text("◎\n" + state.tr("Select files to review versions and compatibility here."))
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                }
                if let review = state.review {
                    reviewBox(review)
                }
            }
        }
        .fileImporter(isPresented: $pickingPatch, allowedContentTypes: [.ota]) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.choose(kind: "patch", url: url, name: url.lastPathComponent)
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

    private func reviewBox(_ j: JsonObject) -> some View {
        let check = Json.map(j["check"]) ?? JsonObject()
        var conflicts: [String] = []
        for key in ["conflicts", "package_conflicts"] {
            if let list = Json.list(check[key]) {
                for x in list { conflicts.append(AppState.str(x)) }
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text(String(format: state.tr("Required / available: %@ / %@"), AppState.bytes(check["required_bytes"]), AppState.bytes(check["free_bytes"])))
                .font(.system(size: 14))
                .padding(.top, 14)
            if !conflicts.isEmpty {
                Text(String(format: state.tr("Local file or dependency conflicts; nothing written: %@"), conflicts.joined(separator: ", ")))
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 10)
            }
            Toggle(state.tr("Automatically reboot after updating"), isOn: $state.autoReboot)
                .padding(.top, 12)
                .disabled(state.busy || state.monitoring)
            Button(state.tr("Apply reviewed patch")) {
                state.apply()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .disabled(state.busy || state.monitoring || !Json.truthy(check["applicable"]))
        }
    }
}

// AboutView.swift
// About page, mirroring MainActivity.buildAbout() — usage, important
// notes, friend links, and the licence note for this iOS port.

import SwiftUI

public struct AboutView: View {
    @EnvironmentObject private var state: AppState

    public init() {}

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.2"
    }

    private struct Item {
        let mark: String
        let text: String
        let heading: Bool
        init(_ mark: String, _ text: String, heading: Bool = false) {
            self.mark = mark
            self.text = text
            self.heading = heading
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("‹  " + state.tr("Back")) {
                state.about = false
            }
            .buttonStyle(.bordered)
            .padding(.top, 14)

            CardView {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                    Text("OpenWrt Diff Studio")
                        .font(.system(size: 19, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(String(format: state.tr("iOS version %@"), version))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(state.tr("Compare two full OpenWrt releases, build a patch with only the changed files, and update the device directly over SSH. Settings, extra packages and user data are kept."))
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity)
            }

            aboutSection(title: state.tr("How to use"), items: howToUse, numbered: true)
            aboutSection(title: state.tr("Important notes"), items: notes, numbered: false)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                    Text(state.tr("Links")).font(.system(size: 13)).foregroundColor(.secondary)
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                }
                HStack(spacing: 16) {
                    Link(state.tr("GitHub"), destination: URL(string: "https://github.com/linote99")!)
                    Link(state.tr("Lino Notes"), destination: URL(string: "https://www.linote.top/")!)
                }
                .frame(maxWidth: .infinity)
                Text(state.tr("Licences: app code MIT; ext4 parser AGPL-3.0-or-later; third-party notices in THIRD_PARTY_NOTICES.md."))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .padding(.top, 10)
        }
    }

    private var howToUse: [Item] {
        [
            Item("", state.tr("Create patch"), heading: true),
            Item("1", state.tr("On Create patch, select the old release (the version the device runs now) and the new full release ZIP. A saved version index can replace the old full ZIP. E5 and MU300 / F50 / V50 / U30Air are supported.")),
            Item("2", state.tr("Tap Analyze to review the target device, version change, changed files and payload size. Blocking reasons are listed if a patch cannot be made.")),
            Item("3", state.tr("Tap Export patch to save the complete update ZIP (update.ota, desktop updater and README), or Export .ota only.")),
            Item("4", state.tr("After a successful analysis, the new release's version index (.owrt-index.json) is saved in the app. Next time, tap Saved version indexes to use it as the old release, export it for the desktop app, or delete it.")),
            Item("", state.tr("Update device"), heading: true),
            Item("1", state.tr("Connect the phone to the device's Wi-Fi or USB tethering and select the .ota patch on Update device. You can also open an .ota with this app from a file manager.")),
            Item("2", state.tr("Enter the management address (E5 192.168.9.1, MU300 192.168.77.1 by default; host:port also works) and the root password.")),
            Item("3", state.tr("Tap Connect and review. When space, local changes, dependencies and version all pass, tap Apply reviewed patch. Optionally enable automatic reboot.")),
            Item("4", state.tr("Progress is shown automatically; you can also tap Check device status at any time. Reboot the device when prompted.")),
        ]
    }

    private var notes: [Item] {
        [
            Item("•", state.tr("Only import and apply patches from trusted sources. Patches write system files as root.")),
            Item("•", state.tr("The old release must match what the device runs now. Do not force an update when the review fails.")),
            Item("•", state.tr("Keep the device powered during the update and do not unplug or reboot it. The phone may lock or switch apps; the device finishes on its own.")),
            Item("•", state.tr("The device keeps recovery copies before writing and rolls back on failure; still back up important settings in the device web UI first.")),
            Item("•", state.tr("Analyzing an E5 release temporarily extracts the root filesystem image; keep enough free storage (usually several hundred MB or more).")),
            Item("•", state.tr("If the device Wi-Fi reports no internet, stay connected; the app automatically uses the network that reaches the device.")),
            Item("•", state.tr("The device identity is verified between review and apply; review again after switching or resetting the device.")),
            Item("•", state.tr("If the save dialog shortens the file name, just save; the full name and extension are restored after export.")),
            Item("•", state.tr("A version index only records the file list, package versions and checksums. It holds no system files and does not mean the device was updated. The old index must match what the device runs now.")),
            Item("•", state.tr("Exported patches use the desktop format and can also be applied with the desktop updater or in the device web UI (System > System patches).")),
        ]
    }

    private func aboutSection(title: String, items: [Item], numbered: Bool) -> some View {
        CardView {
            Text(title).font(.system(size: 17, weight: .bold))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.heading {
                    Text(item.text)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.accentColor)
                        .padding(.top, 14)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.mark)
                            .font(.system(size: 14, weight: numbered ? .bold : .regular))
                            .foregroundColor(numbered ? .accentColor : .secondary)
                            .frame(minWidth: 22, alignment: .leading)
                        Text(item.text)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}

# OpenWrt Diff Studio — iOS port

SwiftUI port of the Android app **OpenWrt Diff Studio v1.1.2**
(`openwrt-diff-studio`, commit `9a826b9`). Same features, same
output formats:

- **Create patch**: pick an old full OpenWrt release ZIP (or a saved
  `.owrt-index.json` version index) and a new full release ZIP, analyse
  the changed files / kernel / boot images / package dependencies, and
  export a full update ZIP (with `update.ota`, the desktop updater and
  notes) or just the `.ota`. E5 (ext4 rootfs) and MU300 / F50 / F50 Pro /
  U30 Pro / V50 / U30Air (tar rootfs) are supported. Exported patches
  use the desktop format and can also be applied with the desktop
  updater or in the device web UI.
- **Update device**: pick a `.ota` patch, enter the device management
  address and root password, connect over SSH, review (space, local
  changes, dependencies, version), apply as root, optionally reboot.
- Saved version indexes (`.owrt-index.json`, checksummed, tamper
  rejected), Chinese/English, dark/light via system, progress and error
  banners matching the Android app.

Bundle id `com.linote.diffstudio`, version 1.1.2, build 7. Requires
iOS 16+, Xcode 16.

## The IPA is unsigned

The `.ipa` produced by the GitHub Actions workflow (and by the archive
steps below) is **unsigned** (`CODE_SIGNING_ALLOWED=NO`). It cannot be
installed on an iPhone directly. It must be signed first — see
[Self-sign and install](#self-sign-and-install).

## Build in Xcode

1. Open `DiffStudio.xcodeproj` in Xcode 16.
2. Xcode resolves the Swift Package dependency
   [NIOSSH](https://github.com/apple/swift-nio-ssh) (pinned `0.12.0` to
   `< 0.13.0`) on first open — needs network access to GitHub.
3. Select an iPhone (or "Any iOS Device") as the run destination and
   press Run. No signing is required to build; the project sets
   `CODE_SIGNING_ALLOWED=NO` / empty `CODE_SIGN_IDENTITY`.
4. To make an unsigned archive: Product → Archive, then in the
   Organizer right-click the archive → Show in Finder, and copy
   `DiffStudio.app` out of
   `DiffStudio.xcarchive/Products/Applications/`.

## Get the IPA from GitHub Actions

Push changes under `ios/` to `main` (or run the workflow manually from
the Actions tab). The repository-root workflow
[`../.github/workflows/build-ipa.yml`](../.github/workflows/build-ipa.yml)
runs the XCTest suite on an iOS Simulator, archives for
`generic/platform=iOS` with signing disabled, zips
`Payload/DiffStudio.app` into `DiffStudio-unsigned.ipa`, verifies the
IPA contains the app binary and the `Assets/` runtime files, and uploads
it as the `DiffStudio-unsigned` artifact. Download it from the workflow
run's Artifacts section.

## Self-sign and install

You need a free Apple ID (no paid developer account) and a computer
with **AltStore** or **Sideloadly**. The free-Apple-ID certificate lasts
7 days; AltStore can refresh it automatically over Wi-Fi, Sideloadly
requires re-signing manually.

**AltStore** (recommended):

1. Install AltServer on your Mac/PC and AltStore on your iPhone
   (altstore.io).
2. In AltStore, tap **My Apps → +** and choose
   `DiffStudio-unsigned.ipa`. Sign in with your Apple ID when asked.
3. On the iPhone, go to Settings → General → VPN & Device Management
   and trust your Apple ID developer certificate.
4. Open the app. AltStore refreshes the 7-day signature while the phone
   is on the same Wi-Fi as the computer running AltServer.

**Sideloadly**:

1. Connect the iPhone to your computer, open Sideloadly, drag
   `DiffStudio-unsigned.ipa` in, enter your Apple ID, and click Start.
2. Trust the developer certificate as above.

## Project layout

```
DiffStudio.xcodeproj/          Xcode project (Xcode 16, iOS 16+, arm64)
DiffStudio/
  DiffStudioApp.swift          @main entry point, .onOpenURL for .ota/.zip/.json
  Info.plist                   bundle id, version 1.1.2 (7), .ota/.zip/.json
                               document types, NSLocalNetworkUsageDescription
  Core/                        pure-logic port of the Java core package
    Zip.swift                  ZipIn/ZipOut (manual central-directory parsing,
                               no ZIPFoundation — exact Java behaviour)
    TarIn.swift  Ext4.swift    tar reader; read-only ext2/3/4 parser (AGPL-3.0)
    Gzip.swift                 streaming gzip (CZlib on Linux; pure-Swift
                               inflate on Apple platforms)
    Json.swift                 ordered JSON, duplicate-field rejection
    Release.swift              E5 (ext4.gz) / MU300 (tar.gz) release indexer
    ReleaseIndex.swift         .owrt-index.json (checksum + tamper rejection)
    Ota.swift  OtaPackage.swift  OTA protocol 2, analysis + export
    OtaRuntime.swift           device-side runtime builder + bootstrap.sh
    Bundle.swift               full update ZIP export, asset manifests
    Py.swift                   Python-compat helpers (hashing, quoting, …)
    ErrorExplain.swift         the 22 ordered error explanations (zh/en)
    AppIO.swift                iOS equivalent of AndroidIo
  SSH/
    Remote.swift               SSH client on NIOSSH (password auth, exec,
                               upload, progress, host-key pinning)
  UI/
    AppState.swift             all app state + work flow (port of MainActivity)
    ContentView.swift          header, tabs, intro, messages, footer
    DiffStudioView.swift       Create patch tab
    UpdaterView.swift          Update device tab
    AboutView.swift            About page
    Components.swift           shared SwiftUI components
    Strings.swift              Localizable.strings lookup (keys = English)
  Resources/
    en.lproj/  zh-Hans.lproj/  Localizable.strings (100 keys each)
    Assets.xcassets/           app icon (Δ)
Assets/                        device-side runtime files, byte-identical to
                               the Android app's assets/ (28 files, 372K)
DiffStudioTests/               XCTest ports + new tests (see below)
../.github/workflows/build-ipa.yml
```

## Tests

`DiffStudioTests/` contains:

- `RuntimeAndProfileTests` — port of Java `RuntimeAndProfileTest`
  (patch filename profile labels; bootstrap separates session id from
  reviewed patch id).
- `RemoteStartCommandTests` — port of Java `RemoteStartCommandTest`
  (start command uses the reviewed patch id; missing id is rejected).
- `IndexAndAssetsTests` — new: `.owrt-index.json` round-trips through
  serialize / write / read, tampering is rejected, and every bundled
  asset's SHA-256 matches the Android v1.1.2 assets.

Run them in Xcode (Product → Test) or in the GitHub Actions workflow.

## Known gaps and divergences from Android

- **NIOSSH offers password and public-key auth only** — there is no
  keyboard-interactive offer in NIOSSH 0.12.0. Java's JSch tried
  keyboard-interactive as a second round; here the password is offered
  once and then no further offer is made. Devices that require
  keyboard-interactive will fail to authenticate.
- **NIOSSH is modern-crypto-only** (Ed25519, ECDSA, AES-GCM, x25519).
  Old Dropbear devices offering only legacy DH / CBC / MD5 / ssh-rsa
  will fail to negotiate; Java's JSch had legacy algorithms appended.
  This surfaces as a connection failure — there is no silent downgrade.
- `backend/ota_engine.py` is listed in both `files.json` manifests but
  is not present in `bundle/common/backend/`; like Android, the iOS
  export maps it to `ota/<family>/engine.py`.
- `ZipOut` buffers each whole entry's uncompressed data in memory
  before deflating (as in Java); large single blobs are a memory risk
  during export.
- Gzip on Apple platforms buffers the whole compressed member in
  memory (Linux streams via CZlib).
- iOS has no foreground-service / wake-lock equivalent: the device
  transaction continues independently; the app only polls while it is
  active. Keep the app open during apply, or check status afterwards.
- iOS has no per-route network-interface selection (Android chose the
  route by longest prefix and skipped VPNs); iOS routes LAN traffic to
  Wi-Fi automatically.
- Swift `String` cannot hold surrogate-escape filenames; invalid bytes
  become U+FFFD (documented in `Py.decodeSurrogateEscape`).
- Save dialogs use `fileExporter` (pick destination, then generate) —
  same order as Android. If the save dialog shortens the file name, the
  full name and extension are restored after export.
- The iOS app was not tested against a real phone or router yet, same
  as the Android 1.1.2 release notes.

## Licences

- App code: MIT (`LICENSE`).
- `Core/Ext4.swift` (port of `Ext4.java`): AGPL-3.0-or-later
  (`LICENSES/AGPL-3.0.txt`).
- Third-party notices: `THIRD_PARTY_NOTICES.md` (JSch, JZlib, jBCrypt
  licences in `LICENSES/`; NIOSSH is Apache-2.0, see its repository).

## Verification status (this Linux VM has no Xcode/macOS)

Verified here:

- `swiftc -typecheck` on all `DiffStudio/Core/*.swift` with Swift 6.0.3
  (Linux): passes with zero errors/warnings.
- `DiffStudio/SSH/Remote.swift` compiled against real NIOSSH 0.12.0
  in a scratch Swift package (`swift package resolve` + `swift build`
  on Linux, Swift 6.0.3): passes, with two benign warnings — NIOSSH's
  own `NIOSSHHandler` is marked Sendable-unavailable and NIO's
  `addHandler` is `@preconcurrency`; the project builds the app target
  in Swift 5 mode, where these stay warnings. This is the exact usage
  pattern from NIOSSH's own README.
- All 7 XCTest tests pass on Linux in the same scratch package
  (`swift test`): the two ported Java tests, the `.owrt-index.json`
  round-trip, tamper rejection, and all 28 asset SHA-256 checks. This
  run also exercises the pure-Swift SHA-256 path used when CryptoKit
  is unavailable.
- All 28 files under `Assets/` are byte-identical to the Android
  v1.1.2 assets (`diff -r` clean; SHA-256 recorded in
  `DiffStudioTests/IndexAndAssetsTests.swift`).
- `project.pbxproj`: all 98 objects resolve, every referenced file
  exists, NIOSSH pinned `0.12.0..<0.13.0`, `CODE_SIGNING_ALLOWED=NO`
  in the app and test targets.
- `../.github/workflows/build-ipa.yml`: YAML parses; the archive / package / verify steps
  mirror the commands above.
- `Localizable.strings`: 100 keys in both `en` and `zh-Hans`, every
  `tr("…")` key used in code is present in both files.

Not verified here (needs a Mac or the Actions run):

- The full Xcode build for iOS device (SwiftUI views, `Info.plist`
  document types, asset catalog) — `swiftc -parse` was used for the UI
  files on Linux, which checks syntax only.
- The XCTest run and the unsigned `.ipa` itself — produced by the
  GitHub Actions workflow on first run.
- A real device test (patch generation against real release ZIPs, SSH
  apply to a real router).

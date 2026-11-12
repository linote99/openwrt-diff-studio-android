// DiffStudioApp.swift
// App entry point. The app opens .ota / .zip / .json files handed to
// it by the Files app (CFBundleDocumentTypes in Info.plist).

import SwiftUI

@main
public struct DiffStudioApp: App {
    @StateObject private var state = AppState()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(state.colorScheme)
                .onOpenURL { url in
                    state.handleOpenURL(url)
                }
        }
    }
}

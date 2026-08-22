//
//  mothxOSApp.swift
//  mothxOS
//
//  Created by YangDongFeng on 2026/8/17.
//

import SwiftUI

@main
struct mothxOSApp: App {
    @StateObject private var mothx = MothxServiceManager()
    @StateObject private var language = LanguageStore()
    // WindowGroup may recreate ContentView after the last window is closed.
    // Keep this at the App lifetime so reactivating the app does not repeat
    // launch-only environment checks or restart the existing mothx service.
    @State private var showEnvironmentCheck = true

    var body: some Scene {
        WindowGroup {
            ContentView(showEnvironmentCheck: $showEnvironmentCheck)
                .environmentObject(mothx)
                .environmentObject(language)
                .task {
                    mothx.languageStore = language
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Reconnect to mothx") {
                    Task { await mothx.connect() }
                }
            }
        }
    }
}

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

    var body: some Scene {
        WindowGroup {
            ContentView()
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

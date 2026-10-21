import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct SpaceApp: App {
    @State private var vault = VaultStore()

    init() {
        #if os(macOS)
        // Space has its own tabs inside the window; the system window tabs would only duplicate them.
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(vault)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await vault.restore() }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        // No system title bar / toolbar: on macOS 26 it floats over the content and takes the clicks
        // meant for the tabs. Our own controls live in the sidebar's top row, like in Obsidian.
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}

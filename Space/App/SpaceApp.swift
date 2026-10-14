import SwiftUI

@main
struct SpaceApp: App {
    @State private var vault = VaultStore()

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
        .windowToolbarStyle(.unified)
        #endif
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(VaultStore.self) private var vault

    var body: some View {
        Group {
            if vault.rootURL == nil {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .alert("Space", isPresented: Binding(
            get: { vault.errorMessage != nil },
            set: { if !$0 { vault.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vault.errorMessage ?? "")
        }
    }
}

/// Sidebar with universes and notes, detail with the map or a note.
struct MainView: View {
    @Environment(VaultStore.self) private var vault
    @State private var map = MapModel()
    @State private var workspace = Workspace()
    @State private var pickingAccess = false
    @AppStorage("space.sidebarCompact") private var compactSidebar = false
    /// Height of the window's title strip (0 when the window is zoomed to full screen and has none).
    @State private var titleStrip: CGFloat = 28

    var body: some View {
        #if os(macOS)
        // A floating glass panel instead of the system sidebar column: it can fold into a narrow rail
        // of icons and back, smoothly, which the system column can't do.
        HStack(spacing: 8) {
            SidebarView()
                .frame(width: compactSidebar ? 78 : 270)
                // A floating panel of Liquid Glass from the top of the window, as in Finder on macOS 26:
                // the window's buttons sit inside it (placed by WindowButtons below).
                .background(GlassPanel(tint: Theme.sidebar.opacity(0.45)))
                .padding(.top, Self.sidebarTop)
                .padding(.bottom, 8)
                .ignoresSafeArea(.container, edges: .top)
                .zIndex(1)                       // always above the map/note next to it
            detail
            .padding(.bottom, 8)
            // Without a title strip (a zoomed window) keep the same room above the panes for the vault's name.
            .padding(.top, titleStrip < 10 ? 30 : 0)
            .clipped()                           // the map and notes stay inside their own area
        }
        .padding(.horizontal, 8)
        .background(WindowButtons(sidebarWidth: compactSidebar ? 78 : 270, compact: compactSidebar))
        // The strip above the tabs shows the vault's name, centred over the panes.
        .overlay(alignment: .top) {
            VaultTitle(name: vault.vaultName, fallback: 30)
                .padding(.leading, (compactSidebar ? 78 : 270) + 16)
        }
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { titleStrip = g.safeAreaInsets.top }
                    .onChange(of: g.safeAreaInsets.top) { _, top in titleStrip = top }
            }
        }
        .animation(.smooth(duration: 0.35), value: compactSidebar)
        .background {
            ZStack {
                DesktopBlur()
                SpaceBackground()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .overlay { DragGhost() }                 // over the sidebar and the panes alike
        .overlay { TipLayer().ignoresSafeArea() }  // hover hints for the buttons
        .modifier(MainChrome(vault: vault, map: map, workspace: workspace, pickingAccess: $pickingAccess))
        #else
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
        }
        .modifier(MainChrome(vault: vault, map: map, workspace: workspace, pickingAccess: $pickingAccess))
        #endif
    }

    private var detail: some View {
            // Panes and tabs: drag a tab to any side of a pane to split it, like in Obsidian.
            WorkspaceView()
            .overlay(alignment: .top) {
                if vault.needsWriteAccess {
                    WriteAccessBanner { pickingAccess = true }
                        .padding(.top, 70)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: vault.needsWriteAccess)
            .overlay {
                if vault.isLoading {
                    ProgressView("Читаю хранилище…")
                        .padding(24)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
    }
}

/// Things shared by both layouts: the map model and the write-access folder picker.
private struct MainChrome: ViewModifier {
    let vault: VaultStore
    let map: MapModel
    let workspace: Workspace
    @Binding var pickingAccess: Bool

    func body(content: Content) -> some View {
        content
        .environment(map)
        .environment(workspace)
        // Whatever gets picked (sidebar, map, links) opens in the focused pane. Deferred one turn so a click
        // that also focuses a pane is applied first.
        .onChange(of: vault.selection) { _, new in
            Task { @MainActor in workspace.show(new) }
        }
        .onChange(of: vault.generation) { _, _ in
            // Renamed or moved in another app: open tabs follow the file.
            for (old, new) in vault.lastMoves { workspace.retarget(old: old, new: new) }
            workspace.prune { vault.cosmos.notes[$0] != nil }
        }
        // The system folder picker is the only way a sandboxed app gets write access to a folder.
        .fileImporter(isPresented: $pickingAccess, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await vault.grantAccess(with: url) } }
        }
        .fileDialogDefaultDirectory(vault.rootURL?.deletingLastPathComponent())
        #if os(macOS)
        .fileDialogMessage(Text("Выбери папку хранилища «\(vault.vaultName)», чтобы Space мог создавать и сохранять заметки."))
        .fileDialogConfirmationLabel(Text("Дать доступ"))
        #endif
    }
}

/// Shown when the vault is read-only for the app.
private struct WriteAccessBanner: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Хранилище открыто только для чтения").font(.callout.weight(.semibold))
                Text("Разреши запись, чтобы создавать вселенные, созвездия и звёзды и сохранять правки.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Button("Дать доступ", action: action)
                .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
    }
}

#if os(macOS)
extension MainView {
    /// Gap between the window's top edge and the sidebar panel.
    static let sidebarTop: CGFloat = 6
}

/// Puts the window's red / yellow / green buttons inside the sidebar panel: centred in the narrow rail,
/// with a margin in the wide one. AppKit lays them out again now and then, so they are put back each time.
private struct WindowButtons: NSViewRepresentable {
    let sidebarWidth: CGFloat
    let compact: Bool

    func makeNSView(context: Context) -> NSView {
        let v = Placer()
        v.sidebarWidth = sidebarWidth
        v.compact = compact
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let p = v as? Placer else { return }
        p.sidebarWidth = sidebarWidth
        p.compact = compact
        p.place()
        // The sidebar folds with an animation; put the buttons where it ends up, and again once it settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { p.place() }
    }

    final class Placer: NSView {
        var sidebarWidth: CGFloat = 270
        var compact = false
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                    DispatchQueue.main.async { self?.place() }
                })
            }
            DispatchQueue.main.async { self.place() }
        }

        func place() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let buttons = kinds.compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, let size = buttons.first?.frame.size else { return }
            let gap: CGFloat = 8
            let group = size.width * 3 + gap * 2
            let panelX: CGFloat = 8                                      // the sidebar's left margin
            let startX = compact ? panelX + (sidebarWidth - group) / 2 : panelX + 16
            // Centre line 20 points below the window's top edge (14 below the panel's top).
            let centerFromTop: CGFloat = MainView.sidebarTop + 14
            let height = window.frame.height
            for (i, b) in buttons.enumerated() {
                guard let sv = b.superview else { continue }
                let inWindow = NSRect(x: startX + CGFloat(i) * (size.width + gap),
                                      y: height - centerFromTop - size.height / 2,
                                      width: size.width, height: size.height)
                let frame = sv.convert(inWindow, from: nil)
                if b.frame != frame { b.frame = frame }
            }
        }
    }
}

/// The vault's name in the window's title bar strip, like the document title in Obsidian.
private struct VaultTitle: View {
    let name: String
    var fallback: CGFloat = 28

    var body: some View {
        GeometryReader { g in
            let strip = g.safeAreaInsets.top
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .frame(width: g.size.width, height: strip > 10 ? strip : fallback)
        }
        .ignoresSafeArea(.container, edges: .top)   // reach up into the strip; the proxy still reports its height
        .allowsHitTesting(false)
    }
}
#endif

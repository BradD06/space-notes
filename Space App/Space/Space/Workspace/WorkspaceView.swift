import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The whole work area: panes split in any direction, each with its own tabs.
///
/// Tabs are dragged with our own drag (not the system drag and drop): the app follows the pointer,
/// draws a ghost of the tab, highlights where it will land, and rearranges the panes on release.
struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        NodeView(node: workspace.root)
            .onPreferenceChange(PaneFrames.self) { workspace.paneFrames = $0 }
            .onPreferenceChange(BarFrames.self) { workspace.barFrames = $0 }
            .onPreferenceChange(ChipFrames.self) { workspace.chipFrames = $0 }
    }
}

/// The ghost of whatever is being dragged (a tab, a note, a folder), following the pointer over the whole window.
struct DragGhost: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        GeometryReader { g in
            if let d = workspace.drag {
                let origin = g.frame(in: .global).origin
                Label(d.folder.map { "→ " + (($0 as NSString).lastPathComponent.isEmpty ? "Входящие" : ($0 as NSString).lastPathComponent) + " · " + d.title } ?? d.title,
                      systemImage: d.icon)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .glassEffect(.regular.tint(Theme.accent.opacity(0.18)), in: .capsule)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .fixedSize()
                    .position(x: d.location.x - origin.x + 20, y: d.location.y - origin.y + 14)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A pane, or a split of child nodes with draggable dividers between them.
private struct NodeView: View {
    let node: PaneNode

    var body: some View {
        if node.isPane {
            PaneView(pane: node)
        } else {
            SplitView(node: node)
        }
    }
}

private struct SplitView: View {
    let node: PaneNode
    @Environment(Workspace.self) private var workspace
    private let handle: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            let horizontal = node.axis == .horizontal
            let total = (horizontal ? g.size.width : g.size.height) - handle * CGFloat(max(node.children.count - 1, 0))
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { i, child in
                    let share = node.fractions.indices.contains(i) ? node.fractions[i] : 1 / CGFloat(node.children.count)
                    NodeView(node: child)
                        .frame(width: horizontal ? max(0, total * share) : nil, height: horizontal ? nil : max(0, total * share))
                    if i < node.children.count - 1 {
                        ResizeHandle(horizontal: horizontal) { delta in
                            workspace.resize(node, at: i, by: delta / max(total, 1))
                        } onEnd: {
                            workspace.endResize()
                        }
                        .frame(width: horizontal ? handle : nil, height: horizontal ? nil : handle)
                    }
                }
            }
        }
    }

    /// A thin line you can grab to resize the neighbours.
    private struct ResizeHandle: View {
        let horizontal: Bool
        let onDrag: (CGFloat) -> Void
        let onEnd: () -> Void
        @State private var last: CGFloat = 0
        @State private var hover = false

        var body: some View {
            ZStack {
                Color.clear
                Capsule().fill(Theme.accent.opacity(hover ? 0.6 : 0))
                    .frame(width: horizontal ? 3 : 40, height: horizontal ? 40 : 3)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                #if os(macOS)
                if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                #endif
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let now = horizontal ? v.translation.width : v.translation.height
                    onDrag(now - last)
                    last = now
                }
                .onEnded { _ in last = 0; onEnd() })
        }
    }
}

// MARK: - Pane

private struct PaneView: View {
    let pane: PaneNode
    @Environment(Workspace.self) private var workspace
    @Environment(VaultStore.self) private var vault

    var body: some View {
        let focused = workspace.focusedID == pane.id
        VStack(spacing: 0) {
            TabBar(pane: pane, focused: focused)
                .zIndex(1)          // always above the pane's content, which may paint beyond its own top
            GeometryReader { g in
                ZStack {
                    content
                    if let t = workspace.drag?.target, t.pane == pane.id, t.index == nil {
                        DropHighlight(zone: t.zone, size: g.size)
                    }
                }
                // Clicking inside a pane's content makes it the one where the sidebar opens things.
                .simultaneousGesture(TapGesture().onEnded {
                    guard workspace.focusedID != pane.id else { return }
                    workspace.focus(pane)
                    if let tab = pane.activeTab, vault.selection != tab.selection { vault.selection = tab.selection }
                })
                // A note or map wider than a narrow pane must not spill over its neighbours (and their tabs).
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
                .contentShape(Rectangle())
                .preference(key: PaneFrames.self, value: [pane.id: g.frame(in: .global)])
            }
        }
        .background(GlassPanel(tint: Theme.ground.opacity(focused ? 0.5 : 0.62)))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay {
            // The focused pane gets a faint accent rim.
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(focused && workspace.paneCount > 1 ? 0.28 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .environment(\.paneID, pane.id)
    }

    @ViewBuilder
    private var content: some View {
        switch pane.activeTab {
        case .note(let id):
            if Books.isBook(id) {
                BookView(bookID: id).id(id)
            } else if Documents.isDocument(id) {
                DocumentView(docID: id).id(id)
            } else {
                NoteView(noteID: id).id(id)
            }
        case .map:
            CosmosMapView()
        case .dashboard:
            DashboardView()
        case .widget(let token):
            if let ref = WidgetRef(token: token) {
                WidgetPane(ref: ref).id(token)
            } else {
                ContentUnavailableView("Виджет не найден", systemImage: "square.dashed")
            }
        case nil:
            ContentUnavailableView("Нет открытых вкладок", systemImage: "rectangle.dashed")
        }
    }
}

/// Shows where the dragged tab will go: a half of the pane, or the whole pane for "into this pane".
private struct DropHighlight: View {
    let zone: DropZone
    let size: CGSize

    var body: some View {
        let r: CGRect = switch zone {
        case .left: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case .center: CGRect(origin: .zero, size: size)
        }
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.accent.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5))
            .frame(width: max(0, r.width - 8), height: max(0, r.height - 8))
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
            .animation(.smooth(duration: 0.15), value: zone)
    }
}

// MARK: - Tabs

private struct TabBar: View {
    let pane: PaneNode
    let focused: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(VaultStore.self) private var vault

    var body: some View {
        // Where a dragged tab would be inserted in this bar (nil when the drag isn't over it).
        let before: Int? = workspace.drag?.target.flatMap { $0.pane == pane.id ? $0.index : nil }
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.offset) { i, tab in
                        TabChip(title: title(tab), icon: icon(tab), color: color(tab),
                                active: i == pane.active, focused: focused) {
                            workspace.activate(pane, i)
                            vault.selection = tab.selection
                        } onClose: {
                            workspace.close(pane, i)
                            if let t = pane.activeTab, workspace.focusedID == pane.id { vault.selection = t.selection }
                        }
                        // Drag the tab anywhere: onto another tab bar, into a pane, or onto a pane's side.
                        .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                            .onChanged { v in
                                if workspace.drag == nil {
                                    workspace.beginDrag(Workspace.payload(pane: pane, index: i), title: title(tab), icon: icon(tab), at: v.location)
                                } else {
                                    workspace.moveDrag(to: v.location)
                                }
                            }
                            .onEnded { _ in workspace.endDrag() })
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ChipFrames.self, value: [pane.id: [i: g.frame(in: .global)]])
                        })
                        .overlay(alignment: .leading) {
                            if before == i { Capsule().fill(Theme.accent).frame(width: 3, height: 22).offset(x: -3) }
                        }
                        .overlay(alignment: .trailing) {
                            if before == pane.tabs.count && i == pane.tabs.count - 1 {
                                Capsule().fill(Theme.accent).frame(width: 3, height: 22).offset(x: 3)
                            }
                        }
                        .contextMenu {
                            Button("Закрыть", systemImage: "xmark") { workspace.close(pane, i) }
                            Button("Открыть справа", systemImage: "rectangle.split.2x1") { workspace.openToTheSide(tab) }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollEdgeEffectHidden(true, for: .all)
            Button { workspace.addTab(to: pane) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .tip("Новая вкладка")
            .padding(.trailing, 6)
        }
        .padding(.top, 4)
        .frame(height: 40)
        // The empty part of the bar is the window's title bar: drag it to move the window, double-click to zoom.
        .background {
            (before != nil ? Theme.accent.opacity(0.10) : Color.white.opacity(0.001))
                .modifier(TitleBarArea())
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1).padding(.horizontal, 12) }
        .background(GeometryReader { g in Color.clear.preference(key: BarFrames.self, value: [pane.id: g.frame(in: .global)]) })
    }

    private func title(_ tab: WorkTab) -> String {
        switch tab {
        case .map: "Карта космоса"
        case .dashboard: "Дашборд"
        case .note(let id): vault.cosmos.title(id)
        case .widget(let t): WidgetRef(token: t).map { r in WidgetIndex.shared.entry(r, vault)?.name ?? vault.cosmos.title(r.note) } ?? "Виджет"
        }
    }

    private func icon(_ tab: WorkTab) -> String {
        switch tab {
        case .map: "sparkles"
        case .dashboard: "rectangle.3.group"
        case .note(let id): Documents.icon(for: id)
        case .widget: "square.grid.2x2"
        }
    }

    private func color(_ tab: WorkTab) -> Color {
        switch tab {
        case .map, .dashboard, .widget: Theme.accent
        case .note(let id): Theme.color(forUniverse: vault.cosmos.universeOf[id])
        }
    }
}

private struct TabChip: View {
    let title: String
    let icon: String
    let color: Color
    let active: Bool
    let focused: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 2) {
            // Not a Button: a button swallows the mouse-down, and then the tab can't be dragged.
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(active ? color : Theme.muted)
                Text(title).font(.system(size: 12.5)).lineLimit(1)
                    .foregroundStyle(active ? Theme.ink : Theme.ink.opacity(0.7))
            }
            .padding(.leading, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(hover ? 0.08 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .tip("Закрыть вкладку")
            .opacity(active || hover ? 1 : 0)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: 220)
        .background {
            if active {
                Color.clear
                    .glassEffect(.regular.tint((focused ? color : Theme.accent).opacity(focused ? 0.14 : 0.05)), in: .capsule)
                    .allowsHitTesting(false)
            } else {
                Capsule().fill(Color.white.opacity(hover ? 0.05 : 0))
            }
        }
        .contentShape(Capsule())
        .onHover { hover = $0 }
    }
}


// MARK: - Frames for the drag (in window coordinates)

private struct PaneFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct BarFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

private struct ChipFrames: PreferenceKey {
    static let defaultValue: [UUID: [Int: CGRect]] = [:]
    static func reduce(value: inout [UUID: [Int: CGRect]], nextValue: () -> [UUID: [Int: CGRect]]) {
        value.merge(nextValue()) { a, b in a.merging(b) { $1 } }
    }
}

/// Lets the empty part of a bar act as the window's title bar on the Mac.
private struct TitleBarArea: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
        #else
        content
        #endif
    }
}

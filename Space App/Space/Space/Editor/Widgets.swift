import SwiftUI
import Observation

/// A ```dataview / ```dataviewjs block taken out of its note: shown in a pane of its own (dragged anywhere like a
/// tab) or pinned to the dashboard. Referred to as "note path#k", the k-th such block of that note.
nonisolated struct WidgetRef: Hashable, Sendable {
    var note: String
    var index: Int

    var token: String { "\(note)#\(index)" }

    init(note: String, index: Int) {
        self.note = note
        self.index = index
    }

    init?(token: String) {
        guard let hash = token.lastIndex(of: "#"), let k = Int(token[token.index(after: hash)...]) else { return nil }
        note = String(token[..<hash])
        index = k
    }
}

nonisolated enum WidgetCatalog {
    /// The note's ```dataview and ```dataviewjs blocks, each with its fences, in order.
    static func blocks(in text: String) -> [String] {
        var out: [String] = []
        var current: [String]?
        var marker = ""
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if current == nil {
                let lower = (t.split(separator: " ").first.map(String.init) ?? "").lowercased()
                for m in ["```", "~~~"] where lower == m + Dataview.language || lower == m + DataviewJS.language {
                    current = [line]
                    marker = m
                }
            } else {
                current!.append(line)
                if t == marker {
                    out.append(current!.joined(separator: "\n"))
                    current = nil
                }
            }
        }
        return out
    }

    /// A widget's name: the script it loads (`dv.view("Виджеты/код/погода")` → "Погода"), else the note's title.
    static func name(of block: String, note: String) -> String {
        let title = ((note as NSString).lastPathComponent as NSString).deletingPathExtension
        if let r = block.range(of: #"dv\.view\(\s*["'`]([^"'`]+)["'`]"#, options: .regularExpression) {
            let inner = block[r].replacingOccurrences(of: #"^dv\.view\(\s*["'`]"#, with: "", options: .regularExpression).dropLast()
            let last = String(inner).split(separator: "/").last.map(String.init) ?? String(inner)
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        if DataviewJS.isJS(block) {
            // "// ── Focus timer (помодоро) ──" as the first comment
            if let first = block.components(separatedBy: "\n").dropFirst().first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }) {
                let c = first.replacingOccurrences(of: #"^\s*//[\s─—-]*|[\s─—-]*$"#, with: "", options: .regularExpression)
                if !c.isEmpty, c.count < 40 { return c.components(separatedBy: ":").first ?? c }
            }
        }
        return title
    }

    static func icon(of block: String) -> String {
        DataviewJS.isJS(block) ? "square.grid.2x2" : "tablecells"
    }
}

/// Every widget in the vault, for the dashboard's "add widget" menu. Read again when notes change.
@MainActor
final class WidgetIndex {
    static let shared = WidgetIndex()
    struct Entry: Identifiable {
        let ref: WidgetRef
        let name: String
        let icon: String
        var id: String { ref.token }
    }
    private var cached: (stamp: Int, entries: [Entry])?

    func all(_ vault: VaultStore) -> [Entry] {
        let stamp = DataviewIndexCache.shared.peekStamp(vault)
        if let c = cached, c.stamp == stamp { return c.entries }
        var out: [Entry] = []
        for id in vault.cosmos.notes.keys.sorted() where id.lowercased().hasSuffix(".md") {
            let text = vault.text(of: id)
            guard text.contains("dataview") else { continue }
            for (k, b) in WidgetCatalog.blocks(in: text).enumerated() {
                out.append(Entry(ref: WidgetRef(note: id, index: k), name: WidgetCatalog.name(of: b, note: id), icon: WidgetCatalog.icon(of: b)))
            }
        }
        cached = (stamp, out)
        return out
    }

    func entry(_ ref: WidgetRef, _ vault: VaultStore) -> Entry? { all(vault).first { $0.ref == ref } }
}

/// Where widgets are pinned, per vault: the dashboard (each with its own place and size there) and the sidebar.
@MainActor
@Observable
final class PinnedWidgets {
    static let shared = PinnedWidgets()

    enum Place: String { case dashboard, sidebar }

    /// Dashboard widgets, drawn in this order (the last one on top).
    private(set) var tokens: [String] = []
    private(set) var sidebar: [String] = []
    /// Where each dashboard widget sits on the board and how big it is.
    private(set) var frames: [String: CGRect] = [:]
    @ObservationIgnored private var vaultKey = ""

    private var storeKey: String { "space.widgets." + vaultKey }

    private struct Stored: Codable {
        var dashboard: [String] = []
        var sidebar: [String] = []
        var frames: [String: [Double]] = [:]
    }

    func use(_ vault: VaultStore) {
        let key = vault.rootURL?.path ?? ""
        guard key != vaultKey else { return }
        vaultKey = key
        if let data = UserDefaults.standard.data(forKey: storeKey), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            tokens = s.dashboard
            sidebar = s.sidebar
            frames = s.frames.compactMapValues { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        } else {
            // the first version kept only the dashboard's list
            tokens = UserDefaults.standard.stringArray(forKey: "space.dashboardWidgets." + key) ?? []
            sidebar = []
            frames = [:]
        }
    }

    func isPinned(_ ref: WidgetRef, _ place: Place = .dashboard) -> Bool {
        (place == .dashboard ? tokens : sidebar).contains(ref.token)
    }

    func toggle(_ ref: WidgetRef, _ place: Place = .dashboard) {
        switch place {
        case .dashboard:
            if let i = tokens.firstIndex(of: ref.token) { tokens.remove(at: i); frames[ref.token] = nil } else { tokens.append(ref.token) }
        case .sidebar:
            if let i = sidebar.firstIndex(of: ref.token) { sidebar.remove(at: i) } else { sidebar.append(ref.token) }
        }
        save()
    }

    func remove(_ token: String, from place: Place = .dashboard) {
        if place == .dashboard { tokens.removeAll { $0 == token }; frames[token] = nil } else { sidebar.removeAll { $0 == token } }
        save()
    }

    /// Sidebar order: puts `token` where `before` is (or at the end).
    func moveInSidebar(_ token: String, before: String?) {
        guard token != before, let from = sidebar.firstIndex(of: token) else { return }
        sidebar.remove(at: from)
        sidebar.insert(token, at: before.flatMap { sidebar.firstIndex(of: $0) } ?? sidebar.count)
        save()
    }

    func setFrame(_ token: String, _ frame: CGRect) {
        frames[token] = frame
        save()
    }

    /// The widget last touched is drawn on top.
    func bringToFront(_ token: String) {
        guard let i = tokens.firstIndex(of: token), i != tokens.count - 1 else { return }
        tokens.remove(at: i)
        tokens.append(token)
        save()
    }

    private func save() {
        let s = Stored(dashboard: tokens, sidebar: sidebar,
                       frames: frames.mapValues { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] })
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: storeKey) }
    }
}

// MARK: - A widget on its own

/// One widget outside its note, at the given width: reads its block from the note, runs it like in the note.
struct WidgetBlockView: View {
    let ref: WidgetRef
    var width: CGFloat
    @Environment(VaultStore.self) private var vault
    @State private var model = DataviewModel()

    var body: some View {
        let block = currentBlock
        Group {
            if let block {
                DataviewView(model: model)
                    .onAppear { configure(block) }
                    .onChange(of: block) { _, b in configure(b) }
                    .onChange(of: width) { _, w in model.width = w }
            } else {
                Label("Виджет не найден: блок убрали из заметки «\(title)»", systemImage: "questionmark.square.dashed")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }

    private var title: String { ((ref.note as NSString).lastPathComponent as NSString).deletingPathExtension }

    private var currentBlock: String? {
        _ = vault.cosmos.notes[ref.note]?.modified           // read again after the note is saved
        let blocks = WidgetCatalog.blocks(in: vault.text(of: ref.note))
        return blocks.indices.contains(ref.index) ? blocks[ref.index] : nil
    }

    private func configure(_ block: String) {
        if model.query != block { model.query = block }
        model.noteID = ref.note
        model.width = width
        model.widgetRef = ref
        let vault = vault
        model.onOpen = { link in
            let t = link.lowercased()
            if let id = vault.cosmos.notes.values.first(where: { $0.title.lowercased() == t })?.id { vault.selection = .note(id) }
        }
        model.onToggle = { vault.toggle($0) }
        model.onEdit = { [ref] in vault.selection = .note(ref.note) }
    }
}

/// A widget in a pane of its own (a tab like any note: dragged to a side, into another pane, closed).
struct WidgetPane: View {
    let ref: WidgetRef

    var body: some View {
        GeometryReader { g in
            ScrollView {
                WidgetBlockView(ref: ref, width: max(200, g.size.width - 40))
                    .padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
    }
}

// MARK: - The dashboard's widgets

/// The dashboard's board: pinned widgets placed freely, each where you drag it and as big as you make it.
/// Drag a widget by its header to move it (out of the board, into a pane, to open it there); drag the corner
/// to resize. Places snap to a 10-point grid. Widgets are added from every widget in the vault.
struct DashboardWidgets: View {
    @Environment(VaultStore.self) private var vault
    @Environment(Workspace.self) private var workspace
    private let pinned = PinnedWidgets.shared
    @State private var boardWidth: CGFloat = 800
    @State private var boardFrame: CGRect = .zero
    /// The widget being moved or resized and its frame while the finger is down.
    @State private var live: (token: String, frame: CGRect)?
    @AppStorage("space.dashboardBoardHeight") private var viewportHeight: Double = 520
    @State private var resizeStart: Double?

    static let grid: CGFloat = 10
    static let minSize = CGSize(width: 220, height: 140)

    var body: some View {
        let _ = pinned.use(vault)
        let refs = pinned.tokens.compactMap(WidgetRef.init(token:))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ВИДЖЕТЫ").font(Theme.mono(10)).kerning(1.4).foregroundStyle(Theme.muted)
                if !refs.isEmpty {
                    Text("перетаскивай за заголовок, размер — за угол").font(.caption).foregroundStyle(Theme.faint)
                }
                Spacer()
                AddWidgetMenu(place: .dashboard)
            }
            .padding(.horizontal, 6)
            if refs.isEmpty {
                Text("Закрепи сюда виджеты из заметок: «+» справа или меню «•••» виджета в заметке.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6)
            } else {
                let frames = layout(refs)
                let height = (frames.values.map(\.maxY).max() ?? 0) + 20
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: boardWidth, height: max(height, 160))
                        ForEach(refs, id: \.self) { ref in
                            let f = live?.token == ref.token ? live!.frame : frames[ref.token]!
                            card(ref, frame: f, placed: frames[ref.token]!)
                                .frame(width: f.width, height: f.height)
                                .offset(x: f.minX, y: f.minY)
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { boardFrame = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, f in boardFrame = f }
                    })
                }
                .frame(height: min(max(height, 160), viewportHeight))
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { boardWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in boardWidth = w }
                })
                viewportHandle
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Drag the line under the board to give the widgets more or less of the dashboard.
    private var viewportHandle: some View {
        Capsule().fill(Color.white.opacity(0.12)).frame(width: 46, height: 4)
            .frame(maxWidth: .infinity).frame(height: 10)
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { v in
                    if resizeStart == nil { resizeStart = viewportHeight }
                    viewportHeight = min(1600, max(180, resizeStart! + v.translation.height))
                }
                .onEnded { _ in resizeStart = nil })
            .help("Потяни, чтобы сделать область виджетов выше или ниже")
    }

    /// Every pinned widget's frame: its saved one (kept inside the board's width), or a free place for a new one.
    private func layout(_ refs: [WidgetRef]) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        let width = max(boardWidth, Self.minSize.width)
        for ref in refs {
            if var f = pinned.frames[ref.token] {
                f.size.width = min(max(f.width, Self.minSize.width), width)
                f.origin.x = min(max(0, f.minX), width - f.width)
                f.origin.y = max(0, f.minY)
                out[ref.token] = f
            }
        }
        // New widgets go to the first place where they don't cover another, row by row.
        let w = min(460, width), h: CGFloat = 360
        for ref in refs where out[ref.token] == nil {
            var y: CGFloat = 0
            search: while true {
                var x: CGFloat = 0
                while x + w <= width + 0.5 {
                    let r = CGRect(x: x, y: y, width: w, height: h)
                    if !out.values.contains(where: { $0.insetBy(dx: 1, dy: 1).intersects(r) }) { out[ref.token] = r; break search }
                    x += Self.grid * 2
                }
                y += Self.grid * 2
            }
        }
        return out
    }

    private func snap(_ v: CGFloat) -> CGFloat { (v / Self.grid).rounded() * Self.grid }

    private func card(_ ref: WidgetRef, frame f: CGRect, placed: CGRect) -> some View {
        let entry = WidgetIndex.shared.entry(ref, vault)
        let name = entry?.name ?? ((ref.note as NSString).lastPathComponent as NSString).deletingPathExtension
        let icon = entry?.icon ?? "square.grid.2x2"
        let moving = live?.token == ref.token
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").foregroundStyle(Theme.faint)
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                Button { vault.selection = .widget(ref.token) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Открыть в отдельной панели")
                Button { pinned.remove(ref.token) } label: { Image(systemName: "pin.slash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Убрать с дашборда")
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
            .help("Перетащи, чтобы переставить; за пределы дашборда — в любую панель")
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { v in
                    pinned.bringToFront(ref.token)
                    if boardFrame.insetBy(dx: -30, dy: -30).contains(v.location) {
                        if workspace.drag != nil { workspace.cancelDrag() }
                        var n = placed
                        n.origin.x = min(max(0, snap(placed.minX + v.translation.width)), max(0, boardWidth - placed.width))
                        n.origin.y = max(0, snap(placed.minY + v.translation.height))
                        live = (ref.token, n)
                    } else {
                        // Left the board: it's dragged like a tab, to open in a pane or at a pane's side.
                        live = nil
                        if workspace.drag == nil {
                            workspace.beginDrag(WorkTab.widget(ref.token).token, title: name, icon: icon, at: v.location)
                        } else {
                            workspace.moveDrag(to: v.location)
                        }
                    }
                }
                .onEnded { _ in
                    if let l = live, l.token == ref.token { pinned.setFrame(ref.token, l.frame) }
                    if workspace.drag != nil { workspace.endDrag() }
                    live = nil
                })
            WidgetBlockScroll(ref: ref, width: f.width - 24)
        }
        .padding(12)
        .frame(width: f.width, height: f.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface.opacity(moving ? 0.98 : 0.9)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(moving ? Theme.accent.opacity(0.7) : Color.white.opacity(0.08), lineWidth: moving ? 1.5 : 1))
        .shadow(color: .black.opacity(moving ? 0.35 : 0.12), radius: moving ? 14 : 4, y: moving ? 6 : 2)
        .overlay(alignment: .bottomTrailing) { resizeHandle(ref, placed: placed) }
    }

    private func resizeHandle(_ ref: WidgetRef, placed: CGRect) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.muted)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    pinned.bringToFront(ref.token)
                    var n = placed
                    n.size.width = min(max(Self.minSize.width, snap(placed.width + v.translation.width)), boardWidth - placed.minX)
                    n.size.height = max(Self.minSize.height, snap(placed.height + v.translation.height))
                    live = (ref.token, n)
                }
                .onEnded { _ in
                    if let l = live { pinned.setFrame(ref.token, l.frame) }
                    live = nil
                })
            .help("Потяни, чтобы изменить размер")
    }
}

/// A widget at a fixed size: what doesn't fit scrolls inside it.
struct WidgetBlockScroll: View {
    let ref: WidgetRef
    let width: CGFloat

    var body: some View {
        ScrollView { WidgetBlockView(ref: ref, width: max(120, width)) }
            .scrollIndicators(.automatic)
    }
}

// MARK: - The sidebar's widgets

/// Widgets pinned to the sidebar, under the folders: narrow cards, reordered by dragging one onto another.
struct SidebarWidgets: View {
    @Environment(VaultStore.self) private var vault
    private let pinned = PinnedWidgets.shared
    @AppStorage("space.sidebarWidgetsOpen") private var open = true
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var dropTarget: String?

    var body: some View {
        let _ = pinned.use(vault)
        let refs = pinned.sidebar.compactMap(WidgetRef.init(token:))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { withAnimation(.smooth(duration: 0.25)) { open.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                        Text("ВИДЖЕТЫ").font(Theme.mono(10)).kerning(1.4)
                    }
                    .foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                AddWidgetMenu(place: .sidebar, compact: true)
            }
            .padding(.horizontal, 12)
            if open {
                if refs.isEmpty {
                    Text("Закрепи виджет: «+» или меню «•••» виджета.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 12)
                }
                GeometryReader { g in
                    let w = g.size.width
                    VStack(spacing: 8) {
                        ForEach(refs, id: \.self) { ref in card(ref, width: w) }
                    }
                }
                .frame(height: CGFloat(refs.count) * (Self.cardHeight + 8))
                .padding(.horizontal, 8)
            }
        }
        .padding(.top, 12)
    }

    static let cardHeight: CGFloat = 300

    private func card(_ ref: WidgetRef, width: CGFloat) -> some View {
        let entry = WidgetIndex.shared.entry(ref, vault)
        let name = entry?.name ?? ((ref.note as NSString).lastPathComponent as NSString).deletingPathExtension
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: entry?.icon ?? "square.grid.2x2").foregroundStyle(Theme.accent)
                Text(name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button { vault.selection = .widget(ref.token) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Открыть в отдельной панели")
                Button { pinned.remove(ref.token, from: .sidebar) } label: { Image(systemName: "pin.slash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Убрать из боковой панели")
            }
            .font(.system(size: 11))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { v in dropTarget = cardFrames.first { $0.value.contains(v.location) && $0.key != ref.token }?.key }
                .onEnded { _ in
                    if let t = dropTarget { withAnimation(.smooth(duration: 0.25)) { pinned.moveInSidebar(ref.token, before: t) } }
                    dropTarget = nil
                })
            WidgetBlockScroll(ref: ref, width: width - 16)
        }
        .padding(8)
        .frame(width: width, height: Self.cardHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(dropTarget == ref.token ? Theme.accent.opacity(0.7) : Color.white.opacity(0.07)))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { cardFrames[ref.token] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in cardFrames[ref.token] = f }
        })
    }
}

/// "+": pins any widget of the vault to the dashboard or the sidebar.
struct AddWidgetMenu: View {
    let place: PinnedWidgets.Place
    var compact = false
    @Environment(VaultStore.self) private var vault
    private let pinned = PinnedWidgets.shared

    var body: some View {
        let all = WidgetIndex.shared.all(vault)
        let byNote = Dictionary(grouping: all, by: { $0.ref.note })
        Menu {
            if all.isEmpty { Text("В заметках нет блоков dataview / dataviewjs") }
            ForEach(byNote.keys.sorted(), id: \.self) { note in
                let title = ((note as NSString).lastPathComponent as NSString).deletingPathExtension
                Menu(title) {
                    ForEach(byNote[note] ?? []) { e in
                        Button { pinned.toggle(e.ref, place) } label: {
                            Label(pinned.isPinned(e.ref, place) ? "\(e.name)  ✓" : e.name, systemImage: e.icon)
                        }
                    }
                }
            }
        } label: {
            Group {
                if compact { Image(systemName: "plus") } else { Label("Добавить", systemImage: "plus") }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, compact ? 6 : 9).frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        #if os(macOS)
        .menuStyle(.button).menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain).fixedSize()
        .help(place == .dashboard ? "Закрепить на дашборде виджет из любой заметки" : "Закрепить в боковой панели виджет из любой заметки")
    }
}

/// The widget's own menu (in its note, in a pane): open it in a pane, pin it to the dashboard or the sidebar.
struct WidgetMenu: View {
    let ref: WidgetRef
    var standalone = false
    var onShowCode: (() -> Void)?
    /// In its note: placed freely (true) or in the line (false); nil elsewhere.
    var floating: Bool? = nil
    var onToggleFloat: (() -> Void)? = nil
    @Environment(VaultStore.self) private var vault
    private let pinned = PinnedWidgets.shared

    var body: some View {
        let _ = pinned.use(vault)
        Menu {
            if let floating, let onToggleFloat {
                Button(floating ? "Вернуть в строку текста" : "Свободное размещение (текст обтекает)",
                       systemImage: floating ? "text.alignleft" : "arrow.up.and.down.and.arrow.left.and.right") { onToggleFloat() }
                Divider()
            }
            if !standalone {
                Button("Открыть в отдельной панели", systemImage: "arrow.up.forward.square") { vault.selection = .widget(ref.token) }
            }
            Button(pinned.isPinned(ref) ? "Убрать с дашборда" : "Закрепить на дашборде",
                   systemImage: pinned.isPinned(ref) ? "pin.slash" : "pin") { pinned.toggle(ref) }
            Button(pinned.isPinned(ref, .sidebar) ? "Убрать из боковой панели" : "Закрепить в боковой панели",
                   systemImage: pinned.isPinned(ref, .sidebar) ? "sidebar.left" : "sidebar.leading") { pinned.toggle(ref, .sidebar) }
            if let onShowCode {
                Divider()
                Button(standalone ? "Открыть заметку с виджетом" : "Показать код", systemImage: "chevron.left.forwardslash.chevron.right") { onShowCode() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.muted)
                .frame(width: 24, height: 22)
                .background(Capsule().fill(Theme.surfaceHigh.opacity(0.9)))
                .contentShape(Capsule())
        }
        #if os(macOS)
        .menuStyle(.button).menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain).fixedSize()
        .help("Виджет: отдельная панель, дашборд, боковая панель")
    }
}

// MARK: - Floating in the note

/// A widget placed freely in its note, text flowing around it: kept in the block's opening line,
/// "```dataviewjs float x=520 y=0 w=320" (Obsidian reads only the first word, so the note stays compatible).
/// x, y: points from the top left of the text; w: the widget's width.
nonisolated struct WidgetFloat: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat

    static func parse(_ fenceLine: String) -> WidgetFloat? {
        let words = fenceLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.contains("float") else { return nil }
        func value(_ k: String) -> CGFloat? {
            words.first { $0.hasPrefix(k + "=") }.flatMap { Double($0.dropFirst(k.count + 1)) }.map { CGFloat($0) }
        }
        return WidgetFloat(x: value("x") ?? 0, y: value("y") ?? 0, w: value("w") ?? 320)
    }

    /// The opening line with this placement (or none): the fence and language stay, old placement words go.
    static func fenceLine(_ line: String, with f: WidgetFloat?) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var kept = words.filter { w in w != "float" && !["x=", "y=", "w="].contains { w.hasPrefix($0) } }
        if let f {
            kept += ["float", "x=\(Int(f.x.rounded()))", "y=\(Int(f.y.rounded()))", "w=\(Int(f.w.rounded()))"]
        }
        return String(indent) + kept.joined(separator: " ")
    }

    /// The first line of a block.
    static func of(block: String) -> WidgetFloat? {
        parse(String(block.prefix { $0 != "\n" }))
    }
}

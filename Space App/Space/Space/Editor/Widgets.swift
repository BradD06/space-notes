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
                let lower = t.lowercased()
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

/// The widgets pinned to the dashboard, in their order, per vault.
@MainActor
@Observable
final class PinnedWidgets {
    static let shared = PinnedWidgets()
    private(set) var tokens: [String] = []
    @ObservationIgnored private var vaultKey = ""

    private var storeKey: String { "space.dashboardWidgets." + vaultKey }

    func use(_ vault: VaultStore) {
        let key = vault.rootURL?.path ?? ""
        guard key != vaultKey else { return }
        vaultKey = key
        tokens = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
    }

    func isPinned(_ ref: WidgetRef) -> Bool { tokens.contains(ref.token) }

    func toggle(_ ref: WidgetRef) {
        if let i = tokens.firstIndex(of: ref.token) { tokens.remove(at: i) } else { tokens.append(ref.token) }
        save()
    }

    func remove(_ token: String) {
        tokens.removeAll { $0 == token }
        save()
    }

    /// Puts `token` where `before` is (or at the end).
    func move(_ token: String, before: String?) {
        guard token != before, let from = tokens.firstIndex(of: token) else { return }
        tokens.remove(at: from)
        let to = before.flatMap { tokens.firstIndex(of: $0) } ?? tokens.count
        tokens.insert(token, at: to)
        save()
    }

    private func save() { UserDefaults.standard.set(tokens, forKey: storeKey) }
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

/// Widgets pinned to the dashboard: a grid of cards, reordered by dragging one onto another,
/// dragged out of the dashboard into any pane, and added from every widget in the vault.
struct DashboardWidgets: View {
    @Environment(VaultStore.self) private var vault
    @Environment(Workspace.self) private var workspace
    private let pinned = PinnedWidgets.shared
    @State private var dropTarget: String?

    var body: some View {
        let _ = pinned.use(vault)
        let refs = pinned.tokens.compactMap(WidgetRef.init(token:))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("ВИДЖЕТЫ").font(Theme.mono(10)).kerning(1.4).foregroundStyle(Theme.muted)
                Spacer()
                addMenu
            }
            .padding(.horizontal, 6)
            if refs.isEmpty {
                Text("Закрепи сюда виджеты из заметок: «+» справа или меню виджета в заметке.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6)
            } else {
                // The page under the widgets keeps its room: past a point the widgets scroll.
                GeometryReader { g in
                    let columns = max(1, Int((g.size.width + 14) / 480))
                    let w = (g.size.width - CGFloat(columns - 1) * 14) / CGFloat(columns)
                    ScrollView { grid(refs, columns: columns, width: w) }
                        .scrollIndicators(.automatic)
                }
                .frame(height: min(max(gridHeight, 120), Self.maxSectionHeight))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    static let maxSectionHeight: CGFloat = 560
    static let maxCardHeight: CGFloat = 460

    // The grid's own height, reported by its rows (a GeometryReader has none of its own).
    @State private var gridHeight: CGFloat = 200

    private func grid(_ refs: [WidgetRef], columns: Int, width: CGFloat) -> some View {
        let rows = stride(from: 0, to: refs.count, by: columns).map { Array(refs[$0..<min($0 + columns, refs.count)]) }
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(row, id: \.self) { ref in card(ref, width: width) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { gridHeight = g.size.height }
                .onChange(of: g.size.height) { _, h in gridHeight = h }
        })
    }

    private func card(_ ref: WidgetRef, width: CGFloat) -> some View {
        let entry = WidgetIndex.shared.entry(ref, vault)
        let name = entry?.name ?? ((ref.note as NSString).lastPathComponent as NSString).deletingPathExtension
        let icon = entry?.icon ?? "square.grid.2x2"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").foregroundStyle(Theme.faint)
                    .help("Перетащи на другой виджет, чтобы поменять порядок, или в любую панель")
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
            // Drag by the header: onto another card to reorder, onto a pane (or its side) to open it there.
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { v in
                    if workspace.drag == nil {
                        workspace.beginDrag(WorkTab.widget(ref.token).token, title: name, icon: icon, at: v.location)
                    } else {
                        workspace.moveDrag(to: v.location)
                    }
                    dropTarget = cardFrames.first(where: { $0.value.contains(v.location) && $0.key != ref.token })?.key
                }
                .onEnded { _ in
                    if let target = dropTarget {
                        workspace.cancelDrag()
                        withAnimation(.smooth(duration: 0.25)) { pinned.move(ref.token, before: target) }
                    } else {
                        workspace.endDrag()
                    }
                    dropTarget = nil
                })
            // Tall widgets (a long task list) scroll inside their card.
            ViewThatFits(in: .vertical) {
                WidgetBlockView(ref: ref, width: width - 24)
                ScrollView { WidgetBlockView(ref: ref, width: width - 24) }
            }
            .frame(maxHeight: Self.maxCardHeight)
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(dropTarget == ref.token ? Theme.accent.opacity(0.7) : Color.white.opacity(0.07), lineWidth: dropTarget == ref.token ? 2 : 1))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { cardFrames[ref.token] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in cardFrames[ref.token] = f }
        })
    }

    @State private var cardFrames: [String: CGRect] = [:]

    private var addMenu: some View {
        let all = WidgetIndex.shared.all(vault)
        let byNote = Dictionary(grouping: all, by: { $0.ref.note })
        return Menu {
            if all.isEmpty { Text("В заметках нет блоков dataview / dataviewjs") }
            ForEach(byNote.keys.sorted(), id: \.self) { note in
                let title = ((note as NSString).lastPathComponent as NSString).deletingPathExtension
                Menu(title) {
                    ForEach(byNote[note] ?? []) { e in
                        Button {
                            pinned.toggle(e.ref)
                        } label: {
                            Label(pinned.isPinned(e.ref) ? "\(e.name)  ✓" : e.name, systemImage: e.icon)
                        }
                    }
                }
            }
        } label: {
            Label("Добавить", systemImage: "plus")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .contentShape(Capsule())
        }
        #if os(macOS)
        .menuStyle(.button).menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain).fixedSize()
        .help("Закрепить на дашборде виджет из любой заметки")
    }
}

/// The widget's own menu (in its note, in a pane): open it in a pane, pin it to the dashboard.
struct WidgetMenu: View {
    let ref: WidgetRef
    var standalone = false
    var onShowCode: (() -> Void)?
    @Environment(VaultStore.self) private var vault
    private let pinned = PinnedWidgets.shared

    var body: some View {
        let _ = pinned.use(vault)
        Menu {
            if !standalone {
                Button("Открыть в отдельной панели", systemImage: "arrow.up.forward.square") { vault.selection = .widget(ref.token) }
            }
            Button(pinned.isPinned(ref) ? "Убрать с дашборда" : "Закрепить на дашборде",
                   systemImage: pinned.isPinned(ref) ? "pin.slash" : "pin") { pinned.toggle(ref) }
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
        .help("Виджет: отдельная панель, дашборд")
    }
}

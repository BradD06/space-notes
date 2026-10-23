import SwiftUI

/// Whether the command bar is open. One for the window, shared by the top bar's field, the sidebar and ⌘K.
@MainActor
@Observable
final class CommandCenter {
    var open = false
    var query = ""

    func show(_ text: String = "") {
        query = text
        open = true
    }
}

/// The one command bar (⌘K): finds a star by name, creates one from what was typed, or with ">" runs a command.
struct CommandPalette: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var map
    @Environment(CommandCenter.self) private var center
    @AppStorage(Appearance.key) private var appearance = Appearance.dark.rawValue
    @AppStorage("space.sidebarCompact") private var compactSidebar = false
    @State private var selected = 0
    @State private var creating: CreateKind?
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        var detail = ""
        let run: () -> Void
    }

    var body: some View {
        @Bindable var center = center
        ZStack(alignment: .top) {
            if center.open {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                panel(query: $center.query)
                    .padding(.top, 70)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.2), value: center.open)
        .onChange(of: center.open) { _, open in
            if open { selected = 0; Task { @MainActor in focused = true } }
        }
        .onChange(of: center.query) { _, _ in selected = 0 }
        .sheet(item: $creating) { kind in CreateSheet(kind: kind) }
        .background {
            // ⌘K anywhere (inside a note's text ⌘K stays "link to a star").
            Button("") { center.open ? close() : center.show() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0).allowsHitTesting(false)
        }
    }

    private func panel(query: Binding<String>) -> some View {
        let items = self.items
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.muted)
                TextField("", text: query, prompt: Text("Найти, создать звезду или «>» для команды").foregroundStyle(Theme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                Text("esc").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.wash.opacity(0.13)))
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            if !items.isEmpty {
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == selected)
                                .onTapGesture { item.run(); close() }
                                .onHover { if $0 { selected = i } }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 600)
        .background(GlassPanel(radius: 22, thickness: .thick, density: 1.5))
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Theme.muted)
                .frame(width: 22)
            Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail).font(.system(size: 12)).foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.muted).lineLimit(1)
        }
        .foregroundStyle(selected ? Color.white : Theme.ink)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Theme.accent : .clear))
        .contentShape(Rectangle())
    }

    private var items: [Item] {
        let q = center.query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix(">") {
            let c = String(q.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
            return commands.filter { c.isEmpty || $0.title.lowercased().contains(c) }
        }
        let cosmos = vault.cosmos
        guard !q.isEmpty else {
            // Nothing typed yet: the recent stars, then the commands.
            let recent = InsightsCache.insights(vault).recent.prefix(5).map { star($0, cosmos) }
            return recent + commands.prefix(4)
        }
        let lower = q.lowercased()
        let found = cosmos.notes.keys
            .filter { cosmos.title($0).lowercased().contains(lower) }
            .sorted {
                let a = cosmos.title($0).lowercased().hasPrefix(lower), b = cosmos.title($1).lowercased().hasPrefix(lower)
                return a != b ? a : cosmos.title($0).localizedStandardCompare(cosmos.title($1)) == .orderedAscending
            }
            .prefix(8)
            .map { star($0, cosmos) }
        let exact = cosmos.notes.keys.contains { cosmos.title($0).lowercased() == lower }
        let create = Item(id: "create", icon: "plus", title: "Создать звезду «\(q)»", detail: "во «Входящих»") {
            createStar(q)
        }
        return found + (exact ? [] : [create])
    }

    private func star(_ id: String, _ cosmos: Cosmos) -> Item {
        Item(id: "n:" + id, icon: Documents.icon(for: id), title: cosmos.title(id),
             detail: cosmos.universe(cosmos.universeOf[id] ?? "")?.name ?? "") { vault.selection = .note(id) }
    }

    private var commands: [Item] {
        let light = appearance == Appearance.light.rawValue
        return [
            Item(id: "c:star", icon: "square.and.pencil", title: "Новая звезда", detail: "⌘N") { creating = .star(universe: inboxID, constellation: "") },
            Item(id: "c:map", icon: "sparkles", title: "Карта звёзд", detail: "⌘G") { vault.selection = .map; map.go(to: .multiverse) },
            Item(id: "c:dash", icon: "rectangle.3.group", title: "Дашборд") { vault.selection = .dashboard },
            Item(id: "c:theme", icon: light ? "moon" : "sun.max", title: light ? "Тёмная тема" : "Светлая тема") {
                withAnimation(.smooth(duration: 0.3)) { appearance = (light ? Appearance.dark : .light).rawValue }
            },
            Item(id: "c:universe", icon: "circle.dashed", title: "Новая вселенная") { creating = .universe },
            Item(id: "c:fold", icon: "sidebar.left", title: compactSidebar ? "Развернуть меню" : "Свернуть меню", detail: "⌃⌘S") { compactSidebar.toggle() },
            Item(id: "c:reload", icon: "arrow.clockwise", title: "Перечитать хранилище") { Task { await vault.reload(showingProgress: true) } }
        ]
    }

    /// "Входящие" when the vault has one, else the first universe.
    private var inboxID: String {
        let u = vault.cosmos.universes
        return (u.first { $0.name == Cosmos.inboxName } ?? u.first)?.id ?? ""
    }

    private func createStar(_ title: String) {
        let universe = inboxID
        Task {
            do {
                let id = try await vault.createStar(titled: title, inUniverse: universe, constellation: "")
                vault.selection = .note(id)
            } catch {
                vault.errorMessage = error.localizedDescription
            }
        }
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selected) else { return }
        items[selected].run()
        close()
    }

    private func close() {
        center.open = false
        center.query = ""
        focused = false
    }
}

/// The command bar as it sits in a top bar: looks like a search field, opens the command bar.
struct CommandField: View {
    @Environment(CommandCenter.self) private var center
    @State private var hover = false

    var body: some View {
        Button { center.show() } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold))
                Text("Найти, создать звезду или «>» для команды").font(.system(size: 13.5)).lineLimit(1)
                Spacer(minLength: 6)
                Text("⌘K").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.8))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.wash.opacity(0.13)))
            }
            .foregroundStyle(Theme.muted)
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 42)
            .frame(maxWidth: 520)
            // A well in the glass: a little darker, with a shadow inside its top edge.
            .background(Capsule().fill(Theme.wash.opacity(hover ? 0.1 : 0.06)))
            .overlay(Capsule().strokeBorder(Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Командная строка")
    }
}

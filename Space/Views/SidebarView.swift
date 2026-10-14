import SwiftUI
import UniformTypeIdentifiers

/// Universes → constellations → stars, the same structure as on the map.
/// Each universe folds and unfolds; the toolbar creates new universes, constellations and stars.
struct SidebarView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var map
    @AppStorage("space.collapsedUniverses") private var collapsedRaw = ""
    @State private var creating: CreateKind?
    @State private var creatingVault = false
    @State private var openingVault = false

    var body: some View {
        @Bindable var vault = vault
        let cosmos = vault.cosmos

        List(selection: $vault.selection) {
            Label("Карта космоса", systemImage: "sparkles")
                .tag(VaultStore.Selection.map)

            ForEach(cosmos.universes) { universe in
                // A plain Section (not Section(isExpanded:)) so macOS doesn't add its own second chevron on hover.
                Section {
                    if isExpanded(universe.id) {
                    ForEach(universe.constellations.filter { $0.name != Cosmos.looseName }) { constellation in
                        DisclosureGroup {
                            ForEach(constellation.noteIDs, id: \.self) { id in
                                Text(cosmos.title(id)).lineLimit(1).tag(VaultStore.Selection.note(id))
                            }
                        } label: {
                            HStack {
                                Text(constellation.name)
                                Spacer()
                                Text("\(constellation.noteIDs.count)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            }
                        }
                        .contextMenu {
                            Button("Новая звезда здесь", systemImage: "plus") {
                                creating = .star(universe: universe.id, constellation: constellation.name)
                            }
                        }
                    }
                    // Notes that sit directly in the universe folder are listed as they are, without a group.
                    if let loose = universe.constellations.first(where: { $0.name == Cosmos.looseName }) {
                        ForEach(loose.noteIDs, id: \.self) { id in
                            Label(cosmos.title(id), systemImage: "smallcircle.filled.circle")
                                .lineLimit(1)
                                .tag(VaultStore.Selection.note(id))
                        }
                    }
                    }
                } header: {
                    UniverseHeader(universe: universe, expanded: isExpanded(universe.id)) {
                        toggle(universe.id)
                    }
                    .contextMenu {
                        Button("Новое созвездие", systemImage: "sparkle") { creating = .constellation(universe: universe.id) }
                        Button("Новая звезда", systemImage: "plus") { creating = .star(universe: universe.id, constellation: "") }
                        Button("Показать на карте", systemImage: "sparkles") {
                            vault.selection = .map
                            map.go(to: .universe(universe.id), cosmos: cosmos, layout: map.layout)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationTitle(vault.vaultName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { creating = .universe } label: { Label("Новая вселенная", systemImage: "circle.dashed") }
                    .help("Новая вселенная — папка верхнего уровня")
                Button { creating = .constellation(universe: contextUniverse) } label: { Label("Новое созвездие", systemImage: "sparkle") }
                    .help("Новое созвездие — папка внутри вселенной")
                Button { creating = .star(universe: contextUniverse, constellation: contextConstellation) } label: {
                    Label("Новая звезда", systemImage: "square.and.pencil")
                }
                .help("Новая звезда — заметка")
                .keyboardShortcut("n", modifiers: .command)

                Menu {
                    Button("Свернуть все вселенные", systemImage: "rectangle.compress.vertical") { setAll(expanded: false) }
                    Button("Развернуть все вселенные", systemImage: "rectangle.expand.vertical") { setAll(expanded: true) }
                    Divider()
                    Button("Перечитать хранилище", systemImage: "arrow.clockwise") { Task { await vault.reload() } }
                    Button("Вернуть вселенные на места", systemImage: "circle.grid.cross") { map.resetUniversePositions() }
                    Divider()
                    Button("Новое хранилище…", systemImage: "externaldrive.badge.plus") { creatingVault = true }
                    Button("Открыть другое хранилище…", systemImage: "folder") { openingVault = true }
                    Divider()
                    Button("Закрыть хранилище", systemImage: "xmark.circle", role: .destructive) { vault.close() }
                } label: {
                    Label("Ещё", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $creating) { kind in
            CreateSheet(kind: kind)
        }
        .sheet(isPresented: $creatingVault) { CreateVaultSheet() }
        .fileImporter(isPresented: $openingVault, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await vault.open(url) } }
        }
    }

    // MARK: Context for the create buttons: the universe/constellation you are looking at right now.

    private var contextUniverse: String {
        let c = vault.cosmos
        if case .note(let id) = vault.selection, let u = c.universeOf[id] { return u }
        if let u = map.focusedUniverse { return u }
        if let s = map.focusedStar, let u = c.universeOf[s] { return u }
        return c.universes.first(where: { $0.name != Cosmos.inboxName })?.id ?? c.universes.first?.id ?? ""
    }

    private var contextConstellation: String {
        let c = vault.cosmos
        let star: String? = { if case .note(let id) = vault.selection { return id }; return map.focusedStar }()
        guard let s = star, let cid = c.constellationOf[s] else { return "" }
        return c.constellationName[cid] ?? ""
    }

    // MARK: Folding

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: "\n").map(String.init))
    }

    private func isExpanded(_ id: String) -> Bool { !collapsed.contains(id) }

    private func toggle(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        collapsedRaw = set.sorted().joined(separator: "\n")
    }

    private func setAll(expanded: Bool) {
        collapsedRaw = expanded ? "" : vault.cosmos.universes.map(\.id).joined(separator: "\n")
    }

}

/// Universe row header: colour, name, count, and a chevron that folds its constellations.
private struct UniverseHeader: View {
    let universe: Cosmos.Universe
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                // Chevron on the left, like Finder: clearly apart from the count.
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.smooth(duration: 0.2), value: expanded)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 12)
                Circle()
                    .fill(Theme.color(forUniverseIndex: universe.colorIndex))
                    .frame(width: 8, height: 8)
                Text(universe.name)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text("\(universe.starCount)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.muted)
                    .padding(.trailing, 6)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(universe.name), \(expanded ? "свернуть" : "развернуть")")
    }
}

// MARK: - Creating things

enum CreateKind: Identifiable, Hashable {
    case universe
    case constellation(universe: String)
    case star(universe: String, constellation: String)

    var id: String {
        switch self {
        case .universe: "u"
        case .constellation(let u): "c" + u
        case .star(let u, let c): "s" + u + "/" + c
        }
    }
}

/// One small sheet for all three: a name, and where to put it.
struct CreateSheet: View {
    let kind: CreateKind
    @Environment(VaultStore.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var universe = ""
    @State private var constellation = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        let cosmos = vault.cosmos
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon)
                .font(.title2.weight(.semibold))
            Text(hint).font(.callout).foregroundStyle(Theme.muted)

            TextField(placeholder, text: $name)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .focused($nameFocused)
                .onSubmit(create)

            if !isUniverse {
                Picker("Вселенная", selection: $universe) {
                    ForEach(cosmos.universes.filter { !isConstellation || $0.name != Cosmos.inboxName }) { u in
                        Text(u.name).tag(u.id)
                    }
                }
            }
            if isStar, let u = cosmos.universe(universe), u.name != Cosmos.inboxName {
                Picker("Созвездие", selection: $constellation) {
                    Text("Без созвездия").tag("")
                    ForEach(u.constellations.filter { $0.name != Cosmos.looseName }) { c in
                        Text(c.name).tag(c.name)
                    }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(Color(hex: 0xE8826B))
            }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Создать", action: create)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .onAppear {
            switch kind {
            case .universe: break
            case .constellation(let u): universe = u
            case .star(let u, let c): universe = u; constellation = c
            }
            if universe.isEmpty || vault.cosmos.universe(universe) == nil { universe = vault.cosmos.universes.first?.id ?? "" }
            nameFocused = true
        }
        .onChange(of: universe) { _, _ in
            if case .star(_, let c) = kind, vault.cosmos.universe(universe)?.constellations.contains(where: { $0.name == c }) == true {
                constellation = c
            } else {
                constellation = ""
            }
        }
    }

    private var isUniverse: Bool { if case .universe = kind { true } else { false } }
    private var isConstellation: Bool { if case .constellation = kind { true } else { false } }
    private var isStar: Bool { if case .star = kind { true } else { false } }

    private var title: String { isUniverse ? "Новая вселенная" : isConstellation ? "Новое созвездие" : "Новая звезда" }
    private var icon: String { isUniverse ? "circle.dashed" : isConstellation ? "sparkle" : "square.and.pencil" }
    private var placeholder: String { isUniverse ? "Например, Изучение английского" : isConstellation ? "Например, Грамматика" : "Название заметки" }
    private var hint: String {
        isUniverse ? "Большая тема. В хранилище появится папка верхнего уровня."
        : isConstellation ? "Группа заметок внутри вселенной. Появится папка внутри папки вселенной."
        : "Заметка в формате Markdown. Откроется сразу после создания."
    }

    private func create() {
        let value = name
        Task {
            do {
                switch kind {
                case .universe: try await vault.createUniverse(named: value)
                case .constellation: try await vault.createConstellation(named: value, inUniverse: universe)
                case .star: try await vault.createStar(titled: value, inUniverse: universe, constellation: constellation)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

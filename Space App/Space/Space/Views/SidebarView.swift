import SwiftUI
import UniformTypeIdentifiers

/// The sidebar: a header with the vault, a small menu, the universes as a cascading tree
/// (universe → constellation → star) in a glass card, and a "create" card at the bottom.
/// It folds into a narrow rail of icons with the button in the header.
struct SidebarView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var map
    @Environment(Workspace.self) private var workspace
    @AppStorage("space.collapsedUniverses") private var collapsedRaw = ""
    @AppStorage("space.sidebarCompact") private var compact = false
    @State private var creating: CreateKind?
    @State private var creatingVault = false
    @State private var openingVault = false
    @State private var deleting: DeleteTarget?
    @State private var search = ""
    @State private var pickingCover = false

    var body: some View {
        VStack(spacing: 0) {
            brandRow
            vaultCard
            GlowDivider()
            searchField                          // the map button, and search beside it when there's room
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !search.isEmpty && !compact {
                        SectionLabel(title: "Найдено", compact: compact)
                        searchResults
                    } else {
                        universesHeader
                        tree
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            GlowDivider()
            vaultBar
        }
        #if os(macOS)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))   // red bands stop at the round corners
        #endif
        // The round fold button sits on the panel's edge, half outside, as in the reference.
        .overlay(alignment: .topTrailing) {
            // Below the panes' tab bars, so it never covers a tab.
            foldButton.offset(x: 13, y: 74)
        }
        .animation(.smooth(duration: 0.3), value: compact)
        #if !os(macOS)
        .navigationTitle(vault.vaultName)
        #endif
        .sheet(item: $creating) { kind in CreateSheet(kind: kind) }
        .confirmationDialog(deleting?.question ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { target in
            Button(target.action, role: .destructive) {
                Task {
                    do { try await vault.trash(target.path) }
                    catch { vault.errorMessage = error.localizedDescription }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { target in
            Text(target.detail)
        }
        .sheet(isPresented: $creatingVault) { CreateVaultSheet() }
        .onAppear { workspace.onMoveToFolder = { payload, folder in moveItem(payload, to: folder) } }
        .fileImporter(isPresented: $openingVault, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await vault.open(url) } }
        }
    }

    // MARK: Header: the app's name, back / forward, the vault card and search

    /// The top row: the window's buttons sit on the left (placed by the window), back / forward on the right
    /// at the same height. In the narrow rail the arrows go just below the window's buttons.
    private var brandRow: some View {
        Group {
            if compact {
                HStack(spacing: 0) { backButton; forwardButton }
                    .padding(.top, 30)
            } else {
                HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    backButton
                    forwardButton
                }
                .frame(height: 28)                // centred on the window buttons' line (14 points below the top)
                .padding(.trailing, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    /// Round button on the panel's edge: folds the sidebar to a rail of icons and back.
    private var foldButton: some View {
        Button { compact.toggle() } label: {
            Image(systemName: compact ? "chevron.right" : "chevron.left")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.ground)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.ink))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tip(compact ? "Развернуть панель (⌃⌘S)" : "Свернуть панель (⌃⌘S)")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    /// The vault's profile: its cover with the name and numbers. A click opens the vault's dashboard.
    private var vaultCard: some View {
        let selected = vault.selection == .dashboard
        return Button { vault.selection = .dashboard } label: {
            if compact {
                VaultCover(name: vault.vaultName, stats: "", height: 50, showText: false, selected: selected)
                    .frame(width: 50)
            } else {
                VaultCover(name: vault.vaultName, stats: DashboardView.stats(vault.cosmos), height: 96, selected: selected)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 0 : 14)
        .padding(.top, 4).padding(.bottom, 12)
        .contextMenu {
            Button("Открыть дашборд", systemImage: "rectangle.3.group") { vault.selection = .dashboard }
            Button("Сменить обложку…", systemImage: "photo") { pickingCover = true }
            if VaultProfile.shared.coverFile != nil {
                Button("Убрать обложку", systemImage: "trash", role: .destructive) { VaultProfile.shared.removeCover() }
            }
        }
        .fileImporter(isPresented: $pickingCover, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            do { try VaultProfile.shared.setCover(from: url) }
            catch { vault.errorMessage = "Не удалось поставить обложку: \(error.localizedDescription)" }
        }
        .tip("Дашборд хранилища")
    }

    /// Search capsule: filters the stars by name.
    private var searchField: some View {
        HStack(spacing: 10) {
            mapButton
            if !compact {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                TextField("", text: $search, prompt: Text("ПОИСК…").foregroundStyle(Theme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .tip("Очистить поиск")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 0 : 18)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// "Карта космоса": a round button by the search; red while the map is open.
    private var mapButton: some View {
        let selected = vault.selection == .map
        return Button {
            vault.selection = .map
            map.go(to: .multiverse, cosmos: vault.cosmos, layout: map.layout)
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(selected ? Color.white : Theme.ground)
                .frame(width: 30, height: 30)
                .background(Circle().fill(selected ? Theme.accent : Theme.ink.opacity(0.85)))
                .shadow(color: selected ? Theme.accent.opacity(0.45) : .clear, radius: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tip("Карта космоса")
    }

    private var searchResults: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let cosmos = vault.cosmos
        let found = Self.byName(cosmos.notes.keys.filter { cosmos.title($0).lowercased().contains(q) })
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(found.prefix(80), id: \.self) { id in
                starRow(id, level: 0, color: Theme.color(forUniverse: cosmos.universeOf[id]))
            }
            if found.isEmpty {
                Text("Ничего не нашлось").font(.callout).foregroundStyle(Theme.muted).padding(.horizontal, 18).padding(.vertical, 8)
            }
        }
    }

    /// "ВСЕЛЕННЫЕ" with the explorer's buttons on the right.
    private var universesHeader: some View {
        HStack(spacing: 0) {
            SectionLabel(title: "Вселенные", compact: compact)
            if !compact {
                Spacer(minLength: 0)
                newStarButton
                IconButton(icon: "folder.badge.plus", help: "Новое созвездие") { creating = .constellation(universe: contextUniverse) }
                IconButton(icon: "circle.dashed", help: "Новая вселенная") { creating = .universe }
                Menu {
                    Button("Свернуть все", systemImage: "rectangle.compress.vertical") { setAll(expanded: false) }
                    Button("Развернуть все", systemImage: "rectangle.expand.vertical") { setAll(expanded: true) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Theme.muted)
                .tip("Ещё: свернуть или развернуть все")
                .padding(.trailing, 12)
            }
        }
        .overlay(alignment: .trailing) {
            if compact { newStarButton.frame(maxWidth: .infinity).offset(y: 26) }
        }
        .padding(.bottom, compact ? 26 : 0)
        // With no "Входящие" row (nothing in the vault's root), the header takes files back to the root.
        .modifier(OptionalRootDrop(active: !vault.cosmos.universes.contains { vault.folderName(ofUniverse: $0.id).isEmpty }))
    }

    /// The bar at the bottom of the panel: managing the vault itself.
    private var vaultBar: some View {
        let buttons = Group {
            BarButton(icon: "folder", help: "Открыть другое хранилище…") { openingVault = true }
            BarButton(icon: "externaldrive.badge.plus", help: "Новое хранилище…") { creatingVault = true }
            BarButton(icon: "arrow.clockwise", help: "Перечитать хранилище") { Task { await vault.reload() } }
            BarButton(icon: "circle.grid.cross", help: "Вернуть вселенные на карте на места") { map.resetUniversePositions() }
            BarButton(icon: "rectangle.portrait.and.arrow.right", help: "Закрыть хранилище", destructive: true) { vault.close() }
        }
        return Group {
            if compact {
                VStack(spacing: 8) { buttons }
            } else {
                HStack(spacing: 0) { buttons }.frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, compact ? 0 : 12)
        .frame(maxWidth: .infinity)
    }

    private var backButton: some View {
        IconButton(icon: "chevron.left", help: "Назад (⌘[)") { vault.goBack() }
            .disabled(vault.backStack.isEmpty)
            .opacity(vault.backStack.isEmpty ? 0.4 : 1)
            .keyboardShortcut("[", modifiers: .command)
    }

    private var forwardButton: some View {
        IconButton(icon: "chevron.right", help: "Вперёд (⌘])") { vault.goForward() }
            .disabled(vault.forwardStack.isEmpty)
            .opacity(vault.forwardStack.isEmpty ? 0.4 : 1)
            .keyboardShortcut("]", modifiers: .command)
    }

    private var newStarButton: some View {
        IconButton(icon: "square.and.pencil", help: "Новая звезда (⌘N)") {
            creating = .star(universe: contextUniverse, constellation: contextConstellation)
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    // MARK: Universes

    private var tree: some View {
        let cosmos = vault.cosmos
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(cosmos.universes) { universe in
                if compact {
                    CompactUniverse(universe: universe) {
                        vault.selection = .map
                        map.go(to: .universe(universe.id), cosmos: cosmos, layout: map.layout)
                    }
                } else {
                    universeTree(universe)
                }
            }
            if cosmos.universes.isEmpty, !compact {
                Text("Пока пусто. Создай первую вселенную.").font(.callout).foregroundStyle(Theme.muted).padding(8)
            }
        }
    }

    @ViewBuilder
    private func universeTree(_ universe: Cosmos.Universe) -> some View {
        let cosmos = vault.cosmos
        let open = isExpanded(universe.id)
        let color = Theme.color(forUniverse: universe.id)
        TreeRow(level: 0, expandable: true, expanded: open, selected: false, count: universe.starCount,
                onToggle: { toggle(universe.id) }, onTap: { toggle(universe.id) }) {
            UniverseDot(universe: universe)
            Text(universe.name).fontWeight(.medium).lineLimit(1)
        }
        .modifier(FolderRowDrag(path: vault.folderName(ofUniverse: universe.id),
                                draggable: !vault.folderName(ofUniverse: universe.id).isEmpty, title: universe.name))
        .contextMenu {
            Button("Новое созвездие", systemImage: "sparkle") { creating = .constellation(universe: universe.id) }
            Button("Новая звезда", systemImage: "plus") { creating = .star(universe: universe.id, constellation: "") }
            Button("Показать на карте", systemImage: "sparkles") {
                vault.selection = .map
                map.go(to: .universe(universe.id), cosmos: cosmos, layout: map.layout)
            }
            Divider()
            colorMenu(for: universe.id)
            let folder = vault.folderName(ofUniverse: universe.id)
            if !folder.isEmpty {
                Divider()
                Button("Удалить вселенную…", systemImage: "trash", role: .destructive) {
                    deleting = DeleteTarget(kind: .universe, name: universe.name, path: folder, stars: universe.starCount)
                }
            }
        }

        if open {
            ForEach(universe.constellations.filter { $0.name != Cosmos.looseName }) { c in
                let key = "c:" + c.id
                let cOpen = isExpanded(key, defaultOpen: false)
                TreeRow(level: 1, expandable: true, expanded: cOpen, selected: false, count: nil,
                        onToggle: { toggle(key, defaultOpen: false) }, onTap: { toggle(key, defaultOpen: false) }) {
                    Image(systemName: "book.closed").foregroundStyle(Theme.muted).font(.system(size: 11))
                    Text(c.name).lineLimit(1)
                }
                .modifier(FolderRowDrag(path: vault.folderPath(ofConstellation: c.name, inUniverse: universe.id), draggable: true, title: c.name))
                .contextMenu {
                    Button("Новая звезда здесь", systemImage: "plus") { creating = .star(universe: universe.id, constellation: c.name) }
                    let folder = vault.folderPath(ofConstellation: c.name, inUniverse: universe.id)
                    if !folder.isEmpty {
                        Divider()
                        Button("Удалить созвездие…", systemImage: "trash", role: .destructive) {
                            deleting = DeleteTarget(kind: .constellation, name: c.name, path: folder, stars: c.noteIDs.count)
                        }
                    }
                }
                if cOpen {
                    let path = vault.folderPath(ofConstellation: c.name, inUniverse: universe.id)
                    if path.isEmpty {
                        ForEach(Self.byName(c.noteIDs), id: \.self) { id in starRow(id, level: 2, color: color) }
                    } else {
                        folderTree(path, notes: c.noteIDs, level: 2, color: color)
                    }
                }
            }
            if let loose = universe.constellations.first(where: { $0.name == Cosmos.looseName }) {
                ForEach(Self.byName(loose.noteIDs), id: \.self) { id in starRow(id, level: 1, color: color) }
            }
        }
    }

    /// "Цвет" submenu: coloured circles, the current one marked.
    private func colorMenu(for id: String) -> some View {
        let colors = UniverseColors.shared
        let current = colors.hex(for: id)
        return Menu {
            ForEach(UniverseColors.swatches) { s in
                Button {
                    withAnimation(.smooth) { colors.set(s.hex, for: id) }
                } label: {
                    Label { Text(s.hex == current ? "\(s.name)  ✓" : s.name) } icon: { swatchImage(s.hex) }
                }
            }
        } label: {
            Label("Цвет", systemImage: "paintpalette")
        }
    }

    private func starRow(_ id: String, level: Int, color: Color) -> some View {
        let selected = vault.selection == .note(id)
        return TreeRow(level: level, expandable: false, expanded: false, selected: selected, tint: color,
                       count: nil, onToggle: {}, onTap: { vault.selection = .note(id) }) {
            if Books.isBook(id) {
                Image(systemName: "book.closed.fill").font(.system(size: 10)).foregroundStyle(selected ? Color.white : Theme.muted)
            }
            Text(vault.cosmos.title(id)).lineLimit(1)
        }
        // Drag a note onto any pane (or its side) to open it there.
        .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                if workspace.drag == nil {
                    workspace.beginDrag(WorkTab.note(id).token, title: vault.cosmos.title(id),
                                        icon: Books.isBook(id) ? "book.closed" : "doc.text", at: v.location)
                } else {
                    workspace.moveDrag(to: v.location)
                }
            }
            .onEnded { _ in workspace.endDrag() })
        .contextMenu {
            Button("Открыть в новой вкладке", systemImage: "plus.square.on.square") { workspace.openInNewTab(.note(id)) }
            Button("Открыть справа", systemImage: "rectangle.split.2x1") { workspace.openToTheSide(.note(id)) }
            Divider()
            Button("Удалить звезду…", systemImage: "trash", role: .destructive) {
                deleting = DeleteTarget(kind: .star, name: vault.cosmos.title(id), path: id, stars: 1)
            }
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
    // Universes are open by default; constellations are folded by default (keys start with "c:").
    // The stored set holds the ones that differ from their default.

    private var flipped: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }

    /// The inside of a folder as in Finder: its subfolders (each a branch of its own, at any depth) and then its notes.
    private func folderTree(_ path: String, notes: [String], level: Int, color: Color) -> AnyView {
        let prefix = path + "/"
        var subfolders = Set<String>()
        var direct: [String] = []
        for id in notes where id.hasPrefix(prefix) {
            let rest = id.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { subfolders.insert(String(rest[..<slash])) } else { direct.append(id) }
        }
        for folder in vault.cosmos.folders where folder.hasPrefix(prefix) {
            let rest = folder.dropFirst(prefix.count)
            if let first = rest.split(separator: "/").first { subfolders.insert(String(first)) }
        }
        let sorted = subfolders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return AnyView(Group {
            ForEach(sorted, id: \.self) { name in
                let sub = prefix + name
                let inside = notes.filter { $0.hasPrefix(sub + "/") }
                let key = "f:" + sub
                let open = isExpanded(key, defaultOpen: false)
                TreeRow(level: level, expandable: true, expanded: open, selected: false, count: inside.isEmpty ? nil : inside.count,
                        onToggle: { toggle(key, defaultOpen: false) }, onTap: { toggle(key, defaultOpen: false) }) {
                    Image(systemName: open ? "folder" : "folder.fill").foregroundStyle(Theme.muted).font(.system(size: 11))
                    Text(name).lineLimit(1)
                }
                .modifier(FolderRowDrag(path: sub, draggable: true, title: name))
                .contextMenu {
                    Button("Удалить папку…", systemImage: "trash", role: .destructive) {
                        deleting = DeleteTarget(kind: .folder, name: name, path: sub, stars: inside.count)
                    }
                }
                if open {
                    folderTree(sub, notes: inside, level: level + 1, color: color)
                }
            }
            ForEach(Self.byName(direct), id: \.self) { id in starRow(id, level: level, color: color) }
        })
    }

    /// A note, book or folder dropped onto a folder row: the file moves there, open tabs follow it.
    private func moveItem(_ payload: String, to folder: String) {
        let item = payload.hasPrefix("note:") ? String(payload.dropFirst(5)) : String(payload.dropFirst(7))
        do {
            guard let new = try vault.move(item, toFolder: folder) else { return }
            workspace.retarget(old: item, new: new)
            if case .note(let id) = vault.selection, id == item || id.hasPrefix(item + "/") {
                vault.selection = .note(id == item ? new : new + id.dropFirst(item.count))
            }
            Task { await vault.reload() }
        } catch {
            vault.errorMessage = error.localizedDescription
        }
    }

    /// The explorer keeps notes in a steady order, by file name as in Finder and Obsidian ("E01-02" before "E01-10").
    /// (The map orders them by links instead; that order changes as links do.)
    static func byName(_ ids: [String]) -> [String] {
        ids.sorted {
            let a = ($0 as NSString).lastPathComponent, b = ($1 as NSString).lastPathComponent
            let r = a.localizedStandardCompare(b)
            return r == .orderedSame ? $0 < $1 : r == .orderedAscending
        }
    }

    private func isExpanded(_ id: String, defaultOpen: Bool = true) -> Bool { flipped.contains(id) != defaultOpen }

    private func toggle(_ id: String, defaultOpen: Bool = true) {
        var set = flipped
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        withAnimation(.smooth(duration: 0.25)) { collapsedRaw = set.sorted().joined(separator: "\n") }
    }

    private func setAll(expanded: Bool) {
        let keep = flipped.filter { $0.hasPrefix("c:") }
        let universes = expanded ? [] : vault.cosmos.universes.map(\.id)
        withAnimation(.smooth(duration: 0.25)) { collapsedRaw = (keep.sorted() + universes).joined(separator: "\n") }
    }
}

// MARK: - Pieces

/// A soft card inside the glass panel (glass on glass looks muddy).
private struct Card: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int
    let compact: Bool

    var body: some View {
        HStack(spacing: 4) {
            if !compact { Text(title + ":") }
            Text("\(count)").fontWeight(.semibold).foregroundStyle(Theme.ink.opacity(0.8))
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: compact ? .infinity : nil, alignment: compact ? .center : .leading)
        .padding(.leading, compact ? 0 : 6)
    }
}

/// A row of the menu: an icon in a little white circle and a title; the selected one is a red band, edge to edge.
private struct MenuRow: View {
    let icon: String
    let title: String
    let selected: Bool
    let compact: Bool
    var plain = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundIcon(icon: icon, selected: selected, plain: plain)
                if !compact {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(selected ? Color.white : Theme.ink.opacity(hover ? 1 : 0.88))
            .padding(.horizontal, compact ? 0 : 18)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: compact ? .center : .leading)
            .background(SelectionBand(selected: selected, hover: hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip(compact ? title : "")              // the folded rail shows only icons
    }
}

/// An icon in a small filled circle, as in the reference (plain: just the glyph).
struct RoundIcon: View {
    let icon: String
    var selected = false
    var plain = false

    var body: some View {
        Group {
            if plain {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Theme.ink.opacity(0.9))
            } else {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected ? Theme.accent : Theme.ground)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(selected ? Color.white : Theme.ink.opacity(0.82)))
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// The selection: a red band across the whole panel; hover is a faint light band.
struct SelectionBand: View {
    let selected: Bool
    let hover: Bool

    var body: some View {
        Rectangle()
            .fill(selected ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                           : AnyShapeStyle(Color.white.opacity(hover ? 0.05 : 0)))
            .shadow(color: selected ? Theme.accent.opacity(0.35) : .clear, radius: 8)
    }
}

/// A thin line that fades out at both ends.
struct GlowDivider: View {
    var body: some View {
        LinearGradient(colors: [.clear, Color.white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .padding(.horizontal, 22)
    }
}

/// "МЕНЮ", "ВСЕЛЕННЫЕ", "ОБЩЕЕ".
private struct SectionLabel: View {
    let title: String
    let compact: Bool

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: compact ? 9.5 : 12.5, weight: .semibold))
            .tracking(compact ? 0.3 : 0.6)
            .foregroundStyle(Theme.ink.opacity(0.7))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: compact ? .infinity : nil, alignment: compact ? .center : .leading)
            .padding(.leading, compact ? 0 : 18)
            .padding(.top, 10).padding(.bottom, 6)
    }
}

/// The vault's round avatar: its first letter (or emoji) on a soft red glow.
private struct VaultAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let first = name.first.map(String.init) ?? "S"
        Text(first)
            .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(RadialGradient(colors: [Theme.accent.opacity(0.95), Theme.accent.opacity(0.55), Color(hex: 0x4A1512)],
                                                     center: .init(x: 0.4, y: 0.35), startRadius: 1, endRadius: size * 0.7)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
            .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 2)
    }
}

/// A small square icon button for the explorer toolbar.
private struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13))
                .frame(width: 28, height: 26)
                .background(Circle().fill(Color.white.opacity(hover ? 0.08 : 0)).frame(width: 26, height: 26))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hover ? Theme.ink : Theme.muted)
        .onHover { hover = $0 }
        .tip(help)
    }
}

/// One line of the cascading tree. Each level is indented and hangs on a thin guide line,
/// so you can always see what belongs to what.
private struct TreeRow<Label: View>: View {
    let level: Int
    let expandable: Bool
    let expanded: Bool
    let selected: Bool
    var tint: Color = Theme.ink
    let count: Int?
    let onToggle: () -> Void
    let onTap: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            // Guide lines for every level above this one.
            HStack(spacing: 0) {
                ForEach(0..<level, id: \.self) { _ in
                    Rectangle().fill(Color.white.opacity(selected ? 0.25 : 0.08)).frame(width: 1).frame(width: 16)
                }
            }
            if expandable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(selected ? Color.white : Theme.muted)
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
            }
            label()
            Spacer(minLength: 6)
            if let count {
                // Counts as small round badges.
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 18)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(selected ? Color.white : Theme.ink.opacity(hover ? 1 : 0.85))
        .padding(.leading, 16).padding(.trailing, 14)
        .frame(minHeight: 31)
        .background(SelectionBand(selected: selected, hover: hover))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.15), value: hover)
    }
}

/// The colour dot of a universe. Clicking it opens the colour picker.
private struct UniverseDot: View {
    let universe: Cosmos.Universe
    @State private var picking = false

    var body: some View {
        let colors = UniverseColors.shared
        Circle()
            .fill(colors.color(for: universe.id))
            .frame(width: 10, height: 10)
            .shadow(color: colors.color(for: universe.id).opacity(0.6), radius: 4)
            .frame(width: 16, height: 16)
            .contentShape(Circle())
            .onTapGesture { picking = true }
            .tip("Цвет вселенной")
            .popover(isPresented: $picking, arrowEdge: .trailing) {
                ColorGrid(universeID: universe.id) { picking = false }
            }
    }
}

/// A grid of swatches; white is the default.
private struct ColorGrid: View {
    let universeID: String
    let done: () -> Void

    var body: some View {
        let colors = UniverseColors.shared
        let current = colors.hex(for: universeID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Цвет вселенной").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 10), count: 4), spacing: 10) {
                ForEach(UniverseColors.swatches) { s in
                    Button {
                        withAnimation(.smooth) { colors.set(s.hex, for: universeID) }
                        done()
                    } label: {
                        Circle().fill(Color(hex: s.hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Color.white.opacity(current == s.hex ? 0.9 : 0), lineWidth: 2).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .help(s.name)                     // in a popover: the system tag
                }
            }
        }
        .padding(16)
    }
}

/// Folded sidebar: a universe is just its glowing dot.
private struct CompactUniverse: View {
    let universe: Cosmos.Universe
    let action: () -> Void

    var body: some View {
        let color = Theme.color(forUniverse: universe.id)
        Button(action: action) {
            Circle().fill(color)
                .frame(width: 12, height: 12)
                .shadow(color: color.opacity(0.7), radius: 5)
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip("\(universe.name) · \(universe.starCount)")
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

/// A coloured circle for menus. Menus draw SF Symbols in one colour, so this is a real (non-template) image.
@MainActor
func swatchImage(_ hex: UInt32) -> Image {
    let size: CGFloat = 14
    #if os(macOS)
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSColor(Color(hex: hex)).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)); ring.lineWidth = 1; ring.stroke()
        return true
    }
    img.isTemplate = false
    return Image(nsImage: img)
    #else
    let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
        UIColor(Color(hex: hex)).setFill()
        UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: size - 2, height: size - 2)).fill()
    }.withRenderingMode(.alwaysOriginal)
    return Image(uiImage: img)
    #endif
}

/// What the "delete" confirmation is about.
private struct DeleteTarget {
    enum Kind { case universe, constellation, folder, star }
    let kind: Kind
    let name: String
    /// Path inside the vault.
    let path: String
    let stars: Int

    var question: String {
        switch kind {
        case .universe: "Удалить вселенную «\(name)»?"
        case .constellation: "Удалить созвездие «\(name)»?"
        case .folder: "Удалить папку «\(name)»?"
        case .star: "Удалить звезду «\(name)»?"
        }
    }

    var action: String {
        switch kind {
        case .universe: "Удалить вселенную"
        case .constellation: "Удалить созвездие"
        case .folder: "Удалить папку"
        case .star: "Удалить звезду"
        }
    }

    var detail: String {
        let what = switch kind {
        case .universe, .constellation, .folder: stars == 0 ? "Папка пустая." : "Внутри \(stars) \(plural(stars, "звезда", "звезды", "звёзд")) — они уйдут вместе с папкой."
        case .star: "Файл заметки."
        }
        return what + " Всё переместится в Корзину — оттуда можно вернуть."
    }
}

/// A folder row in the explorer: a place to drop notes and folders into (it lights up), and itself draggable.
private struct FolderRowDrag: ViewModifier {
    /// The folder inside the vault ("" is the vault's root, i.e. "Входящие").
    let path: String
    let draggable: Bool
    let title: String
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let isTarget = workspace.drag?.folder == path
        content
            .overlay {
                if isTarget {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accent.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                        .padding(.horizontal, 6)
                        .allowsHitTesting(false)
                }
            }
            .animation(.smooth(duration: 0.12), value: isTarget)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { workspace.folderFrames[path] = $0 }
            .onDisappear { workspace.folderFrames[path] = nil }
            .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { v in
                    guard draggable else { return }
                    if workspace.drag == nil {
                        workspace.beginDrag("folder:" + path, title: title, icon: "folder", at: v.location)
                    } else {
                        workspace.moveDrag(to: v.location)
                    }
                }
                .onEnded { _ in if draggable { workspace.endDrag() } })
    }
}

private struct OptionalRootDrop: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.modifier(FolderRowDrag(path: "", draggable: false, title: "Входящие")) } else { content }
    }
}

/// A round button of the vault bar; it fills with light under the pointer (red for closing the vault).
private struct BarButton: View {
    let icon: String
    let help: String
    var destructive = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hover ? (destructive ? Color.white : Theme.ground) : Theme.ink.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(Circle().fill(hover ? (destructive ? Theme.accent : Theme.ink.opacity(0.9)) : Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hover ? 0 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.15), value: hover)
        .tip(help)
    }
}

import SwiftUI

/// Plain markdown editing for now (a TextKit 2 editor with live styling comes next).
/// Saves automatically shortly after you stop typing.
struct NoteView: View {
    let noteID: String
    /// A page that is not a note of the vault (the dashboard): read and saved straight from this file,
    /// shown without the location and title, and without the note-only tools.
    var file: URL? = nil

    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var map
    @Environment(\.paneID) private var paneID
    @Environment(Workspace.self) private var workspace
    @State private var text = ""
    @State private var lastSaved = ""
    @State private var saveTask: Task<Void, Never>?
    /// The links panel on the right: closed until you open it, then remembered.
    @AppStorage("space.showOrbit") private var showOrbit = false
    @State private var editor = EditorState()
    /// Source mode shows all Markdown syntax; live preview (default) hides it outside the current line.
    @AppStorage("space.sourceMode") private var sourceMode = false
    /// The properties panel above the text, put away for all notes from the note's tools.
    @AppStorage("space.propertiesHidden") private var hideProperties = false

    var body: some View {
        let cosmos = vault.cosmos
        let titles = cosmos.notes.values.map(\.title).sorted()
        let known = Set(titles.map { $0.lowercased() })
        let wide = PageWidth.isWide(text)
        HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                if file == nil {
                    Text(location.uppercased())
                        .font(Theme.mono(11)).kerning(1).foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer()
                noteTools
            }
            if file == nil {
                Text(cosmos.title(noteID))
                    .font(.system(size: 38, weight: .semibold, design: .serif))
            }
            MarkdownEditor(text: $text,
                           revealAll: sourceMode,
                           titles: titles,
                           resolves: { known.contains(Self.bareTitle($0).lowercased()) },
                           onOpenLink: openLink,
                           state: editor,
                           hideProperties: hideProperties,
                           vault: vault)
                .overlay(alignment: .topLeading) { LinkSuggestions(state: editor) }
                .overlay(alignment: .topLeading) { SlashMenu(state: editor) }
                .overlay(alignment: .topLeading) { SelectionBar(state: editor) }
                .animation(.easeOut(duration: 0.12), value: editor.linkQuery == nil)
                .animation(.easeOut(duration: 0.12), value: editor.slashVisible)
                .animation(.easeOut(duration: 0.1), value: editor.selectionRect == nil)
                #if os(macOS)
                // The editor keeps a gutter on both sides for the block handles; text stays in line with the title.
                .padding(.horizontal, -44)
                #endif
        }
        .padding(.horizontal, wide ? 28 : 32)
        .padding(.top, 18)
        .frame(maxWidth: wide ? .infinity : 760)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.25), value: wide)
            if showOrbit && file == nil {
                Rectangle().fill(Theme.line).frame(width: 1)
                NoteOrbitInspector(noteID: noteID)
                    .frame(width: 260)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: showOrbit)
        .background(SpaceBackground())
        .onAppear {
            text = file.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" } ?? vault.text(of: noteID)
            lastSaved = text
        }
        .onChange(of: text) { _, newValue in
            guard newValue != lastSaved else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                save(newValue)
            }
        }
        .onDisappear { flush() }
        // A quote sent from a book open next to this note.
        .onReceive(NotificationCenter.default.publisher(for: .spaceAppendToNote)) { n in
            guard n.userInfo?["id"] as? String == noteID, let add = n.userInfo?["text"] as? String else { return }
            let gap = text.isEmpty || text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
            text += gap + add
        }
    }

    /// The note's own tools, inside the note (not in the window toolbar) so every pane has its own.
    private var noteTools: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Жирный  ⌘B", systemImage: "bold") { editor.insertMarkup?("**", "**") }
                Button("Курсив  ⌘I", systemImage: "italic") { editor.insertMarkup?("*", "*") }
                Button("Зачёркнутый  ⌘⇧X", systemImage: "strikethrough") { editor.insertMarkup?("~~", "~~") }
                Button("Выделение  ⌘⇧H", systemImage: "highlighter") { editor.insertMarkup?("==", "==") }
                Button("Код", systemImage: "chevron.left.forwardslash.chevron.right") { editor.insertMarkup?("`", "`") }
                Divider()
                Button("Ссылка на звезду  ⌘K", systemImage: "link") { editor.insertMarkup?("[[", "]]") }
                Button("Задача", systemImage: "checkmark.square") { editor.insertMarkup?("- [ ] ", "") }
                Button("Цитата", systemImage: "text.quote") { editor.insertMarkup?("> ", "") }
                Button("Выноска", systemImage: "exclamationmark.bubble") { editor.insertMarkup?("> [!note] ", "") }
            } label: {
                Image(systemName: "textformat").frame(width: 26, height: 24)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .tip("Формат")
            tool(sourceMode ? "chevron.left.forwardslash.chevron.right" : "eye",
                 sourceMode ? "Источник — вся разметка видна" : "Просмотр — разметка видна только в текущей строке") { sourceMode.toggle() }
            if Properties.frontmatter(in: text as NSString) != nil {
                tool(hideProperties ? "list.bullet.rectangle" : "list.bullet.rectangle.fill",
                     hideProperties ? "Показать свойства" : "Скрыть свойства") { hideProperties.toggle() }
            }
            tool(PageWidth.isWide(text) ? "arrow.right.and.line.vertical.and.arrow.left" : "arrow.left.and.right",
                 PageWidth.isWide(text) ? "Обычная ширина" : "Во всю ширину") {
                if let changed = PageWidth.setting(text, wide: !PageWidth.isWide(text)) { text = changed }
            }
            if file == nil {
                tool("sparkles", "Показать на карте") {
                    workspace.focus(id: paneID)
                    flush()
                    map.pendingStar = noteID
                    vault.selection = .map
                }
                tool("sidebar.right", "Орбита: связи заметки") { showOrbit.toggle() }
            }
        }
        .foregroundStyle(Theme.muted)
    }

    private func tool(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(help)
    }

    private var location: String {
        let c = vault.cosmos
        let u = c.universeOf[noteID].flatMap { c.universe($0)?.name } ?? ""
        let k = c.constellationOf[noteID].flatMap { c.constellationName[$0] } ?? ""
        return "\(u) › \(k)"
    }

    private func save(_ value: String) {
        if let file {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try value.write(to: file, atomically: true, encoding: .utf8)
            } catch { vault.errorMessage = "Не удалось сохранить: \(error.localizedDescription)" }
        } else {
            vault.save(noteID, text: value)
        }
        lastSaved = value
    }

    /// Click on [[Title]]: open that star, or create it next to this one if it doesn't exist yet (like Obsidian).
    /// "Book.pdf#page=3" → "Book"; "Note.md" → "Note".
    static func bareTitle(_ link: String) -> String {
        var t = link
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        if t.lowercased().hasSuffix(".pdf") { t.removeLast(4) }
        if t.lowercased().hasSuffix(".md") { t.removeLast(3) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func openLink(_ link: String) {
        workspace.focus(id: paneID)          // the link opens in the pane this note is in
        flush()
        let c = vault.cosmos
        let title = Self.bareTitle(link)
        if let id = c.notes.values.first(where: { $0.title.lowercased() == title.lowercased() })?.id {
            if Books.isBook(id) {
                // "#page=N&q=words": the book opens at that page and finds the quote there.
                if let r = link.range(of: "#page="), let page = Int(link[r.upperBound...].prefix(while: \.isNumber)) {
                    vault.bookPage[id] = page
                }
                if let r = link.range(of: "&q=") {
                    vault.bookFind[id] = String(link[r.upperBound...]).components(separatedBy: "&").first
                }
                // Next to the note (or where the book already is), not instead of the note.
                if !workspace.reveal(.note(id)) { workspace.openToTheSide(.note(id)) }
            }
            vault.selection = .note(id)
            return
        }
        guard !link.lowercased().contains(".pdf") else {
            vault.errorMessage = "Книга «\(title)» не найдена в хранилище."
            return
        }
        let universe = c.universeOf[noteID] ?? ""
        let constellation = c.constellationOf[noteID].flatMap { c.constellationName[$0] } ?? ""
        Task {
            do { try await vault.createStar(titled: title, inUniverse: universe, constellation: constellation) }
            catch { vault.errorMessage = error.localizedDescription }
        }
    }

    private func flush() {
        saveTask?.cancel()
        if text != lastSaved { save(text) }
    }
}

/// Right-hand "Орбита": what this note links to and what links back.
struct NoteOrbitInspector: View {
    let noteID: String
    @Environment(VaultStore.self) private var vault

    var body: some View {
        let c = vault.cosmos
        let back = Set(c.backlinks(to: noteID))
        let outgoing = (c.neighbors[noteID] ?? []).subtracting(back).sorted { c.title($0) < c.title($1) }
        List {
            Section("Входящие связи · \(back.count)") {
                ForEach(back.sorted { c.title($0) < c.title($1) }, id: \.self) { row($0) }
            }
            Section("Ссылки отсюда · \(outgoing.count)") {
                ForEach(outgoing, id: \.self) { row($0) }
            }
            if let tags = c.notes[noteID]?.tags, !tags.isEmpty {
                Section("Теги") {
                    Text(tags.map { "#" + $0 }.joined(separator: "  ")).foregroundStyle(Theme.muted)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ id: String) -> some View {
        let c = vault.cosmos
        return Button { vault.selection = .note(id) } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Theme.color(forUniverse: c.universeOf[id]))
                    .frame(width: 8, height: 8)
                Text(c.title(id)).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

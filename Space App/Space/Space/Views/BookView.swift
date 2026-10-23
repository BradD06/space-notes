import SwiftUI

extension Notification.Name {
    /// Appends Markdown to an open note: userInfo ["id": note id, "text": markdown].
    static let spaceAppendToNote = Notification.Name("space.appendToNote")
}

/// A book of the vault (a PDF file) is a star too. It opens in a tab like a note.
nonisolated enum Books {
    static func isBook(_ id: String) -> Bool { id.lowercased().hasSuffix(".pdf") }
}

#if os(macOS)
import AppKit
import PDFKit

/// What the book view shows: the document, where you are, the search and the selection.
@MainActor
@Observable
final class BookModel {
    var page = 1
    var pageCount = 0
    var hasSelection = false
    var query = ""
    var matches: [PDFSelection] = []
    var matchIndex = 0
    var toast: String?
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored var outline: [(title: String, destination: PDFDestination?)] = []

    func go(toPage n: Int) {
        guard let view = pdfView, let doc = view.document, n >= 1, n <= doc.pageCount, let p = doc.page(at: n - 1) else { return }
        view.go(to: p)
    }

    func search() {
        guard let view = pdfView, let doc = view.document else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { matches = []; view.highlightedSelections = nil; return }
        if matches.isEmpty || matches.first?.string?.lowercased() != q.lowercased() {
            matches = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
            matches.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.45) }
            view.highlightedSelections = matches
            matchIndex = -1
        }
        guard !matches.isEmpty else { show("Не найдено"); return }
        matchIndex = (matchIndex + 1) % matches.count
        view.setCurrentSelection(matches[matchIndex], animate: true)
        view.scrollSelectionToVisible(nil)
    }

    /// Finds the quote's words on its page (or the nearest page that has them) and lights them up.
    func reveal(_ words: String, near page: Int) {
        guard let view = pdfView, let doc = view.document else { return }
        let q = words.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return }
        let hits = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        let onPage: (PDFSelection) -> Int = { sel in sel.pages.first.map { doc.index(for: $0) + 1 } ?? 0 }
        guard let best = hits.min(by: { abs(onPage($0) - page) < abs(onPage($1) - page) }) else { return }
        best.color = NSColor.systemYellow.withAlphaComponent(0.55)
        view.highlightedSelections = [best]
        view.setCurrentSelection(best, animate: true)
        view.scrollSelectionToVisible(nil)
        // The light fades after a while; the selection stays, ready to copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak view] in view?.highlightedSelections = nil }
    }

    func show(_ message: String) {
        withAnimation(.smooth) { toast = message }
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard self?.toast == shown else { return }
            withAnimation(.smooth) { self?.toast = nil }
        }
    }
}

/// A PDF book: pages to scroll, search, contents, zoom, and "quote into the note" open next to it.
struct BookView: View {
    let bookID: String
    @Environment(VaultStore.self) private var vault
    @Environment(Workspace.self) private var workspace
    @Environment(\.paneID) private var paneID
    @State private var model = BookModel()
    /// The side panel with how far you got, the reading time and your notes on the book.
    @AppStorage("space.bookPanel") private var showPanel = true

    var body: some View {
        let cosmos = vault.cosmos
        HStack(spacing: 0) {
        VStack(spacing: 0) {
            // Full header when there's room, icons only in a narrow pane.
            ViewThatFits(in: .horizontal) {
                header(title: cosmos.title(bookID), compact: false)
                header(title: cosmos.title(bookID), compact: true)
            }
            if let url = vault.url(for: bookID) {
                PDFKitView(url: url, bookID: bookID, model: model, startPage: vault.bookPage[bookID],
                           startFind: vault.bookFind[bookID], onQuote: quote, onNewNote: newNote)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
            if showPanel {
                Rectangle().fill(Theme.line).frame(width: 1)
                BookPanel(bookID: bookID, model: model, openNote: openNote, newNote: blankNote)
                    .frame(width: 270)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: showPanel)
        .background(PaneBackdrop())
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear { DispatchQueue.main.async { vault.bookPage[bookID] = nil; vault.bookFind[bookID] = nil } }   // used already
        // A link like [[Book.pdf#page=42]] while the book is already open: jump there.
        .onChange(of: vault.bookPage[bookID]) { _, page in
            guard let page else { return }
            model.go(toPage: page)
            if let words = vault.bookFind[bookID] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { model.reveal(words, near: page) }
            }
            vault.bookPage[bookID] = nil
            vault.bookFind[bookID] = nil
        }
    }

    private func header(title: String, compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            if !compact {
                Image(systemName: "book.closed").foregroundStyle(Theme.muted)
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
            }

            if !model.outline.isEmpty {
                Menu {
                    ForEach(Array(model.outline.enumerated()), id: \.offset) { _, item in
                        Button(item.title) { if let d = item.destination { model.pdfView?.go(to: d) } }
                    }
                } label: {
                    Image(systemName: "list.bullet.indent").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .tip("Оглавление")
            }

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.muted)
                TextField("Поиск в книге", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: compact ? 80 : 130)
                    .onSubmit { model.search() }
                    .onChange(of: model.query) { model.matches = []; if model.query.isEmpty { model.pdfView?.highlightedSelections = nil } }
                if !model.matches.isEmpty {
                    Text("\(model.matchIndex + 1)/\(model.matches.count)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.08)))

            Text(compact ? "\(model.page)" : "\(model.page) / \(model.pageCount)")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .fixedSize()
                .tip("Страница \(model.page) из \(model.pageCount)")

            if compact { Spacer(minLength: 0) }
            HStack(spacing: 0) {
                tool("minus.magnifyingglass", "Мельче") { model.pdfView?.zoomOut(nil) }
                if !compact { tool("arrow.up.left.and.arrow.down.right", "По ширине") { model.pdfView?.autoScales = true } }
                tool("plus.magnifyingglass", "Крупнее") { model.pdfView?.zoomIn(nil) }
            }

            Button(action: newNote) {
                Label("Новая заметка", systemImage: "square.and.pencil")
                    .labelStyle(AdaptiveLabel(iconOnly: compact))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, compact ? 8 : 12).frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .foregroundStyle(model.hasSelection ? Theme.ink : Theme.muted)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!model.hasSelection)
            .tip("Новая заметка из выделенного: цитата, страница и ссылка обратно в книгу")

            Button(action: quote) {
                Label("В заметку", systemImage: "quote.opening")
                    .labelStyle(AdaptiveLabel(iconOnly: compact))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, compact ? 8 : 12).frame(height: 26)
                    .background(Capsule().fill(model.hasSelection ? Theme.accent : Color.white.opacity(0.08)))
                    .foregroundStyle(model.hasSelection ? Color.white : Theme.muted)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!model.hasSelection)
            .tip("Выделите текст в книге — он попадёт цитатой в заметку, открытую рядом")

            tool("sidebar.right", showPanel ? "Скрыть прогресс и заметки" : "Прогресс чтения и заметки по книге") { showPanel.toggle() }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func tool(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(help)
    }

    /// The selection as Markdown: a quote callout with a link back to its page that also finds the words there.
    private func selectedQuote() -> (markdown: String, page: Int, firstWords: String)? {
        guard let view = model.pdfView, let selection = view.currentSelection,
              let raw = selection.string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let doc = view.document
        let page = selection.pages.first.flatMap { doc?.index(for: $0) }.map { $0 + 1 } ?? model.page
        let title = vault.cosmos.title(bookID)
        let file = (bookID as NSString).lastPathComponent
        // Lines broken by the page layout join back into sentences; real paragraphs stay apart.
        let text = raw.replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // The anchor: the start of the quote's first line as it stands in the PDF, so the book can find it.
        let firstLine = raw.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let anchor = Self.words(firstLine, max: 48)
        let at = anchor.isEmpty ? "" : "&q=" + anchor
        var md = "> [!quote] \(title), с. \(page)\n"
        md += text.map { "> " + $0 }.joined(separator: "\n>\n")
        md += "\n> — [[\(file)#page=\(page)\(at)|\(title), с. \(page)]]\n"
        return (md, page, Self.words(text.first ?? "", max: 50))
    }

    /// The first words of a text, cut at a word boundary, without characters that would break a [[link]].
    private static func words(_ s: String, max: Int) -> String {
        let clean = s.components(separatedBy: CharacterSet(charactersIn: "[]|#&^\\/:*?\"<>")).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > max else { return clean }
        let cut = clean.prefix(max)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)])
    }

    /// The selected text as a quote into the note open next to the book.
    private func quote() {
        guard let q = selectedQuote() else { return }
        if let target = workspace.noteNextTo(paneID) {
            NotificationCenter.default.post(name: .spaceAppendToNote, object: nil, userInfo: ["id": target, "text": q.markdown])
            model.show("Цитата добавлена в «\(vault.cosmos.title(target))»")
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(q.markdown, forType: .string)
            model.show("Цитата скопирована — открой заметку рядом и вставь ⌘V")
        }
    }

    /// Opens one of the book's notes next to the book (in the note pane beside it, or a new one).
    private func openNote(_ id: String) {
        if let pane = workspace.notePane(besides: paneID) {
            workspace.focus(pane)
            workspace.openInNewTab(.note(id))
        } else {
            workspace.focus(id: paneID)
            workspace.openToTheSide(.note(id))
        }
        vault.selection = .note(id)
    }

    /// An empty note about the book, linked to it, opened next to it.
    private func blankNote() {
        let file = (bookID as NSString).lastPathComponent
        let folder = (bookID as NSString).deletingLastPathComponent
        let title = vault.cosmos.title(bookID)
        let text = "---\nsource: \"[[\(file)]]\"\npage: \(model.page)\ntags:\n  - книга\n---\nПо книге [[\(file)#page=\(model.page)|\(title), с. \(model.page)]]\n\n"
        do {
            let id = try vault.createNote(titled: "\(title) — заметки", inFolder: folder, text: text)
            Task {
                await vault.reload()
                openNote(id)
            }
        } catch {
            vault.errorMessage = error.localizedDescription
        }
    }

    /// A new note from the selection, next to the book: the book and page in its properties, the quote inside.
    private func newNote() {
        guard let q = selectedQuote() else { return }
        let file = (bookID as NSString).lastPathComponent
        let folder = (bookID as NSString).deletingLastPathComponent
        let title = q.firstWords.isEmpty ? "Цитата — с. \(q.page)" : q.firstWords
        let text = "---\nsource: \"[[\(file)]]\"\npage: \(q.page)\ntags:\n  - цитата\n---\n\(q.markdown)\n"
        do {
            let id = try vault.createNote(titled: title, inFolder: folder, text: text)
            Task {
                await vault.reload()
                // Into the note pane next to the book if there is one, else a new pane on the side.
                if let pane = workspace.notePane(besides: paneID) {
                    workspace.focus(pane)
                    workspace.openInNewTab(.note(id))
                } else {
                    workspace.focus(id: paneID)
                    workspace.openToTheSide(.note(id))
                }
                vault.selection = .note(id)
                model.show("Заметка «\(vault.cosmos.title(id))» создана")
            }
        } catch {
            vault.errorMessage = error.localizedDescription
        }
    }
}

/// The book's side panel: its cover, how much you've read, how long, and the notes you wrote about it.
private struct BookPanel: View {
    let bookID: String
    let model: BookModel
    let openNote: (String) -> Void
    let newNote: () -> Void
    @Environment(VaultStore.self) private var vault
    @State private var cover: NSImage?
    private let stats = BookStats.shared

    var body: some View {
        let c = vault.cosmos
        let s = stats.stat(bookID)
        let notes = c.backlinks(to: bookID).sorted { (c.notes[$0]?.modified ?? .distantPast) > (c.notes[$1]?.modified ?? .distantPast) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let cover {
                            Image(nsImage: cover).resizable().scaledToFill()
                        } else {
                            LinearGradient(colors: [Color(hex: 0x3A1D1C), Color(hex: 0x24304A)], startPoint: .top, endPoint: .bottom)
                                .overlay(Image(systemName: "book.closed").foregroundStyle(.white.opacity(0.6)))
                        }
                    }
                    .frame(width: 64, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.title(bookID)).font(.system(size: 14, weight: .semibold)).lineLimit(3)
                        Text("\(model.pageCount) стр.").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Прочитано").font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(Int((s.progress * 100).rounded()))%").font(.system(size: 20, weight: .bold, design: .rounded))
                    }
                    ProgressBar(value: s.progress)
                    Text("Страница \(model.page) из \(model.pageCount)" + (s.furthest > model.page ? " · дальше всего \(s.furthest)" : ""))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    if s.furthest > model.page + 1 {
                        Button { model.go(toPage: s.furthest) } label: {
                            Label("Продолжить с с. \(s.furthest)", systemImage: "arrow.forward")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                        .tip("Перейти к самой дальней странице, до которой вы дочитали")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Время чтения").font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.muted)
                    Text(BookStats.duration(s.seconds)).font(.system(size: 18, weight: .semibold, design: .rounded))
                    if let started = s.started {
                        Text("Начали \(RuDate.dayMonth(started))" +
                             (s.lastRead.map { " · последний раз \(RuDate.relative($0))" } ?? ""))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Заметки по книге · \(notes.count)").font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.muted)
                        Spacer()
                        Button(action: newNote) { Image(systemName: "plus").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted)
                            .tip("Новая заметка о книге рядом")
                    }
                    if notes.isEmpty {
                        Text("Пока нет. Выделите текст и нажмите «Новая заметка» или «В заметку» — заметки со ссылкой на книгу появятся здесь.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(notes, id: \.self) { id in
                        Button { openNote(id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.title(id)).font(.system(size: 12.5)).lineLimit(2)
                                    if let d = c.notes[id]?.modified {
                                        Text(RuDate.dayMonth(d, short: true)).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tip("Открыть заметку рядом с книгой")
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.never)
        .onAppear { loadCover() }
        .onChange(of: model.pageCount) { loadCover() }
    }

    private func loadCover() {
        guard cover == nil, let page = model.pdfView?.document?.page(at: 0) else { return }
        cover = page.thumbnail(of: CGSize(width: 128, height: 184), for: .cropBox)
    }
}

/// A slim reading bar in the accent colour.
struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [Theme.accent.opacity(0.75), Theme.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(value > 0 ? height : 0, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

/// A label that drops its title when space is short.
private struct AdaptiveLabel: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { HStack(spacing: 5) { configuration.icon; configuration.title.fixedSize() } }
    }
}

/// PDFKit's view, dark around the pages, remembering where you stopped in each book.
private struct PDFKitView: NSViewRepresentable {
    let url: URL
    let bookID: String
    let model: BookModel
    let startPage: Int?
    let startFind: String?
    let onQuote: () -> Void
    let onNewNote: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(bookID: bookID, model: model) }

    func makeNSView(context: Context) -> SpacePDFView {
        let view = SpacePDFView()
        view.onQuote = onQuote
        view.onNewNote = onNewNote
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = NSColor(white: 0.12, alpha: 1)
        model.pdfView = view
        if let doc = PDFDocument(url: url) {
            view.document = doc
            model.pageCount = doc.pageCount
            model.outline = Self.outline(of: doc)
            let saved = BookStats.shared.stat(bookID).page
            let start = startPage ?? max(1, min(saved, doc.pageCount))
            let find = startFind
            DispatchQueue.main.async {
                model.go(toPage: start)
                if let find { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.reveal(find, near: start) } }
            }
        }
        let nc = NotificationCenter.default
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)), name: .PDFViewSelectionChanged, object: view)
        context.coordinator.startTracking(view)
        return view
    }

    func updateNSView(_ view: SpacePDFView, context: Context) {
        view.onQuote = onQuote
        view.onNewNote = onNewNote
    }

    static func dismantleNSView(_ view: SpacePDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.stopTracking()
    }

    private static func outline(of doc: PDFDocument) -> [(title: String, destination: PDFDestination?)] {
        guard let root = doc.outlineRoot else { return [] }
        var items: [(String, PDFDestination?)] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                items.append((String(repeating: "   ", count: depth) + (child.label ?? "—"), child.destination))
                if depth < 1 { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return items
    }

    @MainActor
    final class Coordinator: NSObject {
        let bookID: String
        let model: BookModel
        var pageKey: String { "space.book.page." + bookID }
        /// Reading time: counted while the book is on screen in the active app and you've turned
        /// or scrolled a page in the last few minutes (an open book you walked away from doesn't count).
        private var timer: Timer?
        private var lastActivity = Date()
        private weak var view: PDFView?
        private static let tick: TimeInterval = 10
        private static let idle: TimeInterval = 180

        init(bookID: String, model: BookModel) {
            self.bookID = bookID
            self.model = model
        }

        @objc func pageChanged(_ n: Notification) {
            guard let view = n.object as? PDFView, let page = view.currentPage, let doc = view.document else { return }
            let number = doc.index(for: page) + 1
            model.page = number
            UserDefaults.standard.set(number, forKey: pageKey)
            BookStats.shared.reached(page: number, of: doc.pageCount, in: bookID)
            lastActivity = Date()
        }

        func startTracking(_ view: PDFView) {
            self.view = view
            lastActivity = Date()
            if let clip = view.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: clip)
            }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.count() }
            }
        }

        func stopTracking() {
            timer?.invalidate()
            timer = nil
        }

        @objc func scrolled(_ n: Notification) { lastActivity = Date() }

        private func count() {
            guard NSApp.isActive, let window = view?.window, window.isVisible,
                  window.occlusionState.contains(.visible),
                  Date().timeIntervalSince(lastActivity) < Self.idle else { return }
            BookStats.shared.addReading(Self.tick, to: bookID)
        }

        @objc func selectionChanged(_ n: Notification) {
            guard let view = n.object as? PDFView else { return }
            model.hasSelection = !(view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            lastActivity = Date()
        }
    }
}

/// PDFView with "Цитата в заметку" on top of its right-click menu.
final class SpacePDFView: PDFView {
    var onQuote: (() -> Void)?
    var onNewNote: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let s = currentSelection?.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(ActionItem("Новая заметка из цитаты", symbol: "square.and.pencil") { [weak self] in self?.onNewNote?() }, at: 0)
            menu.insertItem(ActionItem("Цитата в заметку", symbol: "quote.opening") { [weak self] in self?.onQuote?() }, at: 0)
        }
        return menu
    }
}
#else
struct BookView: View {
    let bookID: String
    var body: some View {
        ContentUnavailableView("Книги пока открываются на Mac", systemImage: "book.closed")
    }
}
#endif

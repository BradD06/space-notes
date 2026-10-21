import SwiftUI
import WebKit
#if os(macOS)
import AppKit
import QuickLookUI
#else
import UIKit
import QuickLook
#endif

/// A document of the vault that is neither a note nor a book: text and code (edited as text), CSV tables,
/// RTF (edited in place), Word and OpenDocument pages, HTML, EPUB books, and anything else Quick Look can show.
struct DocumentView: View {
    let docID: String

    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var map
    @Environment(Workspace.self) private var workspace
    @Environment(\.paneID) private var paneID
    @State private var content: Content = .loading
    /// Tables and web pages: their text instead of the table or the page.
    @State private var showSource = false
    /// Bumped after a reload from disk, so the views below start over with the new contents.
    @State private var version = 0
    @State private var draft = DocumentDraft()

    enum Content {
        case loading
        case text(String)
        case rich(NSAttributedString, editable: Bool)
        case web(URL, source: String?)
        case epub(EPUBBook)
        case preview(URL)
        case failed(String)
    }

    private var ext: String { (docID as NSString).pathExtension.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Group {
                switch content {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let text):
                    if Documents.kind(of: docID) == .table && !showSource {
                        DocumentTable(rows: Documents.rows(of: text, separator: ext == "tsv" ? "\t" : ","))
                    } else {
                        textEditor(text)
                    }
                case .rich(let string, let editable):
                    DocumentTextView(initial: string, rich: true, editable: editable, monospaced: false, onEdit: edited)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                case .web(let url, let source):
                    if showSource, let source {
                        textEditor(source)
                    } else {
                        DocumentWebView(url: url, readAccess: vault.rootURL ?? url.deletingLastPathComponent())
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                case .epub(let book):
                    EPUBReader(book: book, docID: docID)
                case .preview(let url):
                    QuickLookView(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .failed(let message):
                    ContentUnavailableView("Не удалось открыть", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .id(version)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .background(SpaceBackground())
        .task { await load() }
        .onDisappear { flush() }
    }

    // MARK: Header

    private var header: some View {
        let c = vault.cosmos
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(location.uppercased())
                    .font(Theme.mono(11)).kerning(1).foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer()
                tools
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(c.title(docID))
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .lineLimit(2)
                Text(ext.uppercased())
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                if let note = status {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// "Только чтение", or the text's encoding when it isn't UTF-8.
    private var status: String? {
        let encoding = draft.encoding == .utf8 ? nil : String.localizedName(of: draft.encoding)
        switch content {
        case .text: return encoding
        case .web(_, let source): return showSource && source != nil ? encoding : "Только чтение"
        case .rich(_, let editable): return editable ? nil : "Только чтение"
        case .epub, .preview: return "Только чтение"
        case .loading, .failed: return nil
        }
    }

    private var tools: some View {
        HStack(spacing: 2) {
            switch content {
            case .text where Documents.kind(of: docID) == .table:
                tool(showSource ? "tablecells" : "text.alignleft", showSource ? "Показать таблицей" : "Править как текст") { toggleSource() }
            case .web(_, source: _?):
                tool(showSource ? "globe" : "chevron.left.forwardslash.chevron.right",
                     showSource ? "Показать страницу" : "Править HTML-код") { toggleSource() }
            default:
                EmptyView()
            }
            if let url = vault.url(for: docID) {
                #if os(macOS)
                tool("arrow.up.forward.app", "Открыть в другом приложении") { NSWorkspace.shared.open(url) }
                #else
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 26, height: 24) }
                    .buttonStyle(.plain)
                #endif
            }
            tool("sparkles", "Показать на карте") {
                workspace.focus(id: paneID)
                flush()
                map.pendingStar = docID
                vault.selection = .map
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
        let u = c.universeOf[docID].flatMap { c.universe($0)?.name } ?? ""
        let k = c.constellationOf[docID].flatMap { c.constellationName[$0] } ?? ""
        return "\(u) › \(k)"
    }

    private func textEditor(_ text: String) -> some View {
        DocumentTextView(initial: NSAttributedString(string: text), rich: false, editable: true,
                         monospaced: !Documents.proseExtensions.contains(ext), onEdit: edited)
    }

    // MARK: Loading and saving

    private func load() async {
        guard let url = vault.url(for: docID) else { content = .failed("Хранилище не открыто."); return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        switch Documents.kind(of: docID) {
        case .text?, .table?:
            // Very large or binary files: Quick Look shows them without loading everything into an editor.
            if size < 20_000_000, let read = Documents.readText(at: url) {
                draft.encoding = read.encoding
                content = .text(read.text)
            } else {
                content = .preview(url)
            }
        case .rich?:
            if let type = Self.richType(ext),
               let string = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) {
                content = .rich(string, editable: ext == "rtf" || ext == "rtfd")
            } else {
                content = .preview(url)
            }
        case .web?:
            let read = ext == "webarchive" ? nil : Documents.readText(at: url)
            if let read { draft.encoding = read.encoding }
            content = .web(url, source: read?.text)
        case .epub?:
            do {
                content = .epub(try await Task.detached(priority: .userInitiated) { try EPUBBook.open(url) }.value)
            } catch {
                content = .failed(error.localizedDescription)
            }
        case .preview?, nil:
            content = .preview(url)
        }
    }

    /// How NSAttributedString reads this kind of file. Word and OpenDocument only on the Mac; on iPhone and iPad
    /// they go to Quick Look.
    private static func richType(_ ext: String) -> NSAttributedString.DocumentType? {
        switch ext {
        case "rtf": .rtf
        case "rtfd": .rtfd
        #if os(macOS)
        case "docx": .officeOpenXML
        case "doc": .docFormat
        case "odt": .openDocument
        case "wordml": .wordML
        #endif
        default: nil
        }
    }

    private func toggleSource() {
        flush()
        showSource.toggle()
        Task {
            await load()
            version += 1
        }
    }

    private func edited(_ value: NSAttributedString) {
        draft.latest = value
        draft.saveTask?.cancel()
        draft.saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        draft.saveTask?.cancel()
        guard let value = draft.latest else { return }
        draft.latest = nil
        let range = NSRange(location: 0, length: value.length)
        if case .rich = content, ext == "rtfd" {
            vault.saveDocument(docID) { url in
                let wrapper = try value.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            }
        } else if case .rich = content {
            vault.saveDocument(docID) { url in
                try value.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url, options: .atomic)
            }
        } else {
            // Saved back in the encoding it came in, unless the new text doesn't fit it.
            let text = value.string
            if !text.canBeConverted(to: draft.encoding) { draft.encoding = .utf8 }
            let encoding = draft.encoding
            vault.saveDocument(docID) { try text.write(to: $0, atomically: true, encoding: encoding) }
        }
    }
}

/// What is typed but not saved yet. A class, so typing doesn't redraw the view.
@MainActor
final class DocumentDraft {
    var latest: NSAttributedString?
    var encoding: String.Encoding = .utf8
    var saveTask: Task<Void, Never>?
}

// MARK: - Table

/// A CSV / TSV file as a table: the first row as the header, pinned on top.
private struct DocumentTable: View {
    let rows: [[String]]
    private static let limit = 5000

    var body: some View {
        let widths = Self.widths(rows)
        let shown = rows.prefix(Self.limit)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(shown.enumerated()).dropFirst(), id: \.offset) { i, row in
                        line(row, widths: widths)
                            .background(i % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                    }
                    if rows.count > Self.limit {
                        Text("Показаны первые \(Self.limit) строк из \(rows.count)")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(10)
                    }
                } header: {
                    if let first = rows.first {
                        line(first, widths: widths)
                            .font(.system(size: 12, weight: .semibold))
                            .background(Theme.surfaceHigh)
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink)
            .textSelection(.enabled)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if rows.isEmpty { ContentUnavailableView("Пустая таблица", systemImage: "tablecells") }
        }
    }

    private func line(_ row: [String], widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(widths.indices, id: \.self) { col in
                Text(col < row.count ? row[col] : "")
                    .lineLimit(3)
                    .frame(width: widths[col], alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
            }
        }
        .fixedSize()
    }

    /// Each column as wide as its longer cells (judging by the first rows), within sane bounds.
    private static func widths(_ rows: [[String]]) -> [CGFloat] {
        var chars: [Int] = []
        for row in rows.prefix(200) {
            for (i, cell) in row.enumerated() {
                if i >= chars.count { chars.append(0) }
                chars[i] = max(chars[i], cell.count)
            }
        }
        return chars.map { min(320, max(48, CGFloat($0) * 7.2)) }
    }
}

// MARK: - EPUB

/// An EPUB book chapter by chapter, remembering where you stopped.
private struct EPUBReader: View {
    let book: EPUBBook
    let docID: String
    @State private var chapter = 0

    var body: some View {
        VStack(spacing: 10) {
            DocumentWebView(url: book.chapters[chapter].url, readAccess: book.folder)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                Button { go(chapter - 1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 26) }
                    .disabled(chapter == 0)
                    .tip("Предыдущая глава")
                Menu {
                    ForEach(book.chapters.indices, id: \.self) { i in
                        Button(book.chapters[i].title) { go(i) }
                    }
                } label: {
                    Text(book.chapters[chapter].title).lineLimit(1).font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .tip("Оглавление")
                Text("\(chapter + 1) / \(book.chapters.count)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                Button { go(chapter + 1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 26) }
                    .disabled(chapter >= book.chapters.count - 1)
                    .tip("Следующая глава")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .onAppear {
            chapter = min(max(0, UserDefaults.standard.integer(forKey: key)), book.chapters.count - 1)
        }
    }

    private var key: String { "space.epub.chapter." + docID }

    private func go(_ i: Int) {
        guard book.chapters.indices.contains(i) else { return }
        chapter = i
        UserDefaults.standard.set(i, forKey: key)
    }
}

// MARK: - Platform views

#if os(macOS)

/// The system text view: plain text in the app's colours, or a white page of formatted text.
struct DocumentTextView: NSViewRepresentable {
    let initial: NSAttributedString
    let rich: Bool
    let editable: Bool
    let monospaced: Bool
    var onEdit: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = editable
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isRichText = rich
        tv.importsGraphics = rich
        tv.layoutManager?.allowsNonContiguousLayout = true
        if rich {
            // A page: the document's own colours on white, whatever the app's theme.
            scroll.appearance = NSAppearance(named: .aqua)
            scroll.drawsBackground = true
            scroll.backgroundColor = .white
            tv.drawsBackground = true
            tv.backgroundColor = .white
            tv.textContainerInset = NSSize(width: 48, height: 40)
            tv.textStorage?.setAttributedString(initial)
        } else {
            scroll.drawsBackground = false
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.isContinuousSpellCheckingEnabled = !monospaced
            let font = monospaced ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) : NSFont.systemFont(ofSize: 15)
            tv.font = font
            tv.textColor = NSColor(Theme.ink)
            tv.insertionPointColor = NSColor(Theme.accent)
            tv.typingAttributes = [.font: font, .foregroundColor: NSColor(Theme.ink)]
            tv.string = initial.string
        }
        tv.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentTextView
        init(_ parent: DocumentTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onEdit(tv.attributedString())
        }
    }
}

/// A web view for HTML files and EPUB chapters. Their scripts don't run.
struct DocumentWebView: NSViewRepresentable {
    let url: URL
    let readAccess: URL

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: Self.configuration())
        Self.load(url, readAccess: readAccess, in: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if web.url?.standardizedFileURL != url.standardizedFileURL { Self.load(url, readAccess: readAccess, in: web) }
    }
}

/// Quick Look, for what nothing else here opens (Pages, very large files…).
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

#else

/// The system text view: plain text in the app's colours, or a white page of formatted text.
struct DocumentTextView: UIViewRepresentable {
    let initial: NSAttributedString
    let rich: Bool
    let editable: Bool
    let monospaced: Bool
    var onEdit: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = editable
        tv.isFindInteractionEnabled = true
        tv.alwaysBounceVertical = true
        if rich {
            tv.overrideUserInterfaceStyle = .light
            tv.backgroundColor = .white
            tv.allowsEditingTextAttributes = true
            tv.textContainerInset = UIEdgeInsets(top: 28, left: 20, bottom: 28, right: 20)
            tv.attributedText = initial
        } else {
            tv.backgroundColor = .clear
            tv.autocorrectionType = .no
            tv.autocapitalizationType = .none
            tv.smartQuotesType = .no
            tv.smartDashesType = .no
            tv.spellCheckingType = monospaced ? .no : .default
            tv.font = monospaced ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 16)
            tv.textColor = UIColor(Theme.ink)
            tv.tintColor = UIColor(Theme.accent)
            tv.text = initial.string
        }
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DocumentTextView
        init(_ parent: DocumentTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.onEdit(tv.attributedText)
        }
    }
}

/// A web view for HTML files and EPUB chapters. Their scripts don't run.
struct DocumentWebView: UIViewRepresentable {
    let url: URL
    let readAccess: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: Self.configuration())
        Self.load(url, readAccess: readAccess, in: web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if web.url?.standardizedFileURL != url.standardizedFileURL { Self.load(url, readAccess: readAccess, in: web) }
    }
}

/// Quick Look, for what nothing else here opens (Word and Pages on iPhone and iPad, very large files…).
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

#endif

extension DocumentWebView {
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return config
    }

    static func load(_ url: URL, readAccess: URL, in web: WKWebView) {
        if url.pathExtension.lowercased() == "webarchive", let data = try? Data(contentsOf: url) {
            web.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: url)
        } else {
            web.loadFileURL(url, allowingReadAccessTo: readAccess)
        }
    }
}

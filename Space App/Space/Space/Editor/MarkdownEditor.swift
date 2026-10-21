import SwiftUI
import Observation

/// Shared state between the native text view and SwiftUI: the `[[` autocomplete popup.
@MainActor
@Observable
final class EditorState {
    var linkQuery: String?
    var suggestions: [String] = []
    var selectedSuggestion = 0
    /// Bottom-left of the caret in the editor's own coordinates (top-left origin).
    var caretPoint: CGPoint = .zero
    @ObservationIgnored var complete: ((String) -> Void)?
    @ObservationIgnored var insertMarkup: ((String, String) -> Void)?

    /// The "/" menu: what's typed after the slash, the matching block kinds and the highlighted one.
    var slashQuery: String?
    var slashItems: [BlockKind] = []
    var selectedSlash = 0
    @ObservationIgnored var chooseSlash: ((BlockKind) -> Void)?

    /// Where the selected text is (top-left of its first line and its width), for the formatting bar.
    var selectionRect: CGRect?
    @ObservationIgnored var turnInto: ((BlockKind) -> Void)?

    var slashVisible: Bool { slashQuery != nil && !slashItems.isEmpty }

    /// Pictures: the file picker from the note's tools, and what went wrong saving one.
    var pickingImage = false
    var mediaError: String?
    @ObservationIgnored var insertImages: (([URL]) -> Void)?
    /// `[text](https://…)` around the selection, with the address from the clipboard when it holds one.
    @ObservationIgnored var insertWebLink: (() -> Void)?
}

/// Obsidian-style Markdown editor: live preview, clickable [[links]] and checkboxes, pictures,
/// list continuation, `[[` autocomplete (notes, #headings, pictures after `![[`), ⌘B / ⌘I / ⌘K / ⌘⇧K.
struct MarkdownEditor {
    @Binding var text: String
    var revealAll: Bool
    var titles: [String]
    var resolves: (String) -> Bool
    var onOpenLink: (String) -> Void
    var state: EditorState
    /// The properties panel is put away: the frontmatter takes no room and nothing is drawn over it.
    var hideProperties: Bool = false
    /// The vault, for ```gallery blocks (their cards show the vault's notes and books).
    var vault: VaultStore? = nil
    /// The note's file: pictures are found from here and pasted ones are saved next to it.
    var noteURL: URL? = nil
    /// The note being edited, for ```dataview queries (`this`, `FROM [[]]`).
    var noteID: String? = nil
}

// MARK: - Logic shared by both platforms

@MainActor
final class EditorCoordinator: NSObject {
    var parent: MarkdownEditor
    var styler = MarkdownStyler()
    var lastActiveLine: NSRange?
    var lastRevealAll = false
    var lastHideProperties = false
    var suppressQueryUntilMove = false

    init(_ parent: MarkdownEditor) {
        self.parent = parent
        super.init()
    }

    /// `selection` nil means "nothing is being edited" (whole blocks are selected): no syntax is revealed.
    func restyle(_ storage: NSTextStorage, selection: NSRange?, force: Bool = false) {
        let ns = storage.string as NSString
        let line = ns.length == 0 || selection == nil ? NSRange(location: NSNotFound, length: 0)
            : ns.lineRange(for: NSRange(location: min(selection!.location, ns.length), length: min(selection!.length, ns.length - min(selection!.location, ns.length))))
        if !force, line == lastActiveLine, parent.revealAll == lastRevealAll, parent.hideProperties == lastHideProperties { return }
        lastHideProperties = parent.hideProperties
        styler.propertiesHidden = parent.hideProperties
        lastActiveLine = line
        lastRevealAll = parent.revealAll
        styler.resolves = parent.resolves
        let note = parent.noteURL, root = parent.vault?.rootURL
        styler.image = { ref in
            guard EditorImages.isImage(ref), let url = EditorImages.resolve(ref, note: note, root: root) else { return nil }
            return EditorImages.image(at: url)
        }
        if let c = storage.layoutManagers.first?.textContainers.first, c.size.width > 60 {
            styler.imageWidth = c.size.width - 2 * c.lineFragmentPadding - 8
        }
        #if os(macOS)
        let host = storage.layoutManagers.first?.firstTextView as? SpaceTextView
        styler.columnsEnabled = host != nil
        styler.columnHeights = host?.columnHeights ?? []
        styler.propertiesHeight = host?.propertiesHeight ?? 80
        styler.galleriesEnabled = host != nil && parent.vault != nil
        styler.galleryHeights = host?.galleryHeights ?? []
        styler.dataviewEnabled = host != nil && parent.vault != nil
        styler.dataviewHeights = host?.dataviewHeights ?? [:]
        #endif
        let blocks = styler.apply(to: storage, active: selection, revealAll: parent.revealAll)
        if let lm = storage.layoutManagers.first as? BlockLayoutManager {
            lm.blocks = blocks
            lm.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        }
        #if os(macOS)
        host?.syncColumns(blocks)
        host?.syncProperties(blocks)
        host?.syncGalleries(blocks)
        host?.syncDataviews(blocks)
        #endif
    }

    /// Handles our own link schemes. Returns true if the URL was ours.
    func handle(url: URL, toggleTask: (Int) -> Void) -> Bool {
        switch url.scheme {
        case MarkdownStyler.noteScheme:
            let raw = url.absoluteString.dropFirst(MarkdownStyler.noteScheme.count + 1)
            parent.onOpenLink(String(raw).removingPercentEncoding ?? String(raw))
            return true
        case MarkdownStyler.taskScheme:
            if let loc = Int(url.absoluteString.dropFirst(MarkdownStyler.taskScheme.count + 1)) { toggleTask(loc) }
            return true
        default:
            return false
        }
    }

    func updateQuery(text: NSString, selection: NSRange) {
        updateSlash(text: text, selection: selection)
        guard selection.length == 0, !suppressQueryUntilMove,
              let q = MarkdownEditing.linkQuery(in: text, caret: selection.location) else {
            if parent.state.linkQuery != nil { parent.state.linkQuery = nil }
            return
        }
        let embed = q.range.location >= 3 && text.character(at: q.range.location - 3) == 33     // "![["
        let list = linkSuggestions(for: q.query, embed: embed, text: text)
        if parent.state.linkQuery != q.query { parent.state.selectedSuggestion = 0 }
        parent.state.linkQuery = q.query
        parent.state.suggestions = list
    }

    var popupVisible: Bool { parent.state.linkQuery != nil && !parent.state.suggestions.isEmpty }

    /// Notes for `[[`, pictures first for `![[`, and the headings of a note after `[[Note#` (`[[#` is this note).
    func linkSuggestions(for query: String, embed: Bool, text: NSString) -> [String] {
        if let hash = query.firstIndex(of: "#") {
            let note = String(query[..<hash]), part = String(query[query.index(after: hash)...])
            let source = note.isEmpty ? text as String : noteText(titled: note)
            return MarkdownEditing.suggestions(for: part, in: MarkdownEditing.headings(in: source)).map { note + "#" + $0 }
        }
        let pool = embed ? EditorImages.names(root: parent.vault?.rootURL) + parent.titles : parent.titles
        return MarkdownEditing.suggestions(for: query, in: pool)
    }

    private func noteText(titled title: String) -> String {
        guard let vault = parent.vault,
              let id = vault.cosmos.notes.values.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })?.id else { return "" }
        return vault.text(of: id)
    }

    /// Saves the pictures next to the note; returns their embed names. Failures go to the editor's alert.
    func savePictures(_ urls: [URL], data: [(Data, String)]) -> [String] {
        var names: [String] = []
        do {
            for u in urls { names.append(try EditorImages.importFile(u, nextTo: parent.noteURL, root: parent.vault?.rootURL)) }
            for (d, ext) in data { names.append(try EditorImages.save(d, ext: ext, nextTo: parent.noteURL)) }
        } catch {
            parent.state.mediaError = VaultStore.isPermissionError(error)
                ? "Нет доступа на запись в папку заметки." : error.localizedDescription
        }
        return names
    }

    /// "/" typed at the start of a line (or after "+" in the gutter) opens the block menu.
    func updateSlash(text: NSString, selection: NSRange) {
        let state = parent.state
        guard state.chooseSlash != nil, selection.length == 0, !suppressQueryUntilMove,
              let q = Self.slashQuery(in: text, caret: selection.location) else {
            if state.slashQuery != nil { state.slashQuery = nil }
            return
        }
        let items = BlockKind.allCases.filter { $0.matches(q.query) }
        if state.slashQuery != q.query { state.selectedSlash = 0 }
        state.slashQuery = q.query
        state.slashItems = items
    }

    /// The "/word" right before the caret, if the line holds nothing else before it.
    static func slashQuery(in text: NSString, caret: Int) -> (query: String, range: NSRange)? {
        guard caret <= text.length, caret > 0 else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: caret - 1, length: 0)).location
        guard lineStart <= caret else { return nil }
        let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        guard before.range(of: #"^[ \t]*/[^\s/]{0,20}$"#, options: .regularExpression) != nil else { return nil }
        let slash = (before as NSString).range(of: "/", options: .backwards)
        let query = (before as NSString).substring(from: slash.location + 1)
        return (query, NSRange(location: lineStart + slash.location, length: caret - lineStart - slash.location))
    }
}

#if os(macOS)
import AppKit

extension MarkdownEditor: NSViewRepresentable {
    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let size = scroll.contentSize

        // TextKit 1 stack with our layout manager, which draws code boxes, tables and quote bars.
        let storage = NSTextStorage()
        let layout = BlockLayoutManager()
        layout.delegate = layout                 // hides spelling marks in Markdown that panels cover
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = SpaceTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        tv.minSize = NSSize(width: 0, height: size.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 44, height: 16)   // room on the left for the block handle

        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.insertionPointColor = EditorTheme().accent
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        tv.typingAttributes = EditorTheme().baseAttributes
        tv.selectedTextAttributes = [.backgroundColor: EditorTheme().accent.withAlphaComponent(0.25)]

        tv.string = text
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        scroll.documentView = tv

        state.complete = { [weak tv, weak coordinator = context.coordinator] title in
            guard let tv, let coordinator else { return }
            coordinator.complete(title, in: tv)
        }
        state.insertMarkup = { [weak tv] open, close in tv?.wrapSelection(open, close) }
        state.chooseSlash = { [weak tv, weak coordinator = context.coordinator] kind in
            guard let tv, let coordinator else { return }
            coordinator.chooseSlash(kind, in: tv)
        }
        state.turnInto = { [weak tv] kind in tv?.turnCaretBlock(into: kind) }
        state.insertImages = { [weak tv, weak coordinator = context.coordinator] urls in
            guard let tv, let coordinator else { return }
            coordinator.insertPictures(urls, in: tv)
        }
        state.insertWebLink = { [weak tv] in tv?.insertWebLink() }
        tv.installGutter()

        if let storage = tv.textStorage { context.coordinator.restyle(storage, selection: tv.selectedRange(), force: true) }
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            context.coordinator.restyle(storage, selection: tv.selectedRange(), force: true)
        } else if context.coordinator.lastRevealAll != revealAll || context.coordinator.lastHideProperties != hideProperties {
            context.coordinator.restyle(storage, selection: tv.selectedRange(), force: true)
        }
    }
}

extension EditorCoordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
        parent.text = tv.string
        parent.state.selectionRect = nil
        restyle(storage, selection: tv.selectedRange(), force: true)
        tv.typingAttributes = styler.theme.baseAttributes
        updateQuery(text: tv.string as NSString, selection: tv.selectedRange())
        updateCaret(tv)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
        if (tv as? SpaceTextView)?.hopOverColumns() == true { return }   // moved again: that change comes back here
        let wholeBlocks = (tv as? SpaceTextView)?.blockSelection != nil
        restyle(storage, selection: wholeBlocks ? nil : tv.selectedRange())
        suppressQueryUntilMove = false
        updateQuery(text: tv.string as NSString, selection: tv.selectedRange())
        updateCaret(tv)
        updateSelectionBar(tv)
    }

    /// The floating formatting bar follows a non-empty selection.
    func updateSelectionBar(_ tv: NSTextView) {
        let sel = tv.selectedRange()
        guard sel.length > 0, let window = tv.window, let scroll = tv.enclosingScrollView,
              (tv as? SpaceTextView)?.draggingBlock == nil, (tv as? SpaceTextView)?.blockSelection == nil else {
            if parent.state.selectionRect != nil { parent.state.selectionRect = nil }
            return
        }
        var actual = NSRange()
        let screen = tv.firstRect(forCharacterRange: sel, actualRange: &actual)
        let inScroll = scroll.convert(window.convertFromScreen(screen), from: nil)
        let top = scroll.isFlipped ? inScroll.minY : scroll.bounds.height - inScroll.maxY
        parent.state.selectionRect = CGRect(x: inScroll.minX, y: top, width: inScroll.width, height: inScroll.height)
    }

    func chooseSlash(_ kind: BlockKind, in tv: NSTextView) {
        let ns = tv.string as NSString
        guard let q = Self.slashQuery(in: ns, caret: tv.selectedRange().location) else { return }
        let snippet = kind.snippet
        replace(in: tv, range: q.range, with: snippet.text)
        tv.setSelectedRange(NSRange(location: q.range.location + snippet.caret, length: 0))
        parent.state.slashQuery = nil
        if kind == .columns {
            // Straight into the first column.
            let at = q.range.location
            DispatchQueue.main.async { (tv as? SpaceTextView)?.focusColumns(at: at) }
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        if handle(url: url, toggleTask: { self.toggleTask(at: $0, in: textView) }) { return true }
        NSWorkspace.shared.open(url)
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let state = parent.state
        if state.slashVisible {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                state.selectedSlash = min(state.selectedSlash + 1, state.slashItems.count - 1); return true
            case #selector(NSResponder.moveUp(_:)):
                state.selectedSlash = max(state.selectedSlash - 1, 0); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                chooseSlash(state.slashItems[state.selectedSlash], in: textView); return true
            case #selector(NSResponder.cancelOperation(_:)):
                suppressQueryUntilMove = true; state.slashQuery = nil; return true
            default: break
            }
        }
        if popupVisible {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                state.selectedSuggestion = min(state.selectedSuggestion + 1, state.suggestions.count - 1); return true
            case #selector(NSResponder.moveUp(_:)):
                state.selectedSuggestion = max(state.selectedSuggestion - 1, 0); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                complete(state.suggestions[state.selectedSuggestion], in: textView); return true
            case #selector(NSResponder.cancelOperation(_:)):
                suppressQueryUntilMove = true; state.linkQuery = nil; return true
            default: break
            }
        }
        if selector == #selector(NSResponder.insertNewline(_:)) { return continueList(in: textView) }
        if selector == #selector(NSResponder.insertTab(_:)) { return indentListItem(in: textView, outdent: false) }
        if selector == #selector(NSResponder.insertBacktab(_:)) { return indentListItem(in: textView, outdent: true) }
        return false
    }

    // MARK: Actions

    func complete(_ title: String, in tv: NSTextView) {
        let ns = tv.string as NSString
        guard let q = MarkdownEditing.linkQuery(in: ns, caret: tv.selectedRange().location) else { return }
        // If "]]" already follows the caret (auto-paired), don't add another.
        let after = NSMaxRange(q.range)
        let hasClose = after + 2 <= ns.length && ns.substring(with: NSRange(location: after, length: 2)) == "]]"
        let insertion = hasClose ? title : title + "]]"
        replace(in: tv, range: q.range, with: insertion)
        tv.setSelectedRange(NSRange(location: q.range.location + (title as NSString).length + 2, length: 0))
        parent.state.linkQuery = nil
    }

    /// Pictures go in as embeds, each on a line of its own so it shows as a picture.
    func insertPictures(_ urls: [URL], data: [(Data, String)] = [], in tv: NSTextView) {
        let names = savePictures(urls, data: data)
        guard !names.isEmpty else { return }
        let sel = tv.selectedRange()
        let snippet = MarkdownEditing.embedSnippet(names, in: tv.string as NSString, at: sel)
        replace(in: tv, range: sel, with: snippet.text)
        tv.setSelectedRange(NSRange(location: sel.location + snippet.caret, length: 0))
    }

    /// Ticks the box; a Tasks-plugin line also gets (or loses) its "✅ date".
    private func toggleTask(at location: Int, in tv: NSTextView) {
        let ns = tv.string as NSString
        guard location + 2 < ns.length else { return }
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let content = NSRange(location: line.location, length: line.length - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0))
        replace(in: tv, range: content, with: Tasks.toggled(ns.substring(with: content)))
    }

    private func continueList(in tv: NSTextView) -> Bool {
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = ns.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        guard let c = MarkdownEditing.continuation(for: lineText) else { return false }
        if c.clearLine {
            replace(in: tv, range: NSRange(location: lineRange.location, length: sel.location - lineRange.location), with: "")
        } else {
            replace(in: tv, range: sel, with: c.insert)
        }
        return true
    }

    private func indentListItem(in tv: NSTextView, outdent: Bool) -> Bool {
        let ns = tv.string as NSString
        let line = ns.lineRange(for: tv.selectedRange())
        let text = ns.substring(with: line)
        guard MarkdownEditing.continuation(for: text.trimmingCharacters(in: .newlines)) != nil else { return false }
        let caret = tv.selectedRange().location
        if outdent {
            if text.hasPrefix("\t") { replace(in: tv, range: NSRange(location: line.location, length: 1), with: ""); tv.setSelectedRange(NSRange(location: max(caret - 1, line.location), length: 0)) }
            else if text.hasPrefix("    ") { replace(in: tv, range: NSRange(location: line.location, length: 4), with: ""); tv.setSelectedRange(NSRange(location: max(caret - 4, line.location), length: 0)) }
        } else {
            replace(in: tv, range: NSRange(location: line.location, length: 0), with: "\t")
            tv.setSelectedRange(NSRange(location: caret + 1, length: 0))
        }
        return true
    }

    /// Undo-friendly replacement.
    private func replace(in tv: NSTextView, range: NSRange, with string: String) {
        guard tv.shouldChangeText(in: range, replacementString: string) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: string)
        tv.didChangeText()
    }

    private func updateCaret(_ tv: NSTextView) {
        guard parent.state.linkQuery != nil || parent.state.slashQuery != nil, let window = tv.window, let scroll = tv.enclosingScrollView else { return }
        var actual = NSRange()
        let screen = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: &actual)
        let inWindow = window.convertFromScreen(screen)
        let inScroll = scroll.convert(inWindow, from: nil)
        let y = scroll.isFlipped ? inScroll.maxY : scroll.bounds.height - inScroll.minY
        parent.state.caretPoint = CGPoint(x: inScroll.minX, y: y + 4)
    }
}

/// NSTextView with Markdown shortcuts: ⌘B bold, ⌘I italic, ⌘K wiki link, ⌘⇧H highlight, ⌘⇧X strikethrough.
/// Typing `[[` auto-closes it.
final class SpaceTextView: NSTextView {
    weak var coordinator: EditorCoordinator?

    // Blocks (see BlockGutter.swift).
    var cachedBlocks: [TextBlock]?
    var gutter: BlockGutter?
    var dropLine: NSView?
    var dragShade: NSView?
    var hoveredBlock: Int?
    /// The blocks being dragged by their handle.
    var draggingBlock: Range<Int>?
    var dropTarget: Int?
    /// Notion's "blue blocks": whole blocks selected (by the handle, the left margin or Esc).
    var blockSelection: Range<Int>?
    var blockAnchor: Int?
    var blockCursor: Int?
    var selectionShade: NSView?
    var savedSelectionAttributes: [NSAttributedString.Key: Any]?
    /// Columns (see ColumnsOverlay.swift): the editors over each columns block and how tall they are.
    var columnViews: [ColumnsView] = []
    var columnHeights: [CGFloat] = []
    var lastCaret = 0
    /// While dragging a block: dropped next to this block, it makes columns.
    var dropBeside: (index: Int, right: Bool)?
    /// The properties panel over the frontmatter (see Properties.swift).
    var propertiesHost: NSHostingView<PropertiesView>?
    var propertiesModel: PropertiesModel?
    var propertiesHeight: CGFloat = 80
    /// Galleries (see Gallery.swift): the card grids over each ```gallery block and how tall they are.
    lazy var galleries = GalleryOverlays(
        textView: self,
        vault: { [weak self] in self?.coordinator?.parent.vault },
        onOpen: { [weak self] link in self?.coordinator?.parent.onOpenLink(link) },
        onResize: { [weak self] in
            guard let self, let storage = self.textStorage else { return }
            self.coordinator?.restyle(storage, selection: self.selectedRange(), force: true)
        })
    /// Dataview results (see DataviewView.swift) over each ```dataview block.
    lazy var dataviews = DataviewOverlays(
        textView: self,
        vault: { [weak self] in self?.coordinator?.parent.vault },
        noteID: { [weak self] in self?.coordinator?.parent.noteID },
        onOpen: { [weak self] link in self?.coordinator?.parent.onOpenLink(link) },
        onResize: { [weak self] in
            guard let self, let storage = self.textStorage else { return }
            self.coordinator?.restyle(storage, selection: self.selectedRange(), force: true)
        })

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, (layoutManager as? BlockLayoutManager)?.blocks.contains(where: \.kind.isImage) == true {
            DispatchQueue.main.async { [weak self] in        // pictures shrink with the column
                guard let self, let storage = self.textStorage else { return }
                self.coordinator?.restyle(storage, selection: self.selectedRange(), force: true)
            }
        }
        guard widthChanged, !columnViews.isEmpty || propertiesHost != nil || !galleries.isEmpty || !dataviews.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let lm = self.layoutManager as? BlockLayoutManager else { return }
            self.syncColumns(lm.blocks)
            self.syncProperties(lm.blocks)      // the panels follow the new width
            self.syncGalleries(lm.blocks)
            self.syncDataviews(lm.blocks)
        }
    }

    override var string: String {
        didSet { cachedBlocks = nil }
    }

    override func didChangeText() {
        cachedBlocks = nil
        clearBlockSelection()          // block numbers change with the text; our own edits reselect afterwards
        super.didChangeText()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { ($0.owner as AnyObject?) === self && $0.options.contains(.mouseMoved) }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let p = convert(event.locationInWindow, from: nil)
        if !(gutter?.frame.insetBy(dx: -4, dy: -4).contains(p) ?? false) { hideHandle() }
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        if let window { updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    override func mouseDown(with event: NSEvent) {
        clearBlockSelection()
        let p = convert(event.locationInWindow, from: nil)
        // In the empty margin left of the text: select whole blocks, dragging over them like a rubber band.
        if p.x < textContainerOrigin.x - 2, !string.isEmpty, let start = blockNearest(toY: p.y) {
            trackBlockBand(from: start)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if blockSelection != nil, handleBlockSelectionKey(event, flags: flags) { return }
        // Esc selects the block with the caret (unless a popup is open: then Esc closes it).
        if event.keyCode == 53, flags.isEmpty, blockSelection == nil,
           coordinator?.popupVisible != true, coordinator?.parent.state.slashVisible != true,
           let i = Blocks.index(of: selectedRange().location, in: blocks) {
            selectBlocks(from: i, to: i)
            return
        }
        if flags.contains([.option, .shift]), !flags.contains(.command) {
            switch event.keyCode {
            case 126: moveCaretBlock(by: -1); return     // ⌥⇧↑
            case 125: moveCaretBlock(by: +1); return     // ⌥⇧↓
            default: break
            }
        }
        hideHandle()
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        if let sel = blockSelection, !shift {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": duplicateBlocks(sel); return true
            case "c": copyBlocks(sel); return true
            case "x": copyBlocks(sel); deleteBlocks(sel); return true
            case "a": selectBlocks(from: 0, to: blocks.count - 1); return true
            default: break
            }
        }
        switch (event.charactersIgnoringModifiers?.lowercased(), shift) {
        case ("b", false): wrapSelection("**", "**"); return true
        case ("i", false): wrapSelection("*", "*"); return true
        case ("k", false): wrapSelection("[[", "]]"); return true
        case ("k", true): insertWebLink(); return true
        case ("h", true): wrapSelection("==", "=="); return true
        case ("x", true): wrapSelection("~~", "~~"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        // "[[" → "[[]]" with the caret in the middle.
        guard (string as? String) == "[" else { return }
        let ns = self.string as NSString
        let caret = selectedRange().location
        guard caret >= 2, ns.substring(with: NSRange(location: caret - 2, length: 2)) == "[[" else { return }
        let next = caret + 2 <= ns.length ? ns.substring(with: NSRange(location: caret, length: 2)) : ""
        guard next != "]]" else { return }
        super.insertText("]]", replacementRange: selectedRange())
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    // MARK: Pictures and links from the clipboard and drops

    /// Picture files, or picture data (a screenshot, an image copied in a browser), on a pasteboard.
    private func pictures(on pb: NSPasteboard) -> (urls: [URL], data: [(Data, String)]) {
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
        let urls = files.filter { EditorImages.isImage($0.lastPathComponent) }
        if !files.isEmpty { return (urls, []) }
        // Text with a picture attached (a copied web page) is pasted as text, unless the text is just its address.
        if let s = pb.string(forType: .string), !MarkdownEditing.isWebAddress(s) { return ([], []) }
        if let png = pb.data(forType: .png) { return ([], [(png, "png")]) }
        if let tiff = pb.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return ([], [(png, "png")])
        }
        return ([], [])
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let found = pictures(on: pb)
        if !found.urls.isEmpty || !found.data.isEmpty, let coordinator {
            coordinator.insertPictures(found.urls, data: found.data, in: self)
            return
        }
        // An address pasted over selected text links the text, like Obsidian.
        if selectedRange().length > 0, let s = pb.string(forType: .string), MarkdownEditing.isWebAddress(s) {
            let sel = selectedRange()
            let link = "[\((string as NSString).substring(with: sel))](\(s.trimmingCharacters(in: .whitespacesAndNewlines)))"
            if shouldChangeText(in: sel, replacementString: link) {
                textStorage?.replaceCharacters(in: sel, with: link)
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + (link as NSString).length, length: 0))
            }
            return
        }
        super.paste(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(sender)
        let found = pictures(on: sender.draggingPasteboard)
        return !found.urls.isEmpty || !found.data.isEmpty ? .copy : op
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let found = pictures(on: sender.draggingPasteboard)
        guard !found.urls.isEmpty || !found.data.isEmpty, let coordinator else { return super.performDragOperation(sender) }
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: min(at, (string as NSString).length), length: 0))
        coordinator.insertPictures(found.urls, data: found.data, in: self)
        window?.makeFirstResponder(self)
        return true
    }

    func insertWebLink() {
        let sel = selectedRange()
        let link = MarkdownEditing.webLink(selected: (string as NSString).substring(with: sel),
                                           clipboard: NSPasteboard.general.string(forType: .string))
        guard shouldChangeText(in: sel, replacementString: link.text) else { return }
        textStorage?.replaceCharacters(in: sel, with: link.text)
        didChangeText()
        setSelectedRange(NSRange(location: sel.location + link.caret, length: 0))
    }

    func wrapSelection(_ open: String, _ close: String) {
        let sel = selectedRange()
        let ns = string as NSString
        let inner = ns.substring(with: sel)
        // Toggle off if the selection is already wrapped.
        let o = (open as NSString).length, c = (close as NSString).length
        if sel.location >= o, NSMaxRange(sel) + c <= ns.length,
           ns.substring(with: NSRange(location: sel.location - o, length: o)) == open,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: c)) == close {
            let outer = NSRange(location: sel.location - o, length: sel.length + o + c)
            if shouldChangeText(in: outer, replacementString: inner) {
                textStorage?.replaceCharacters(in: outer, with: inner)
                didChangeText()
                setSelectedRange(NSRange(location: outer.location, length: sel.length))
            }
            return
        }
        let replacement = open + inner + close
        if shouldChangeText(in: sel, replacementString: replacement) {
            textStorage?.replaceCharacters(in: sel, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + o, length: sel.length))
        }
    }
}

#else
import UIKit
import UniformTypeIdentifiers

extension MarkdownEditor: UIViewRepresentable {
    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(self) }

    func makeUIView(context: Context) -> SpaceUITextView {
        let storage = NSTextStorage()
        let layout = BlockLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = SpaceUITextView(frame: .zero, textContainer: container)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 0, bottom: 120, right: 0)
        tv.autocorrectionType = .default
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.tintColor = EditorTheme().accent
        tv.linkTextAttributes = [:]
        tv.typingAttributes = EditorTheme().baseAttributes
        tv.keyboardDismissMode = .interactive
        tv.text = text
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(EditorCoordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)

        state.complete = { [weak tv, weak coordinator = context.coordinator] title in
            guard let tv, let coordinator else { return }
            coordinator.complete(title, in: tv)
        }
        state.insertMarkup = { [weak tv] open, close in tv?.wrapSelection(open, close) }
        state.insertImages = { [weak tv, weak coordinator = context.coordinator] urls in
            guard let tv, let coordinator else { return }
            coordinator.insertPictures(urls, in: tv)
        }
        state.insertWebLink = { [weak tv] in tv?.insertWebLink() }
        context.coordinator.restyle(tv.textStorage, selection: tv.selectedRange, force: true)
        return tv
    }

    func updateUIView(_ tv: SpaceUITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text {
            let sel = tv.selectedRange
            tv.text = text
            tv.selectedRange = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
            context.coordinator.restyle(tv.textStorage, selection: tv.selectedRange, force: true)
        } else if context.coordinator.lastRevealAll != revealAll || context.coordinator.lastHideProperties != hideProperties {
            context.coordinator.restyle(tv.textStorage, selection: tv.selectedRange, force: true)
        }
    }
}

extension EditorCoordinator: UITextViewDelegate, UIGestureRecognizerDelegate {
    func textViewDidChange(_ tv: UITextView) {
        parent.text = tv.text
        restyle(tv.textStorage, selection: tv.selectedRange, force: true)
        tv.typingAttributes = styler.theme.baseAttributes
        updateQuery(text: tv.text as NSString, selection: tv.selectedRange)
        updateCaret(tv)
    }

    func textViewDidChangeSelection(_ tv: UITextView) {
        restyle(tv.textStorage, selection: tv.selectedRange)
        updateQuery(text: tv.text as NSString, selection: tv.selectedRange)
        updateCaret(tv)
    }

    func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n", range.length == 0 else { return true }
        if popupVisible {
            complete(parent.state.suggestions[parent.state.selectedSuggestion], in: tv)
            return false
        }
        let ns = tv.text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
        guard let c = MarkdownEditing.continuation(for: lineText) else { return true }
        if c.clearLine {
            replace(in: tv, range: NSRange(location: lineRange.location, length: range.location - lineRange.location), with: "")
        } else {
            replace(in: tv, range: range, with: c.insert)
        }
        return false
    }

    /// Links and checkboxes in an editable UITextView don't react to taps by themselves.
    @objc func tapped(_ g: UITapGestureRecognizer) {
        guard let tv = g.view as? UITextView, let pos = tv.closestPosition(to: g.location(in: tv)) else { return }
        let offset = tv.offset(from: tv.beginningOfDocument, to: pos)
        let length = tv.textStorage.length
        for i in [offset, offset - 1] where i >= 0 && i < length {
            if let url = tv.textStorage.attribute(.link, at: i, effectiveRange: nil) as? URL {
                if !handle(url: url, toggleTask: { self.toggleTask(at: $0, in: tv) }) { UIApplication.shared.open(url) }
                return
            }
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func complete(_ title: String, in tv: UITextView) {
        let ns = tv.text as NSString
        guard let q = MarkdownEditing.linkQuery(in: ns, caret: tv.selectedRange.location) else { return }
        let after = NSMaxRange(q.range)
        let hasClose = after + 2 <= ns.length && ns.substring(with: NSRange(location: after, length: 2)) == "]]"
        replace(in: tv, range: q.range, with: hasClose ? title : title + "]]")
        tv.selectedRange = NSRange(location: q.range.location + (title as NSString).length + 2, length: 0)
        parent.state.linkQuery = nil
    }

    func insertPictures(_ urls: [URL], data: [(Data, String)] = [], in tv: UITextView) {
        let names = savePictures(urls, data: data)
        guard !names.isEmpty else { return }
        let sel = tv.selectedRange
        let snippet = MarkdownEditing.embedSnippet(names, in: tv.text as NSString, at: sel)
        replace(in: tv, range: sel, with: snippet.text)
        tv.selectedRange = NSRange(location: sel.location + snippet.caret, length: 0)
    }

    /// Ticks the box; a Tasks-plugin line also gets (or loses) its "✅ date".
    private func toggleTask(at location: Int, in tv: UITextView) {
        let ns = tv.text as NSString
        guard location + 2 < ns.length else { return }
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let content = NSRange(location: line.location, length: line.length - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0))
        replace(in: tv, range: content, with: Tasks.toggled(ns.substring(with: content)))
    }

    private func replace(in tv: UITextView, range: NSRange, with string: String) {
        guard let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let end = tv.position(from: start, offset: range.length),
              let r = tv.textRange(from: start, to: end) else { return }
        tv.replace(r, withText: string)
    }

    private func updateCaret(_ tv: UITextView) {
        guard parent.state.linkQuery != nil, let end = tv.selectedTextRange?.end else { return }
        let r = tv.caretRect(for: end)
        parent.state.caretPoint = CGPoint(x: r.minX - tv.contentOffset.x, y: r.maxY - tv.contentOffset.y + 4)
    }
}

final class SpaceUITextView: UITextView {
    weak var coordinator: EditorCoordinator?

    override var keyCommands: [UIKeyCommand]? {
        var list = [
            UIKeyCommand(title: "Жирный", action: #selector(bold), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Курсив", action: #selector(italic), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "Ссылка на звезду", action: #selector(wiki), input: "k", modifierFlags: .command),
            UIKeyCommand(title: "Ссылка на сайт", action: #selector(webLink), input: "k", modifierFlags: [.command, .shift])
        ]
        // Arrows only steer the [[ popup while it is open; otherwise they move the caret as usual.
        if coordinator?.popupVisible == true {
            list.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(down)))
            list.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(up)))
        }
        list.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return list
    }

    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        // Pictures are sized to the column: a rotation or a wider pane redraws them.
        if let lm = layoutManager as? BlockLayoutManager, lm.blocks.contains(where: \.kind.isImage) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator?.restyle(self.textStorage, selection: self.selectedRange, force: true)
            }
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if pb.hasImages, !pb.hasStrings || pb.string.map(MarkdownEditing.isWebAddress) == true, let coordinator {
            let data = pb.data(forPasteboardType: UTType.png.identifier).map { ($0, "png") }
                ?? pb.data(forPasteboardType: UTType.jpeg.identifier).map { ($0, "jpg") }
                ?? pb.image?.pngData().map { ($0, "png") }
            if let data { coordinator.insertPictures([], data: [data], in: self); return }
        }
        if selectedRange.length > 0, let s = pb.string, MarkdownEditing.isWebAddress(s), let range = selectedTextRange {
            let start = selectedRange.location
            let link = "[\(text(in: range) ?? "")](\(s.trimmingCharacters(in: .whitespacesAndNewlines)))"
            replace(range, withText: link)
            selectedRange = NSRange(location: start + (link as NSString).length, length: 0)
            return
        }
        super.paste(sender)
    }

    func insertWebLink() {
        guard let range = selectedTextRange else { return }
        let start = selectedRange.location
        let link = MarkdownEditing.webLink(selected: text(in: range) ?? "", clipboard: UIPasteboard.general.string)
        replace(range, withText: link.text)
        selectedRange = NSRange(location: start + link.caret, length: 0)
    }

    @objc private func bold() { wrapSelection("**", "**") }
    @objc private func italic() { wrapSelection("*", "*") }
    @objc private func wiki() { wrapSelection("[[", "]]") }
    @objc private func webLink() { insertWebLink() }
    @objc private func down() { moveSuggestion(+1) }
    @objc private func up() { moveSuggestion(-1) }

    private func moveSuggestion(_ d: Int) {
        guard let c = coordinator, c.popupVisible else { return }
        let s = c.parent.state
        s.selectedSuggestion = max(0, min(s.suggestions.count - 1, s.selectedSuggestion + d))
    }

    func wrapSelection(_ open: String, _ close: String) {
        guard let range = selectedTextRange else { return }
        let inner = text(in: range) ?? ""
        let start = selectedRange.location
        replace(range, withText: open + inner + close)
        selectedRange = NSRange(location: start + (open as NSString).length, length: (inner as NSString).length)
    }
}
#endif

// MARK: - The `[[` popup

/// Floating list of matching star names, shown under the caret while typing a link.
struct LinkSuggestions: View {
    let state: EditorState

    var body: some View {
        if state.linkQuery != nil, !state.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(state.suggestions.enumerated()), id: \.offset) { index, title in
                    Button { state.complete?(title) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(title)).font(.caption).foregroundStyle(Theme.accent)
                            label(title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(index == state.selectedSuggestion ? Theme.accent.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 280)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .offset(x: state.caretPoint.x, y: state.caretPoint.y)
            .transition(.opacity)
        }
    }

    private func icon(_ s: String) -> String {
        if s.contains("#") { return "number" }
        return EditorImages.isImage(s) ? "photo" : "sparkle"
    }

    /// "Note#Heading" reads as the heading, with its note dimmed in front.
    private func label(_ s: String) -> Text {
        guard let hash = s.firstIndex(of: "#") else { return Text(s) }
        let note = s[..<hash], heading = s[s.index(after: hash)...]
        return note.isEmpty ? Text(heading) : Text("\(note) › ").foregroundStyle(Theme.muted) + Text(heading)
    }
}

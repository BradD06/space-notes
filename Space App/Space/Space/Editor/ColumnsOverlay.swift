#if os(macOS)
import AppKit

/// Notion-style columns laid over the note: one small editor per column, side by side.
///
/// The note's own text keeps the columns as Markdown (see `Blocks.columnsMarkdown`); the styler hides it and
/// keeps room for this view. Typing in a column writes the whole columns block back into the note.
final class ColumnsView: NSView, NSTextViewDelegate {
    weak var host: SpaceTextView?
    /// Which columns block of the note this is (the first, the second …).
    var index = 0
    private(set) var editors: [ColumnTextView] = []
    /// Galleries inside each column (```gallery blocks work there as in the note).
    private var galleries: [GalleryOverlays] = []
    /// Dataview tables and widgets inside each column, as in the note.
    private var dataviews: [DataviewOverlays] = []
    private var styler: MarkdownStyler = {
        var s = MarkdownStyler()
        s.theme.bodySize = 16
        return s
    }()
    static let gap: CGFloat = 32
    /// The handle of the block under the pointer inside a column: drag it to another column, out, or beside.
    private lazy var grip: GutterButton = {
        let g = GutterButton(symbol: "grip", help: "Перетащите блок: в другую колонку, выше или ниже, наружу")
        g.symbolSize = 9
        g.isHidden = true
        g.onMouseDown = { [weak self] event in self?.trackGrip(event) }
        return g
    }()

    /// Is this window point over the handle (so leaving a column towards it keeps it)?
    func isOverGrip(_ windowPoint: NSPoint) -> Bool {
        guard !grip.isHidden, let sv = grip.superview else { return false }
        return grip.frame.insetBy(dx: -6, dy: -6).contains(sv.convert(windowPoint, from: nil))
    }
    private var hovered: (column: Int, block: Int)?

    override func removeFromSuperview() {
        grip.removeFromSuperview()
        super.removeFromSuperview()
    }

    override var isFlipped: Bool { true }

    // MARK: Blocks inside the columns

    /// The rectangles of a column's blocks, in this view's coordinates.
    func blockRects(_ column: Int) -> [NSRect] {
        guard editors.indices.contains(column) else { return [] }
        let e = editors[column]
        guard let lm = e.layoutManager, let c = e.textContainer else { return [] }
        let o = e.textContainerOrigin
        return Blocks.blocks(in: e.string).map { b in
            let glyphs = lm.glyphRange(forCharacterRange: b.range, actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: glyphs, in: c)
            if b.range.length == 0 { r = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil) }
            return NSRect(x: e.frame.minX, y: e.frame.minY + o.y + r.minY, width: e.frame.width, height: r.height)
        }
    }

    /// Where blocks dropped at this point go: which column, before which of its blocks, and the line to show.
    func dropSpot(at p: NSPoint) -> (column: Int, before: Int, line: NSRect)? {
        guard let j = editors.firstIndex(where: { p.x >= $0.frame.minX - Self.gap / 2 && p.x <= $0.frame.maxX + Self.gap / 2 }) else { return nil }
        let e = editors[j]
        let rects = blockRects(j)
        var before = rects.count
        var y = (rects.last?.maxY ?? e.frame.minY) + 3
        for (i, r) in rects.enumerated() where p.y < r.midY {
            before = i
            y = i > 0 ? (rects[i - 1].maxY + r.minY) / 2 : r.minY - 3
            break
        }
        return (j, before, NSRect(x: e.frame.minX - 4, y: y - 1.5, width: e.frame.width + 8, height: 3))
    }

    /// The pointer moved over a column's editor: its block gets a handle on the left.
    func hover(_ e: NSTextView, at p: NSPoint) {
        guard host?.dragSource == nil, let j = editors.firstIndex(where: { $0 === e }) else { return }
        let local = convert(p, from: e)
        let rects = blockRects(j)
        guard let i = rects.firstIndex(where: { local.y >= $0.minY - 2 && local.y <= $0.maxY + 2 }) else { hideGrip(); return }
        hovered = (j, i)
        let r = rects[i]
        // The handle lives in the note's editor: left of the first column it is outside this view.
        guard let host else { return }
        if grip.superview !== host { grip.removeFromSuperview(); host.addSubview(grip) }
        let inSelf = NSRect(x: r.minX - 20, y: r.minY + max(0, (min(r.height, 40) - 22) / 2), width: 18, height: 22)
        grip.frame = host.convert(inSelf, from: self)
        grip.isHidden = false
    }

    func hideGrip() {
        guard host?.dragSource == nil else { return }
        hovered = nil
        grip.isHidden = true
    }

    private func trackGrip(_ down: NSEvent) {
        guard let host, let window, let h = hovered else { return }
        let start = down.locationInWindow
        var dragging = false
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            let p = event.locationInWindow
            if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 {
                dragging = true
                let rects = blockRects(h.column)
                let shade = rects.indices.contains(h.block) ? convert(rects[h.block], to: host) : .zero
                host.beginColumnDrag(columns: index, column: h.column, range: h.block..<(h.block + 1), shade: shade)
                grip.isHidden = true
            }
            if dragging {
                host.autoscroll(with: event)
                host.updateBlockDrag(event)
            }
        }
        if dragging { host.endBlockDrag() }
        hovered = nil
        grip.isHidden = true
    }

    var columns: [String] { editors.map(\.string) }

    /// Shows these columns (keeps the editors as they are when nothing changed, so typing isn't disturbed).
    func set(columns new: [String]) {
        if editors.count != new.count { rebuild(new.count) }
        for (e, text) in zip(editors, new) where e.string != text {
            let sel = e.selectedRange()
            e.string = text
            e.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            restyle(e)
        }
        layoutEditors()
    }

    func focus(column: Int, atEnd: Bool = true) {
        guard editors.indices.contains(column) else { return }
        let e = editors[column]
        window?.makeFirstResponder(e)
        if atEnd { e.setSelectedRange(NSRange(location: (e.string as NSString).length, length: 0)) }
    }

    private func rebuild(_ count: Int) {
        editors.forEach { $0.removeFromSuperview() }
        editors = (0..<count).map { _ in makeEditor() }
        editors.forEach(addSubview)
        galleries = editors.map { e in
            GalleryOverlays(
                textView: e,
                vault: { [weak self] in self?.host?.coordinator?.parent.vault },
                onOpen: { [weak self] link in self?.host?.coordinator?.parent.onOpenLink(link) },
                onResize: { [weak self, weak e] in
                    guard let self, let e else { return }
                    self.restyle(e)
                    self.layoutEditors()
                })
        }
        dataviews = editors.map { e in
            let o = DataviewOverlays(
                textView: e,
                vault: { [weak self] in self?.host?.coordinator?.parent.vault },
                noteID: { [weak self] in self?.host?.coordinator?.parent.noteID },
                onOpen: { [weak self] link in self?.host?.coordinator?.parent.onOpenLink(link) },
                onResize: { [weak self, weak e] in
                    guard let self, let e else { return }
                    self.restyle(e)
                    self.layoutEditors()
                })
            // The whole note (for a widget reading or rewriting its own note) is the note's editor, not the column's.
            o.noteView = { [weak self] in self?.host }
            return o
        }
    }

    private func makeEditor() -> ColumnTextView {
        let storage = NSTextStorage()
        let layout = BlockLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let e = ColumnTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40), textContainer: container)
        e.isRichText = false
        // No undo of its own: every change lands in the note, and ⌘Z undoes it there (one history for all).
        e.allowsUndo = false
        e.drawsBackground = false
        e.isVerticallyResizable = false
        e.isHorizontallyResizable = false
        e.textContainerInset = NSSize(width: 0, height: 4)
        e.insertionPointColor = styler.theme.accent
        e.isAutomaticQuoteSubstitutionEnabled = false
        e.isAutomaticDashSubstitutionEnabled = false
        e.isContinuousSpellCheckingEnabled = true
        e.linkTextAttributes = [NSAttributedString.Key.cursor: NSCursor.pointingHand]
        e.typingAttributes = styler.theme.baseAttributes
        e.selectedTextAttributes = [NSAttributedString.Key.backgroundColor: styler.theme.accent.withAlphaComponent(0.25)]
        e.delegate = self
        e.owner = self
        return e
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { layoutEditors() }
    }

    /// Lays the editors out side by side and tells the note how tall the columns are.
    func layoutEditors() {
        guard !editors.isEmpty else { return }
        let n = CGFloat(editors.count)
        let width = max(60, (bounds.width - Self.gap * (n - 1)) / n)
        var tallest: CGFloat = 34
        for (i, e) in editors.enumerated() {
            e.frame.size.width = width
            e.frame.origin = NSPoint(x: CGFloat(i) * (width + Self.gap), y: 0)
            if let lm = e.layoutManager, let c = e.textContainer {
                c.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                lm.ensureLayout(for: c)
                if galleries.indices.contains(i), let blm = lm as? BlockLayoutManager { galleries[i].sync(blm.blocks) }
                if dataviews.indices.contains(i), let blm = lm as? BlockLayoutManager { dataviews[i].sync(blm.blocks) }
                tallest = max(tallest, ceil(lm.usedRect(for: c).height) + e.textContainerInset.height * 2 + 4)
            }
        }
        for e in editors { e.frame.size.height = tallest }
        needsDisplay = true
        host?.setColumnHeight(tallest, forColumnsAt: index)
    }

    func restyle(_ e: NSTextView) {
        guard let storage = e.textStorage else { return }
        let active = window?.firstResponder === e ? e.selectedRange() : nil
        let overlay = editors.firstIndex(where: { $0 === e }).flatMap { galleries.indices.contains($0) ? galleries[$0] : nil }
        styler.galleriesEnabled = overlay != nil && host?.coordinator?.parent.vault != nil
        styler.galleryHeights = overlay?.heights ?? []
        let dv = editors.firstIndex(where: { $0 === e }).flatMap { dataviews.indices.contains($0) ? dataviews[$0] : nil }
        styler.dataviewEnabled = dv != nil && host?.coordinator?.parent.vault != nil
        styler.dataviewHeights = dv?.heights ?? [:]
        let blocks = styler.apply(to: storage, active: active, revealAll: false)
        if let lm = storage.layoutManagers.first as? BlockLayoutManager {
            lm.blocks = blocks
            lm.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        }
        overlay?.sync(blocks)
        dv?.sync(blocks)
        e.typingAttributes = styler.theme.baseAttributes
    }

    // A thin line between the columns.
    override func draw(_ dirtyRect: NSRect) {
        guard editors.count > 1 else { return }
        NSColor.white.withAlphaComponent(0.06).setFill()
        for e in editors.dropLast() {
            NSRect(x: e.frame.maxX + Self.gap / 2 - 0.5, y: 6, width: 1, height: max(0, bounds.height - 12)).fill()
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let e = notification.object as? NSTextView else { return }
        restyle(e)
        layoutEditors()
        host?.writeColumns(columns, at: index)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let e = notification.object as? NSTextView else { return }
        if let i = editors.firstIndex(where: { $0 === e }), galleries.indices.contains(i), galleries[i].hopCaret() { return }
        restyle(e)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let e = notification.object as? NSTextView else { return }
        restyle(e)                 // hides the Markdown marks of the line that was being edited
        e.needsDisplay = true
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        let handled = host?.coordinator?.handle(url: url) { loc in
            let ns = textView.string as NSString
            guard loc + 2 < ns.length else { return }
            let mark = NSRange(location: loc + 1, length: 1)
            let checked = ns.substring(with: mark).lowercased() == "x"
            if textView.shouldChangeText(in: mark, replacementString: checked ? " " : "x") {
                textView.textStorage?.replaceCharacters(in: mark, with: checked ? " " : "x")
                textView.didChangeText()
            }
        } ?? false
        if !handled { NSWorkspace.shared.open(url) }
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            // Lists continue inside a column, as in the note.
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            guard sel.length == 0 else { return false }
            let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let before = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
            guard let c = MarkdownEditing.continuation(for: before) else { return false }
            let range = c.clearLine ? NSRange(location: line.location, length: sel.location - line.location) : sel
            let insert = c.clearLine ? "" : c.insert
            if textView.shouldChangeText(in: range, replacementString: insert) {
                textView.textStorage?.replaceCharacters(in: range, with: insert)
                textView.didChangeText()
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc leaves the columns and selects them as a block in the note.
            host?.selectColumnsBlock(at: index)
            return true
        }
        return false
    }
}

/// The editor of one column.
final class ColumnTextView: NSTextView {
    weak var owner: ColumnsView?

    // Moving over a block shows its handle (see ColumnsView.hover).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { ($0.owner as AnyObject?) === self && $0.options.contains(.mouseMoved) }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        owner?.hover(self, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard let owner else { return }
        // Leaving towards the handle keeps it.
        if !owner.isOverGrip(event.locationInWindow) { owner.hideGrip() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased(), shift) {
        case ("b", false): wrap("**", "**"); return true
        case ("i", false): wrap("*", "*"); return true
        case ("k", false): wrap("[[", "]]"); return true
        case ("h", true): wrap("==", "=="); return true
        case ("x", true): wrap("~~", "~~"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func wrap(_ open: String, _ close: String) {
        let sel = selectedRange()
        let inner = (string as NSString).substring(with: sel)
        let new = open + inner + close
        guard shouldChangeText(in: sel, replacementString: new) else { return }
        textStorage?.replaceCharacters(in: sel, with: new)
        didChangeText()
        setSelectedRange(NSRange(location: sel.location + (open as NSString).length, length: sel.length))
    }

    // An empty column says where to type.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let hint = NSAttributedString(string: "Пустая колонка", attributes: [
            .font: EditorTheme().font(size: 15, italic: true), .foregroundColor: EditorTheme().faint])
        hint.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height))
    }
}

// MARK: - The note's side

extension SpaceTextView {

    /// Puts a columns view over every columns block (after each restyle, when the layout is known).
    func syncColumns(_ editorBlocks: [EditorBlock]) {
        let cols = editorBlocks.filter { $0.kind == .columns }
        while columnViews.count > cols.count { columnViews.removeLast().removeFromSuperview() }
        guard !cols.isEmpty, let lm = layoutManager, let container = textContainer else { return }
        lm.ensureLayout(for: container)
        let o = textContainerOrigin
        let pad = container.lineFragmentPadding
        let ns = string as NSString
        for (k, b) in cols.enumerated() {
            let v: ColumnsView
            if k < columnViews.count {
                v = columnViews[k]
            } else {
                v = ColumnsView()
                v.host = self
                addSubview(v)
                columnViews.append(v)
            }
            v.index = k
            let glyph = lm.glyphIndexForCharacter(at: min(b.range.location, max(ns.length - 1, 0)))
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let height = k < columnHeights.count ? columnHeights[k] : 60
            v.frame = NSRect(x: o.x + pad, y: o.y + line.maxY - height, width: container.size.width - 2 * pad, height: height)
            v.set(columns: Blocks.columns(of: Blocks.lines(ns.substring(with: b.range))))
        }
    }

    /// The columns grew or shrank: keep that much room in the note.
    func setColumnHeight(_ height: CGFloat, forColumnsAt k: Int) {
        while columnHeights.count <= k { columnHeights.append(60) }
        guard abs(columnHeights[k] - height) > 0.5 else { return }
        columnHeights[k] = height
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.textStorage else { return }
            self.coordinator?.restyle(storage, selection: self.selectedRange(), force: true)
        }
    }

    /// Writes a columns view's text back into the note (one undoable change).
    func writeColumns(_ columns: [String], at k: Int) {
        let all = blocks.filter { $0.kind == .columns }
        guard all.indices.contains(k) else { return }
        let range = all[k].range
        let new = Blocks.columnsMarkdown(columns).joined(separator: "\n")
        guard (string as NSString).substring(with: range) != new, shouldChangeText(in: range, replacementString: new) else { return }
        textStorage?.replaceCharacters(in: range, with: new)
        didChangeText()
    }

    /// Esc in a column: back to the note, with the whole columns block selected.
    func selectColumnsBlock(at k: Int) {
        let all = blocks
        let columnIndices = all.indices.filter { all[$0].kind == .columns }
        guard columnIndices.indices.contains(k) else { return }
        window?.makeFirstResponder(self)
        selectBlocks(from: columnIndices[k], to: columnIndices[k])
    }

    /// Puts the caret into the first column of the columns block at this place.
    func focusColumns(at location: Int) {
        let all = blocks.filter { $0.kind == .columns }
        guard let k = all.firstIndex(where: { location >= $0.range.location && location <= NSMaxRange($0.range) + 1 }),
              columnViews.indices.contains(k) else { return }
        columnViews[k].focus(column: 0)
    }

    /// The caret never stops inside a columns block's hidden Markdown: it hops over it.
    /// Returns true if it moved the caret.
    func hopOverColumns() -> Bool {
        let sel = selectedRange()
        defer { lastCaret = selectedRange().location }
        guard sel.length == 0, blockSelection == nil else { return false }
        let length = (string as NSString).length
        // Hidden ranges: columns blocks, and the frontmatter while the properties panel shows it.
        var hidden = blocks.filter { $0.kind == .columns }.map(\.range)
        hidden += ((layoutManager as? BlockLayoutManager)?.blocks ?? []).filter { $0.kind == .gallery }.map(\.range)
        if propertiesHost != nil, let fm = Properties.frontmatter(in: string as NSString) { hidden.append(fm.range) }
        // Hidden blocks next to each other (the frontmatter, then a gallery) are hopped over as one,
        // or the caret would bounce between them forever.
        var spans: [NSRange] = []
        for r in hidden.sorted(by: { $0.location < $1.location }) {
            if let last = spans.last, r.location <= NSMaxRange(last) + 1 {
                spans[spans.count - 1] = NSUnionRange(last, r)
            } else {
                spans.append(r)
            }
        }
        for r in spans {
            guard sel.location >= r.location, sel.location <= NSMaxRange(r) else { continue }
            let down = lastCaret <= r.location
            var to = down ? NSMaxRange(r) + 1 : r.location - 1
            if to > length || to < 0 { to = down ? r.location - 1 : NSMaxRange(r) + 1 }
            guard to >= 0, to <= length, to != sel.location else { return false }
            setSelectedRange(NSRange(location: to, length: 0))
            return true
        }
        return false
    }
}
#endif

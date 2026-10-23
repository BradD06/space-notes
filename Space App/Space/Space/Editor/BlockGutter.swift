#if os(macOS)
import AppKit

/// The Notion-style handle next to the block under the pointer: "+" adds a block below,
/// "⋮⋮" drags the block somewhere else (click it for the block's menu).
final class BlockGutter: NSView {
    weak var textView: SpaceTextView?
    let plus = GutterButton(symbol: "plus", help: "Добавить блок ниже")
    let grip = GutterButton(symbol: "grip", help: "Перетащите, чтобы переместить\nНажмите — меню блока")

    static let size = NSSize(width: 40, height: 22)

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.frame = NSRect(x: 0, y: 0, width: 20, height: 22)
        grip.frame = NSRect(x: 20, y: 0, width: 18, height: 22)
        grip.symbolSize = 9
        addSubview(plus)
        addSubview(grip)
        plus.onMouseDown = { [weak self] _ in self?.textView?.addBlockBelowHovered() }
        grip.onMouseDown = { [weak self] event in self?.trackGrip(event) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Drag the grip to move the block (or the selected blocks it belongs to); a click selects it and opens
    /// the block menu; ⇧-click adds the blocks up to it to the selection.
    private func trackGrip(_ down: NSEvent) {
        guard let tv = textView, let window, let block = tv.hoveredBlock else { return }
        if down.modifierFlags.contains(.shift) {
            tv.selectBlocks(from: tv.blockAnchor ?? tv.blockSelection?.lowerBound ?? block, to: block)
            return
        }
        let start = down.locationInWindow
        var dragging = false
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            let p = event.locationInWindow
            if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 {
                dragging = true
                let group = tv.blockSelection.flatMap { $0.contains(block) ? $0 : nil } ?? block..<(block + 1)
                tv.beginBlockDrag(group)
            }
            if dragging {
                tv.autoscroll(with: event)
                tv.updateBlockDrag(event)
            }
        }
        if dragging {
            tv.endBlockDrag()
        } else {
            let group = tv.blockSelection.flatMap { $0.contains(block) ? $0 : nil } ?? block..<(block + 1)
            tv.selectBlocks(from: group.lowerBound, to: group.upperBound - 1)
            tv.showBlockMenu(group, from: grip)
        }
    }
}

/// A small icon in the gutter that lights up under the pointer.
final class GutterButton: NSView {
    private let symbol: String
    var symbolSize: CGFloat = 11
    var onMouseDown: ((NSEvent) -> Void)?
    private var hover = false { didSet { needsDisplay = true } }

    init(symbol: String, help: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        toolTip = help
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true; NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { hover = false; NSCursor.iBeam.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: symbol == "plus" ? .pointingHand : .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        if hover {
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        if symbol == "grip" {
            // Notion's six dots, drawn by hand (no system symbol looks quite like it).
            NSColor.white.withAlphaComponent(hover ? 0.75 : 0.4).setFill()
            let r: CGFloat = 1.6, dx: CGFloat = 5, dy: CGFloat = 5
            let x0 = bounds.midX - dx / 2, y0 = bounds.midY - dy
            for col in 0..<2 {
                for row in 0..<3 {
                    let c = NSPoint(x: x0 + CGFloat(col) * dx, y: y0 + CGFloat(row) * dy)
                    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
                }
            }
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let tint = NSColor.white.withAlphaComponent(hover ? 0.75 : 0.35)
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            tint.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
    }
}

/// An NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", checked: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

// MARK: - Blocks in the text view

extension SpaceTextView {

    var blocks: [TextBlock] {
        if let cached = cachedBlocks { return cached }
        let b = Blocks.blocks(in: string)
        cachedBlocks = b
        return b
    }

    /// The block under the pointer (by height only, so it also works over the gutter).
    func block(atY y: CGFloat) -> Int? {
        guard let lm = layoutManager, let container = textContainer, !string.isEmpty else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: 4, y: y - origin.y)
        let glyph = lm.glyphIndex(for: local, in: container)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard local.y >= line.minY - 2, local.y <= line.maxY + 2 else { return nil }
        let char = lm.characterIndexForGlyph(at: glyph)
        return Blocks.index(of: char, in: blocks)
    }

    /// The rectangle a block occupies, in the text view's coordinates.
    func rect(of block: TextBlock) -> NSRect {
        guard let lm = layoutManager, let container = textContainer else { return .zero }
        let glyphs = lm.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: glyphs, in: container)
        if block.range.length == 0 { r = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil) }
        let o = textContainerOrigin
        return NSRect(x: o.x, y: r.minY + o.y, width: container.size.width, height: r.height)
    }

    /// The rectangle several neighbouring blocks occupy together.
    func rect(of group: Range<Int>) -> NSRect {
        let all = blocks
        guard !group.isEmpty, group.lowerBound >= 0, group.upperBound <= all.count else { return .zero }
        return rect(of: all[group.lowerBound]).union(rect(of: all[group.upperBound - 1]))
    }

    /// The block closest to a height, even between blocks or past the end.
    func blockNearest(toY y: CGFloat) -> Int? {
        let all = blocks
        guard !all.isEmpty else { return nil }
        var best = 0
        var distance = CGFloat.infinity
        for (i, b) in all.enumerated() {
            let r = rect(of: b)
            if y >= r.minY && y <= r.maxY { return i }
            let d = min(abs(y - r.minY), abs(y - r.maxY))
            if d < distance { distance = d; best = i }
        }
        return best
    }

    /// The first line of a block (where its handle goes).
    func firstLineRect(of block: TextBlock) -> NSRect {
        guard let lm = layoutManager, string.utf16.count > 0 else { return .zero }
        let glyph = lm.glyphIndexForCharacter(at: min(block.range.location, string.utf16.count - 1))
        let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let o = textContainerOrigin
        return used.offsetBy(dx: o.x, dy: o.y)
    }

    // MARK: Hover handle

    func installGutter() {
        let g = BlockGutter(frame: NSRect(origin: .zero, size: BlockGutter.size))
        g.textView = self
        g.isHidden = true
        addSubview(g)
        gutter = g

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = EditorTheme().accent.cgColor
        line.layer?.cornerRadius = 1.5
        line.isHidden = true
        addSubview(line)
        dropLine = line

        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = EditorTheme().accent.withAlphaComponent(0.12).cgColor
        shade.layer?.cornerRadius = 8
        shade.isHidden = true
        addSubview(shade, positioned: .below, relativeTo: nil)
        dragShade = shade

        let picked = NSView()
        picked.wantsLayer = true
        picked.layer?.backgroundColor = EditorTheme().accent.withAlphaComponent(0.16).cgColor
        picked.layer?.borderColor = EditorTheme().accent.withAlphaComponent(0.35).cgColor
        picked.layer?.borderWidth = 1
        picked.layer?.cornerRadius = 10
        picked.isHidden = true
        addSubview(picked, positioned: .below, relativeTo: nil)
        selectionShade = picked
    }

    func updateHover(at point: NSPoint) {
        guard let gutter, draggingBlock == nil, dragSource == nil else { return }
        // Only near the text column (and its gutter), not far out on the sides.
        let o = textContainerOrigin
        let width = textContainer?.size.width ?? bounds.width
        guard point.x >= o.x - BlockGutter.size.width - 8, point.x <= o.x + width,
              let i = block(atY: point.y) else {
            hideHandle()
            return
        }
        let b = blocks[i]
        hoveredBlock = i
        let line = firstLineRect(of: b)
        let h = BlockGutter.size.height
        gutter.frame = NSRect(x: o.x - BlockGutter.size.width - 4, y: line.minY + max(0, (min(line.height, 40) - h) / 2),
                              width: BlockGutter.size.width, height: h)
        if gutter.isHidden {
            gutter.alphaValue = 0
            gutter.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; gutter.animator().alphaValue = 1 }
        }
    }

    func hideHandle() {
        guard draggingBlock == nil else { return }
        hoveredBlock = nil
        gutter?.isHidden = true
    }

    // MARK: Dragging a block

    func beginBlockDrag(_ group: Range<Int>) {
        guard !group.isEmpty, group.lowerBound >= 0, group.upperBound <= blocks.count else { return }
        draggingBlock = group
        dragSource = .note(group)
        dropSpot = nil
        dropTarget = nil
        selectionShade?.isHidden = true
        dragShade?.frame = rect(of: group).insetBy(dx: -6, dy: -3)
        dragShade?.alphaValue = 1
        dragShade?.isHidden = false
        NSCursor.closedHand.set()
    }

    /// Starts dragging blocks that sit inside a column (by the handle the columns view shows for them).
    func beginColumnDrag(columns k: Int, column: Int, range: Range<Int>, shade: NSRect) {
        let all = blocks
        let indices = all.indices.filter { all[$0].kind == .columns }
        guard indices.indices.contains(k) else { return }
        draggingBlock = nil
        dragSource = .column(block: indices[k], column: column, range: range)
        dropSpot = nil
        dropTarget = nil
        dropBeside = nil
        hideHandle()
        selectionShade?.isHidden = true
        dragShade?.frame = shade.insetBy(dx: -6, dy: -3)
        dragShade?.alphaValue = 1
        dragShade?.isHidden = false
        NSCursor.closedHand.set()
    }

    func updateBlockDrag(_ event: NSEvent) {
        guard let source = dragSource else { return }
        let group: Range<Int> = { if case .note(let g) = source { return g }; return -1..<(-1) }()
        let p = convert(event.locationInWindow, from: nil)
        let all = blocks
        let o = textContainerOrigin
        let width = textContainer?.size.width ?? 300
        let columnsIndices = all.indices.filter { all[$0].kind == .columns }

        // Over columns: into a column, between its blocks (or as a new column at the columns' outer edges).
        for (k, v) in columnViews.enumerated() where columnsIndices.indices.contains(k) && v.frame.insetBy(dx: 0, dy: -4).contains(p) {
            let blockIndex = columnsIndices[k]
            if group.contains(blockIndex) { break }
            let local = v.convert(p, from: self)
            if local.x > v.bounds.width - 14 || local.x < 6 {
                let right = local.x > v.bounds.width / 2
                dropSpot = .newColumn(block: blockIndex, at: right ? v.columns.count : 0)
                dropTarget = nil
                dropBeside = nil
                dropLine?.frame = NSRect(x: right ? v.frame.maxX - 2 : v.frame.minX - 6, y: v.frame.minY - 2, width: 3, height: v.frame.height + 4)
                dropLine?.isHidden = false
                gutter?.isHidden = true
                return
            }
            if let spot = v.dropSpot(at: local) {
                dropSpot = .column(block: blockIndex, column: spot.column, before: spot.before)
                dropTarget = nil
                dropBeside = nil
                dropLine?.frame = v.convert(spot.line, to: self)
                dropLine?.isHidden = false
                gutter?.isHidden = true
                return
            }
        }

        // Near the right (or left) edge of another block: drop it beside that block, as a column.
        let right = p.x > o.x + width * 0.7, left = p.x > o.x + 8 && p.x < o.x + width * 0.12
        if right || left, let i = block(atY: p.y) ?? blockNearest(toY: p.y), !group.contains(i),
           !group.contains(where: { all[$0].kind == .columns }) {
            let r = rect(of: all[i])
            if p.y >= r.minY - 6, p.y <= r.maxY + 6 {
                dropBeside = (i, right)
                dropSpot = .beside(block: i, right: right)
                dropTarget = nil
                dropLine?.frame = NSRect(x: right ? r.maxX - 2 : r.minX - 6, y: r.minY - 2, width: 3, height: r.height + 4)
                dropLine?.isHidden = false
                gutter?.isHidden = true
                return
            }
        }
        dropBeside = nil

        var target = all.count
        var y = (all.last.map { rect(of: $0).maxY } ?? 0) + 3
        for (i, b) in all.enumerated() {
            let r = rect(of: b)
            if p.y < r.midY {
                target = i
                let previous = i > 0 ? rect(of: all[i - 1]).maxY : r.minY - 6
                y = (previous + r.minY) / 2
                break
            }
        }
        dropTarget = target
        dropSpot = .note(before: target)
        // Dropping right where the blocks already are does nothing, so no line there.
        let still = target >= group.lowerBound && target <= group.upperBound
        dropLine?.frame = NSRect(x: o.x - 4, y: y - 1.5, width: (textContainer?.size.width ?? 300) + 8, height: 3)
        dropLine?.isHidden = still
        gutter?.isHidden = true
    }

    func endBlockDrag() {
        let group = draggingBlock, to = dropTarget, beside = dropBeside
        let source = dragSource, spot = dropSpot
        draggingBlock = nil
        dropTarget = nil
        dropBeside = nil
        dragSource = nil
        dropSpot = nil
        dropLine?.isHidden = true
        dragShade?.isHidden = true
        NSCursor.iBeam.set()
        // Into or out of columns: the general move (empty columns disappear, a lone column unwraps).
        let simple: Bool = {
            guard case .note? = source else { return false }
            switch spot { case .note?, .beside?, nil: return true; default: return false }
        }()
        if !simple {
            if let source, let spot, let moved = Blocks.move(string, from: source, to: spot) { replaceAll(with: moved) }
            return
        }
        if let group, let beside, let made = Blocks.makeColumns(string, target: beside.index, moving: group, right: beside.right) {
            replaceAll(with: made.text)
            selectBlocks(from: made.index, to: made.index)
            return
        }
        guard let group, let to, let moved = Blocks.move(string, range: group, to: to) else {
            if blockSelection != nil, let sel = blockSelection { showSelectionShade(sel) }
            return
        }
        replaceAll(with: moved.text)
        selectBlocks(from: moved.range.lowerBound, to: moved.range.upperBound - 1)   // stays selected, like in Notion
    }

    /// Briefly tints a block that just moved, so the eye can follow it.
    func flash(blockAt index: Int) {
        guard blocks.indices.contains(index), let shade = dragShade else { return }
        shade.frame = rect(of: blocks[index]).insetBy(dx: -6, dy: -3)
        shade.alphaValue = 1
        shade.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            shade.animator().alphaValue = 0       // stays in place, invisible, until the next drag
        }
    }

    // MARK: Changing blocks

    /// Replaces the whole note in one undoable step.
    func replaceAll(with text: String) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: full, with: text)
        didChangeText()
    }

    /// Moves the block with the caret one block up or down (⌥⇧↑ / ⌥⇧↓).
    func moveCaretBlock(by delta: Int) {
        guard let i = Blocks.index(of: selectedRange().location, in: blocks) else { return }
        let caretOffset = selectedRange().location - blocks[i].range.location
        let to = delta < 0 ? i - 1 : i + 2
        guard to >= 0, to <= blocks.count, let moved = Blocks.move(string, from: i, to: to) else { return }
        replaceAll(with: moved.text)
        if let r = Blocks.range(of: moved.index, in: moved.text) {
            setSelectedRange(NSRange(location: r.location + min(caretOffset, r.length), length: 0))
            scrollRangeToVisible(selectedRange())
        }
    }

    func turnBlock(_ index: Int, into kind: BlockKind) {
        let caret = selectedRange()
        let new = Blocks.turn(string, index: index, into: kind)
        guard new != string else { return }
        replaceAll(with: new)
        if let r = Blocks.range(of: index, in: new) {
            setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
        } else {
            setSelectedRange(NSRange(location: min(caret.location, (new as NSString).length), length: 0))
        }
    }

    /// "Turn into" for the block with the caret (the formatting bar uses it).
    func turnCaretBlock(into kind: BlockKind) {
        guard let i = Blocks.index(of: selectedRange().location, in: blocks) else { return }
        turnBlock(i, into: kind)
    }

    func addBlockBelowHovered() {
        guard let i = hoveredBlock, blocks.indices.contains(i) else { return }
        let end = NSMaxRange(blocks[i].range)
        window?.makeFirstResponder(self)
        let insertion = "\n/"
        guard shouldChangeText(in: NSRange(location: end, length: 0), replacementString: insertion) else { return }
        textStorage?.replaceCharacters(in: NSRange(location: end, length: 0), with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: end + 2, length: 0))
        hideHandle()
    }

    func showBlockMenu(_ group: Range<Int>, from view: NSView) {
        guard let menu = blockMenu(group) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    /// The block menu: turn into, colour, links, duplicate, move, copy, delete.
    func blockMenu(_ group: Range<Int>) -> NSMenu? {
        guard !group.isEmpty, group.lowerBound >= 0, group.upperBound <= blocks.count else { return nil }
        let first = blocks[group.lowerBound]
        window?.makeFirstResponder(self)
        let many = group.count > 1

        let menu = NSMenu()
        if many {
            let title = NSMenuItem(title: "Выбрано блоков: \(group.count)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        let turn = NSMenu()
        for kind in BlockKind.convertible {
            turn.addItem(ActionItem(kind.title, symbol: kind.icon, checked: !many && kind == first.kind) { [weak self] in
                self?.turnBlocks(group, into: kind)
            })
        }
        if !many && first.kind == .columns {
            let index = group.lowerBound
            menu.addItem(ActionItem("Добавить колонку", symbol: "rectangle.split.3x1") { [weak self] in
                guard let self else { return }
                self.replaceAll(with: Blocks.addColumn(self.string, index: index))
                self.selectBlocks(from: index, to: index)
            })
            menu.addItem(ActionItem("Разъединить колонки", symbol: "rectangle.grid.1x2") { [weak self] in
                guard let self else { return }
                let at = self.blocks[index].range.location
                self.clearBlockSelection()
                self.replaceAll(with: Blocks.unwrapColumns(self.string, index: index))
                self.setSelectedRange(NSRange(location: at, length: 0))
            })
        } else {
            let turnItem = NSMenuItem(title: "Превратить в", action: nil, keyEquivalent: "")
            turnItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            turnItem.submenu = turn
            menu.addItem(turnItem)
        }
        if group.contains(where: { Blocks.canColor(string, index: $0) }) {
            let colorItem = NSMenuItem(title: "Цвет", action: nil, keyEquivalent: "")
            colorItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
            colorItem.submenu = colorMenu(current: many ? nil : Blocks.tint(string, index: group.lowerBound)) { [weak self] tint in
                self?.colorBlocks(group, tint)
            }
            menu.addItem(colorItem)
        }
        if !many, first.kind != .columns {
            let index = group.lowerBound
            menu.addItem(.separator())
            menu.addItem(ActionItem("Копировать ссылку на блок", symbol: "link") { [weak self] in
                self?.copyLink(toBlock: index)
            })
            if coordinator?.parent.vault != nil, coordinator?.parent.noteID != nil {
                menu.addItem(ActionItem("Превратить в страницу", symbol: "doc.badge.arrow.up") { [weak self] in
                    self?.turnIntoPage(index)
                })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Дублировать  ⌘D", symbol: "plus.square.on.square") { [weak self] in
            self?.duplicateBlocks(group)
        })
        let up = ActionItem("Переместить вверх  ⌥⇧↑", symbol: "arrow.up") { [weak self] in
            self?.moveBlocks(group, by: -1)
        }
        up.isEnabled = group.lowerBound > 0
        menu.addItem(up)
        let down = ActionItem("Переместить вниз  ⌥⇧↓", symbol: "arrow.down") { [weak self] in
            self?.moveBlocks(group, by: +1)
        }
        down.isEnabled = group.upperBound < blocks.count
        menu.addItem(down)
        menu.addItem(ActionItem("Копировать  ⌘C", symbol: "doc.on.doc") { [weak self] in
            self?.copyBlocks(group)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Удалить  ⌫", symbol: "trash") { [weak self] in
            self?.deleteBlocks(group)
        })
        menu.autoenablesItems = false
        return menu
    }

    /// Text colours, background colours and "default", each with its swatch.
    func colorMenu(current: BlockTint?, _ apply: @escaping (BlockTint?) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("По умолчанию", symbol: "circle.slash", checked: current == nil) { apply(nil) })
        for background in [false, true] {
            menu.addItem(.separator())
            let header = NSMenuItem(title: background ? "Фон" : "Текст", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for c in BlockColor.allCases {
                let tint = BlockTint(c, background: background)
                let item = ActionItem(c.title, checked: tint == current) { apply(tint) }
                item.image = Self.swatch(c, background: background)
                menu.addItem(item)
            }
        }
        menu.autoenablesItems = false
        return menu
    }

    /// A small "A" in the colour, or a coloured square for a background.
    static func swatch(_ c: BlockColor, background: Bool) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let color = NSColor(srgbRed: CGFloat((c.hex >> 16) & 0xFF) / 255, green: CGFloat((c.hex >> 8) & 0xFF) / 255,
                                blue: CGFloat(c.hex & 0xFF) / 255, alpha: 1)
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            if background {
                color.withAlphaComponent(0.45).setFill()
                box.fill()
            } else {
                NSColor.white.withAlphaComponent(0.25).setStroke()
                box.stroke()
                let a = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color])
                let size = a.size()
                a.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
            }
            return true
        }
    }

    // MARK: Colours, toggles, links, pages

    /// The blocks the caret (or the selected text, or the selected blocks) is in.
    var caretGroup: Range<Int>? {
        if let sel = blockSelection { return sel }
        let sel = selectedRange()
        guard let a = Blocks.index(of: sel.location, in: blocks) else { return nil }
        let b = Blocks.index(of: NSMaxRange(sel), in: blocks) ?? a
        return a..<(max(a, b) + 1)
    }

    func colorBlocks(_ group: Range<Int>, _ tint: BlockTint?) {
        // Colouring keeps the number of blocks, so the selection stays valid.
        var text = string
        for i in group.reversed() { text = Blocks.setColor(text, index: i, tint: tint) }
        guard text != string else { return }
        let caret = selectedRange().location
        let wasSelected = blockSelection != nil
        replaceAll(with: text)
        if wasSelected {
            selectBlocks(from: group.lowerBound, to: group.upperBound - 1)
        } else if let r = Blocks.range(of: group.lowerBound, in: text) {
            setSelectedRange(NSRange(location: min(max(caret, r.location), NSMaxRange(r)), length: 0))
        }
    }

    func colorCaretBlocks(_ tint: BlockTint?) {
        if let g = caretGroup { colorBlocks(g, tint) }
    }

    /// A click on a toggle's arrow folds or unfolds it. True if there was an arrow there.
    func toggleFold(at p: NSPoint) -> Bool {
        guard let lm = layoutManager as? BlockLayoutManager else { return false }
        let o = textContainerOrigin
        for b in lm.blocks where b.fold != nil {
            guard let r = lm.foldArrowRect(b)?.offsetBy(dx: o.x, dy: o.y).insetBy(dx: -4, dy: -4), r.contains(p) else { continue }
            toggleFold(blockAt: b.range)
            return true
        }
        return false
    }

    /// Flips the "+"/"-" of the callout starting at `range` (only its first line changes).
    func toggleFold(blockAt range: NSRange) {
        let ns = string as NSString
        var line = ns.lineRange(for: NSRange(location: range.location, length: 0))
        if ns.substring(with: line).hasSuffix("\n") { line.length -= 1 }
        let header = ns.substring(with: line)
        let folding = !Blocks.isFolded(header)
        let new = Blocks.setFold(header, folded: folding)
        guard new != header, shouldChangeText(in: line, replacementString: new) else { return }
        let caret = selectedRange()
        textStorage?.replaceCharacters(in: line, with: new)
        didChangeText()
        let shift = (new as NSString).length - line.length
        let titleEnd = NSMaxRange(line) + shift
        // Folded with the caret inside: the caret goes up to the title, or the toggle would stay open.
        if folding, caret.location > titleEnd, caret.location <= NSMaxRange(range) + shift {
            setSelectedRange(NSRange(location: titleEnd, length: 0))
        } else {
            setSelectedRange(NSRange(location: caret.location > line.location ? caret.location + shift : caret.location, length: caret.length))
        }
    }

    /// "[[Note#^id]]" (or "[[Note#Heading]]") on the clipboard; the block gets its "^id" if it had none.
    func copyLink(toBlock index: Int) {
        guard let link = Blocks.blockLink(string, index: index) else { return }
        if link.text != string {
            let caret = selectedRange()
            clearBlockSelection()
            replaceAll(with: link.text)
            setSelectedRange(NSRange(location: min(caret.location, (link.text as NSString).length), length: 0))
        }
        let note = coordinator?.parent.noteURL?.deletingPathExtension().lastPathComponent ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[[\(note)#\(link.anchor)]]", forType: .string)
        coordinator?.parent.state.show("Ссылка на блок скопирована")
    }

    /// Moves the block into a new note next to this one and leaves "[[New note]]" in its place.
    func turnIntoPage(_ index: Int) {
        guard let vault = coordinator?.parent.vault, let noteID = coordinator?.parent.noteID,
              let page = Blocks.page(from: string, index: index) else { return }
        let folder = (noteID as NSString).deletingLastPathComponent
        do {
            let id = try vault.createNote(titled: page.title, inFolder: folder, text: page.body + "\n")
            let title = ((id as NSString).lastPathComponent as NSString).deletingPathExtension
            let new = Blocks.replace(string, index: index, with: "[[\(title)]]")
            clearBlockSelection()
            replaceAll(with: new)
            if let r = Blocks.range(of: index, in: new) { setSelectedRange(NSRange(location: NSMaxRange(r), length: 0)) }
            coordinator?.parent.state.show("Страница «\(title)» создана")
            Task { await vault.reload() }
        } catch {
            vault.errorMessage = "Не удалось создать страницу: \(error.localizedDescription)"
        }
    }

    // MARK: Block shortcuts

    /// ⌘⌥0…8 turn into, ⌘D duplicate, ⌘↩ ticks a task or folds a toggle, ⌘⌥T folds all toggles,
    /// ⌘/ opens the block menu. True if the key was one of them.
    func handleBlockHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control) else { return false }
        let option = flags.contains(.option), shift = flags.contains(.shift)
        if option, !shift {
            // Physical keys, so they work on any layout.
            let kinds: [UInt16: BlockKind] = [29: .text, 18: .h1, 19: .h2, 20: .h3, 21: .task, 23: .bullet, 22: .numbered, 26: .toggle, 28: .code]
            if let kind = kinds[event.keyCode], let g = caretGroup {
                let sel = blockSelection
                if g.count == 1 && sel == nil { turnBlock(g.lowerBound, into: kind) } else { turnBlocks(g, into: kind) }
                return true
            }
            if event.keyCode == 17 {                                        // ⌘⌥T
                let new = Blocks.toggleAllFolds(string)
                guard new != string else { return true }
                let caret = selectedRange()
                clearBlockSelection()
                replaceAll(with: new)
                setSelectedRange(NSRange(location: min(caret.location, (new as NSString).length), length: 0))
                return true
            }
            return false
        }
        if option || shift { return false }
        switch event.keyCode {
        case 2 where blockSelection == nil:                                 // ⌘D
            guard let g = caretGroup else { return true }
            let offset = selectedRange().location - blocks[g.lowerBound].range.location
            let new = Blocks.duplicate(string, range: g)
            guard new != string else { return true }
            replaceAll(with: new)
            if let r = Blocks.range(of: g.upperBound, in: new) {            // the caret goes into the copy
                setSelectedRange(NSRange(location: r.location + min(max(offset, 0), r.length), length: 0))
            }
            return true
        case 36, 76:                                                        // ⌘↩
            guard let i = Blocks.index(of: selectedRange().location, in: blocks) else { return false }
            let ns = string as NSString
            var line = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
            if ns.substring(with: line).hasSuffix("\n") { line.length -= 1 }
            let text = ns.substring(with: line)
            // A task, also inside a toggle or a coloured block ("> - [ ] …"): ticked like a click on its box.
            if let box = text.range(of: #"^[ \t>]*[-*+][ \t]+\[[ xX]\]"#, options: .regularExpression) {
                let quoted = text.trimmingCharacters(in: .whitespaces).hasPrefix(">")
                let mark = text.index(box.upperBound, offsetBy: -2)
                let new = quoted ? text.replacingCharacters(in: mark..<text.index(after: mark), with: text[mark] == " " ? "x" : " ")
                                 : Tasks.toggled(text)
                let caret = selectedRange()
                if shouldChangeText(in: line, replacementString: new) {
                    textStorage?.replaceCharacters(in: line, with: new)
                    didChangeText()
                    setSelectedRange(NSRange(location: min(caret.location, line.location + (new as NSString).length), length: 0))
                }
                return true
            }
            if Blocks.isFoldable(ns.substring(with: ns.lineRange(for: NSRange(location: blocks[i].range.location, length: 0)))) {
                toggleFold(blockAt: blocks[i].range)
                return true
            }
            return false
        case 44:                                                            // ⌘/
            guard let g = caretGroup, let menu = blockMenu(g) else { return true }
            if blockSelection == nil { selectBlocks(from: g.lowerBound, to: g.upperBound - 1) }
            let r = rect(of: g)
            menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.minY - 4), in: self)
            return true
        default:
            return false
        }
    }

    // MARK: Selected blocks

    /// Selects the blocks from `a` to `b` (inclusive, in either order); `a` stays the anchor for ⇧.
    func selectBlocks(from a: Int, to b: Int) {
        let count = blocks.count
        guard count > 0 else { return }
        let a = min(max(a, 0), count - 1), b = min(max(b, 0), count - 1)
        let group = min(a, b)..<(max(a, b) + 1)
        if blockSelection == nil {
            // The text's own selection colour is hidden: the whole blocks are tinted instead.
            savedSelectionAttributes = selectedTextAttributes
            selectedTextAttributes = [.backgroundColor: NSColor.clear]
        }
        blockSelection = group
        blockAnchor = a
        blockCursor = b
        let all = blocks
        let start = all[group.lowerBound].range.location
        let end = NSMaxRange(all[group.upperBound - 1].range)
        setSelectedRange(NSRange(location: start, length: end - start))
        showSelectionShade(group)
        scrollToVisible(rect(of: all[b]).insetBy(dx: 0, dy: -12))
    }

    func showSelectionShade(_ group: Range<Int>) {
        guard let shade = selectionShade else { return }
        shade.frame = rect(of: group).insetBy(dx: -8, dy: -4)
        shade.isHidden = false
    }

    func clearBlockSelection() {
        guard blockSelection != nil else { return }
        blockSelection = nil
        blockAnchor = nil
        blockCursor = nil
        if let saved = savedSelectionAttributes { selectedTextAttributes = saved }
        savedSelectionAttributes = nil
        selectionShade?.isHidden = true
    }

    /// Leaves block selection with the caret at the end of the selected blocks.
    func leaveBlockSelection() {
        guard let sel = blockSelection else { return }
        let end = NSMaxRange(blocks[min(sel.upperBound, blocks.count) - 1].range)
        clearBlockSelection()
        setSelectedRange(NSRange(location: end, length: 0))
    }

    /// Keys while blocks are selected. Returns false to let the key through (after leaving the selection).
    func handleBlockSelectionKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard let sel = blockSelection else { return false }
        let shift = flags.contains(.shift), option = flags.contains(.option)
        if flags.contains(.command) { return false }       // ⌘-shortcuts go through performKeyEquivalent
        switch event.keyCode {
        case 51, 117:                                       // ⌫ / ⌦
            deleteBlocks(sel); return true
        case 53, 36, 76:                                    // Esc / Return: back to typing
            leaveBlockSelection(); return true
        case 126, 125:                                      // ↑ / ↓
            let d = event.keyCode == 126 ? -1 : 1
            if option && shift { moveBlocks(sel, by: d); return true }
            let cursor = (blockCursor ?? (d < 0 ? sel.lowerBound : sel.upperBound - 1)) + d
            if shift {
                selectBlocks(from: blockAnchor ?? sel.lowerBound, to: cursor)
            } else {
                let next = d < 0 ? sel.lowerBound - 1 : sel.upperBound
                selectBlocks(from: next, to: next)
            }
            return true
        default:
            leaveBlockSelection()
            return false
        }
    }

    func moveBlocks(_ group: Range<Int>, by delta: Int) {
        let to = delta < 0 ? group.lowerBound - 1 : group.upperBound + 1
        guard to >= 0, to <= blocks.count, let moved = Blocks.move(string, range: group, to: to) else { return }
        replaceAll(with: moved.text)
        selectBlocks(from: moved.range.lowerBound, to: moved.range.upperBound - 1)
    }

    func duplicateBlocks(_ group: Range<Int>) {
        let new = Blocks.duplicate(string, range: group)
        guard new != string else { return }
        replaceAll(with: new)
        selectBlocks(from: group.upperBound, to: group.upperBound + group.count - 1)
    }

    func deleteBlocks(_ group: Range<Int>) {
        let at = blocks[group.lowerBound].range.location
        let new = Blocks.delete(string, range: group)
        clearBlockSelection()
        replaceAll(with: new)
        setSelectedRange(NSRange(location: min(at, (new as NSString).length), length: 0))
        hideHandle()
    }

    func copyBlocks(_ group: Range<Int>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Blocks.markdown(string, range: group), forType: .string)
    }

    func turnBlocks(_ group: Range<Int>, into kind: BlockKind) {
        // Bottom to top, so the blocks above keep their numbers while the ones below change.
        var text = string
        for i in group.reversed() { text = Blocks.turn(text, index: i, into: kind) }
        guard text != string else { return }
        replaceAll(with: text)
        let count = Blocks.blocks(in: text).count
        if group.upperBound <= count { selectBlocks(from: group.lowerBound, to: group.upperBound - 1) }
    }

    /// Dragging in the left margin selects whole blocks; a click there selects one.
    func trackBlockBand(from start: Int) {
        guard let window else { return }
        window.makeFirstResponder(self)
        selectBlocks(from: start, to: start)
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            autoscroll(with: event)
            let p = convert(event.locationInWindow, from: nil)
            if let i = blockNearest(toY: p.y), i != blockCursor { selectBlocks(from: start, to: i) }
        }
    }
}
#endif

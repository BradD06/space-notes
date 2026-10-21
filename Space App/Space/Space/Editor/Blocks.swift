import Foundation

/// Notion-style blocks on top of plain Markdown.
///
/// The note stays an ordinary .md file. A "block" is one paragraph-like unit of it: a line of text, a heading,
/// a list item together with its nested items, a whole quote or callout, a fenced code block, a table,
/// or the frontmatter. Blank lines between blocks are gaps: moving blocks reorders their contents and keeps
/// the gaps where they were, so the spacing of the note doesn't change.
nonisolated enum BlockKind: String, CaseIterable, Sendable {
    case text, h1, h2, h3, bullet, numbered, task, quote, callout, code, table, columns, gallery, divider

    var title: String {
        switch self {
        case .text: "Текст"
        case .h1: "Заголовок 1"
        case .h2: "Заголовок 2"
        case .h3: "Заголовок 3"
        case .bullet: "Маркированный список"
        case .numbered: "Нумерованный список"
        case .task: "Задача"
        case .quote: "Цитата"
        case .callout: "Выноска"
        case .code: "Код"
        case .table: "Таблица"
        case .columns: "Колонки"
        case .gallery: "Галерея"
        case .divider: "Разделитель"
        }
    }

    var icon: String {
        switch self {
        case .text: "textformat"
        case .h1: "textformat.size.larger"
        case .h2: "textformat.size"
        case .h3: "textformat.size.smaller"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .task: "checkmark.square"
        case .quote: "text.quote"
        case .callout: "exclamationmark.bubble"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .table: "tablecells"
        case .columns: "rectangle.split.2x1"
        case .gallery: "square.grid.2x2"
        case .divider: "minus"
        }
    }

    /// Extra words the "/" menu matches, so "/h1", "/todo" or "/список" all work.
    var keywords: [String] {
        switch self {
        case .text: ["text", "paragraph", "абзац", "текст"]
        case .h1: ["h1", "heading", "title", "заголовок"]
        case .h2: ["h2", "heading", "заголовок"]
        case .h3: ["h3", "heading", "заголовок"]
        case .bullet: ["bullet", "list", "ul", "список", "маркер"]
        case .numbered: ["numbered", "list", "ol", "список", "номер"]
        case .task: ["todo", "task", "check", "задача", "чек"]
        case .quote: ["quote", "цитата"]
        case .callout: ["callout", "note", "выноска", "заметка"]
        case .code: ["code", "код"]
        case .table: ["table", "таблица"]
        case .columns: ["columns", "колонки", "столбцы", "layout"]
        case .gallery: ["gallery", "галерея", "библиотека", "library", "cards", "карточки", "books", "книги", "database", "база"]
        case .divider: ["divider", "line", "hr", "разделитель", "линия"]
        }
    }

    /// Kinds a block can be turned into (tables and dividers are only inserted).
    static let convertible: [BlockKind] = [.text, .h1, .h2, .h3, .bullet, .numbered, .task, .quote, .callout, .code]

    /// The Markdown a single line of this kind starts with.
    var linePrefix: String {
        switch self {
        case .text, .code, .table, .columns, .gallery, .divider: ""
        case .h1: "# "
        case .h2: "## "
        case .h3: "### "
        case .bullet: "- "
        case .numbered: "1. "
        case .task: "- [ ] "
        case .quote: "> "
        case .callout: "> [!note] "
        }
    }

    /// What the "/" menu inserts, and where the caret goes in it.
    var snippet: (text: String, caret: Int) {
        switch self {
        case .code: ("```\n\n```", 4)
        case .table: ("| Колонка | Колонка |\n| --- | --- |\n|  |  |", 2)
        case .divider: ("---\n", 4)
        case .columns: (Blocks.columnsMarkdown(["", ""]).joined(separator: "\n") + "\n", 0)
        case .gallery: (GallerySpec().markdown + "\n", (GallerySpec().markdown as NSString).length + 1)
        default: (linePrefix, (linePrefix as NSString).length)
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        return q.isEmpty || title.lowercased().contains(q) || keywords.contains { $0.hasPrefix(q) }
    }
}

nonisolated struct TextBlock: Equatable, Sendable {
    /// The block's lines (indices into the note split by "\n").
    var lines: Range<Int>
    /// Its characters (UTF-16), without the newline after the last line.
    var range: NSRange
    var kind: BlockKind
}

nonisolated enum Blocks {

    // MARK: Reading

    static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    static func blocks(in text: String) -> [TextBlock] {
        let lines = Self.lines(text)
        var offsets: [Int] = []
        var o = 0
        for l in lines { offsets.append(o); o += (l as NSString).length + 1 }

        func block(_ a: Int, _ b: Int) -> TextBlock {
            let start = offsets[a]
            let end = offsets[b] + (lines[b] as NSString).length
            return TextBlock(lines: a..<(b + 1), range: NSRange(location: start, length: end - start), kind: kind(of: lines[a]))
        }

        var result: [TextBlock] = []
        var i = 0
        // Frontmatter: everything between the opening and closing "---" at the very top.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) {
            var b = block(0, close)
            b.kind = .text
            result.append(b)
            i = close + 1
        }
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { i += 1; continue }
            var end = i
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                let fence = String(t.prefix(3))
                var j = i + 1
                while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { j += 1 }
                end = min(j, lines.count - 1)
            } else if t.hasPrefix("|") {
                while end + 1 < lines.count, lines[end + 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") { end += 1 }
            } else if t.hasPrefix(">") {
                while end + 1 < lines.count, lines[end + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") { end += 1 }
            } else if isListItem(t) {
                // A list item carries its nested items and continuation lines along.
                let indent = indentWidth(lines[i])
                while end + 1 < lines.count {
                    let next = lines[end + 1]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty || indentWidth(next) <= indent { break }
                    end += 1
                }
            }
            result.append(block(i, end))
            i = end + 1
        }
        return result
    }

    static func index(of location: Int, in blocks: [TextBlock]) -> Int? {
        blocks.firstIndex { location >= $0.range.location && location <= NSMaxRange($0.range) }
    }

    static func kind(of line: String) -> BlockKind {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") || t.hasPrefix("~~~") { return .code }
        if t.hasPrefix("|") { return .table }
        if t == "---" || t == "***" || t == "___" { return .divider }
        if t.hasPrefix("### ") { return .h3 }
        if t.hasPrefix("## ") { return .h2 }
        if t.hasPrefix("# ") { return .h1 }
        if t.range(of: #"^[-*+]\s+\[[ xX]\]"#, options: .regularExpression) != nil { return .task }
        if t.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil { return .bullet }
        if t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil { return .numbered }
        if isColumnsHeader(t) { return .columns }
        if t.range(of: #"^>\s?\[!"#, options: .regularExpression) != nil { return .callout }
        if t.hasPrefix(">") { return .quote }
        return .text
    }

    private static func isListItem(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil
    }

    private static func indentWidth(_ line: String) -> Int {
        var w = 0
        for c in line {
            if c == " " { w += 1 } else if c == "\t" { w += 4 } else { break }
        }
        return w
    }

    // MARK: Changing

    /// The note cut into gaps (blank lines) and blocks, in order.
    private enum Piece { case gap([String]), block([String]) }

    private static func pieces(_ text: String) -> [Piece] {
        let lines = Self.lines(text)
        var out: [Piece] = []
        var at = 0
        for b in blocks(in: text) {
            if b.lines.lowerBound > at { out.append(.gap(Array(lines[at..<b.lines.lowerBound]))) }
            out.append(.block(Array(lines[b.lines])))
            at = b.lines.upperBound
        }
        if at < lines.count { out.append(.gap(Array(lines[at...]))) }
        return out
    }

    private static func join(_ pieces: [Piece]) -> String {
        pieces.flatMap { p -> [String] in
            switch p { case .gap(let l), .block(let l): l }
        }.joined(separator: "\n")
    }

    /// Moves block `from` so that it lands before the block now at `to` (`to == count` means at the end).
    /// Gaps stay in place. Returns the new text and the moved block's new index, or nil if nothing moves.
    static func move(_ text: String, from: Int, to: Int) -> (text: String, index: Int)? {
        guard let m = move(text, range: from..<(from + 1), to: to) else { return nil }
        return (m.text, m.range.lowerBound)
    }

    /// Moves several neighbouring blocks together, so they land before the block now at `to`.
    static func move(_ text: String, range: Range<Int>, to: Int) -> (text: String, range: Range<Int>)? {
        var ps = pieces(text)
        let slots = ps.indices.filter { if case .block = ps[$0] { true } else { false } }
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= slots.count else { return nil }
        let to = min(max(to, 0), slots.count)
        guard to < range.lowerBound || to > range.upperBound else { return nil }   // dropped onto itself
        var contents = slots.map { s -> [String] in if case .block(let l) = ps[s] { l } else { [] } }
        let moving = Array(contents[range])
        contents.removeSubrange(range)
        let target = to > range.upperBound ? to - range.count : to
        contents.insert(contentsOf: moving, at: target)
        for (k, s) in slots.enumerated() { ps[s] = .block(contents[k]) }
        return (join(ps), target..<(target + range.count))
    }

    /// Copies of several neighbouring blocks right after them (with the gaps between them).
    static func duplicate(_ text: String, range: Range<Int>) -> String {
        var ps = pieces(text)
        let slots = ps.indices.filter { if case .block = ps[$0] { true } else { false } }
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= slots.count else { return text }
        let first = slots[range.lowerBound], last = slots[range.upperBound - 1]
        var insert: [Piece] = []
        if last + 1 < ps.count, case .gap(let g) = ps[last + 1], last + 2 < ps.count { insert.append(.gap(g)) }
        else { insert.append(.gap([""])) }
        insert.append(contentsOf: ps[first...last])
        ps.insert(contentsOf: insert, at: last + 1)
        return join(ps)
    }

    /// Removes several neighbouring blocks (and the gaps that go with them).
    static func delete(_ text: String, range: Range<Int>) -> String {
        var t = text
        for i in range.reversed() { t = delete(t, index: i) }
        return t
    }

    /// The Markdown of several neighbouring blocks, as it stands in the note.
    static func markdown(_ text: String, range: Range<Int>) -> String {
        let all = blocks(in: text)
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= all.count else { return "" }
        let start = all[range.lowerBound].range.location
        let end = NSMaxRange(all[range.upperBound - 1].range)
        return (text as NSString).substring(with: NSRange(location: start, length: end - start))
    }

    /// A copy of the block right after it, separated like the block is from what follows it.
    static func duplicate(_ text: String, index: Int) -> String {
        var ps = pieces(text)
        let slots = ps.indices.filter { if case .block = ps[$0] { true } else { false } }
        guard slots.indices.contains(index) else { return text }
        let s = slots[index]
        var insert: [Piece] = []
        if s + 1 < ps.count, case .gap(let g) = ps[s + 1], s + 2 < ps.count { insert.append(.gap(g)) }
        insert.append(ps[s])
        ps.insert(contentsOf: insert, at: s + 1)
        return join(ps)
    }

    /// Removes the block and the gap after it (or before it, for the last one).
    static func delete(_ text: String, index: Int) -> String {
        var ps = pieces(text)
        let slots = ps.indices.filter { if case .block = ps[$0] { true } else { false } }
        guard slots.indices.contains(index) else { return text }
        let s = slots[index]
        if s + 1 < ps.count, case .gap = ps[s + 1], s + 2 < ps.count {
            ps.removeSubrange(s...(s + 1))
        } else if s > 0, case .gap = ps[s - 1] {
            ps.removeSubrange((s - 1)...s)
        } else {
            ps.remove(at: s)
        }
        return join(ps)
    }

    /// Turns the block into another kind, keeping its words.
    static func turn(_ text: String, index: Int, into kind: BlockKind) -> String {
        var lines = Self.lines(text)
        let all = blocks(in: text)
        guard all.indices.contains(index) else { return text }
        let b = all[index]
        guard b.kind != .columns, kind != .columns else { return text }
        var body = Array(lines[b.lines])

        // Out of a code block: drop the fences.
        if b.kind == .code {
            if body.count >= 1 { body.removeFirst() }
            if let last = body.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") || last.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                body.removeLast()
            }
            if body.isEmpty { body = [""] }
        }

        switch kind {
        case .code:
            body = ["```"] + body.map { strip($0).content } + ["```"]
        case .quote, .callout:
            // Every line of a quote carries the marker; a callout keeps its type line first.
            let words = body.map { strip($0).content }
            body = words.enumerated().map { i, w in (i == 0 ? kind.linePrefix : "> ") + w }
        default:
            if b.kind == .quote || b.kind == .callout {
                // Out of a quote: every line loses its marker, the first gets the new one.
                body = body.enumerated().map { i, l in
                    let s = strip(l)
                    return i == 0 ? kind.linePrefix + s.content : s.content
                }
            } else {
                let s = strip(body[0])
                body[0] = s.indent + kind.linePrefix + s.content
            }
        }
        lines.replaceSubrange(b.lines, with: body)
        return lines.joined(separator: "\n")
    }

    /// A line without its block marker: (indentation, the words).
    static func strip(_ line: String) -> (indent: String, content: String) {
        let ns = line as NSString
        let re = try! NSRegularExpression(pattern: #"^([ \t]*)(?:#{1,6}\s+|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+|>\s?(?:\[![^\]]*\][+-]?\s*)?)?(.*)$"#)
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return ("", line) }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
    }

    /// Character range of block `index` in `text`.
    static func range(of index: Int, in text: String) -> NSRange? {
        let all = blocks(in: text)
        return all.indices.contains(index) ? all[index].range : nil
    }

    // MARK: Columns

    // Columns are stored as nested callouts, the way Obsidian themes lay out columns:
    //
    //   > [!multi-column]
    //   >
    //   >> [!blank]
    //   >> the first column's Markdown
    //   >
    //   >> [!blank]
    //   >> the second column's
    //
    // Without such a theme Obsidian simply shows the columns one under another, nothing is lost.

    static func isColumnsHeader(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(of: #"^>\s?\[!multi-column\]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Each column's own Markdown, from the lines of a columns block.
    static func columns(of lines: [String]) -> [String] {
        var cols: [[String]] = []
        for line in lines.dropFirst() {
            // Only the leading spaces go: a space typed at the end of a line must survive the round trip.
            var rest = line.drop(while: { $0 == " " || $0 == "\t" })
            guard rest.hasPrefix(">") else { continue }
            rest = rest.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            guard rest.hasPrefix(">") else { continue }         // a lone ">" separates columns
            rest = rest.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            if rest.range(of: #"^\[![^\]]*\][+-]?\s*$"#, options: .regularExpression) != nil {
                cols.append([])                                 // ">> [!blank]" starts the next column
                continue
            }
            if cols.isEmpty { cols.append([]) }
            cols[cols.count - 1].append(String(rest))
        }
        return cols.map { col in
            var c = col
            while let last = c.last, last.trimmingCharacters(in: .whitespaces).isEmpty { c.removeLast() }
            return c.joined(separator: "\n")
        }
    }

    /// The lines of a columns block holding these columns.
    static func columnsMarkdown(_ columns: [String]) -> [String] {
        var out = ["> [!multi-column]"]
        for col in columns {
            out.append(">")
            out.append(">> [!blank]")
            let lines = col.components(separatedBy: "\n")
            out.append(contentsOf: lines.map { $0.isEmpty ? ">>" : ">> " + $0 })
        }
        return out
    }

    /// Puts the blocks `moving` next to block `target`, on its right (or left): a new pair of columns,
    /// or one more column if the target already is columns. Returns the new text and the columns block's index.
    static func makeColumns(_ text: String, target: Int, moving: Range<Int>, right: Bool) -> (text: String, index: Int)? {
        var ps = pieces(text)
        let slots = ps.indices.filter { if case .block = ps[$0] { true } else { false } }
        guard slots.indices.contains(target), !moving.isEmpty, moving.lowerBound >= 0, moving.upperBound <= slots.count,
              !moving.contains(target) else { return nil }
        func lines(_ i: Int) -> [String] { if case .block(let l) = ps[slots[i]] { l } else { [] } }
        guard !moving.contains(where: { isColumnsHeader(lines($0).first ?? "") }) else { return nil }

        // The moved blocks become one column, with a blank line between them as in the note.
        let movedColumn = moving.map { lines($0).joined(separator: "\n") }.joined(separator: "\n\n")
        let targetLines = lines(target)
        var cols = isColumnsHeader(targetLines.first ?? "") ? columns(of: targetLines) : [targetLines.joined(separator: "\n")]
        if right { cols.append(movedColumn) } else { cols.insert(movedColumn, at: 0) }
        ps[slots[target]] = .block(columnsMarkdown(cols))
        let replaced = join(ps)

        // The moved blocks leave their old place; the columns move up by as many blocks as left above them.
        let result = delete(replaced, range: moving)
        let index = target - (moving.upperBound <= target ? moving.count : 0)
        return (result, index)
    }

    /// The columns' contents back as ordinary blocks, one after another.
    static func unwrapColumns(_ text: String, index: Int) -> String {
        var ps = pieces(text)
        let slots = ps.indices.filter { if case .block = ps[$0] { true } else { false } }
        guard slots.indices.contains(index), case .block(let l) = ps[slots[index]], isColumnsHeader(l.first ?? "") else { return text }
        let cols = columns(of: l).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        ps[slots[index]] = .block(cols.joined(separator: "\n\n").components(separatedBy: "\n"))
        return join(ps)
    }

    /// One more empty column at the end.
    static func addColumn(_ text: String, index: Int) -> String {
        var ps = pieces(text)
        let slots = ps.indices.filter { if case .block = ps[$0] { true } else { false } }
        guard slots.indices.contains(index), case .block(let l) = ps[slots[index]], isColumnsHeader(l.first ?? "") else { return text }
        ps[slots[index]] = .block(columnsMarkdown(columns(of: l) + [""]))
        return join(ps)
    }
}

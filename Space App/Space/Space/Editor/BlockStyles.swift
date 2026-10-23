import Foundation

// Notion's block colours, toggles, typing shortcuts and block links, kept as Markdown Obsidian reads:
//
//   > [!space-blue]          a block in blue text          > [!toggle]- Title       folded toggle
//   > the block's Markdown                                 > what it hides
//
//   > [!space-blue-bg]       the same on a blue background > [!toggle-h2]+ Title    open toggle heading
//
// `space-blocks.css` (Resources) styles these callouts in Obsidian so the note looks the same there.

/// Notion's nine colours.
nonisolated enum BlockColor: String, CaseIterable, Sendable {
    case gray, brown, orange, yellow, green, blue, purple, pink, red

    var title: String {
        switch self {
        case .gray: "Серый"
        case .brown: "Коричневый"
        case .orange: "Оранжевый"
        case .yellow: "Жёлтый"
        case .green: "Зелёный"
        case .blue: "Синий"
        case .purple: "Фиолетовый"
        case .pink: "Розовый"
        case .red: "Красный"
        }
    }

    /// Tuned for the dark editor; the CSS snippet uses the same values.
    var hex: UInt32 {
        switch self {
        case .gray: 0x9B9A97
        case .brown: 0xBA856F
        case .orange: 0xE59A5C
        case .yellow: 0xE8C25A
        case .green: 0x6FBF8C
        case .blue: 0x6FA8E8
        case .purple: 0xAF8BE8
        case .pink: 0xE07FB8
        case .red: 0xE8736B
        }
    }

    var keywords: [String] {
        switch self {
        case .gray: ["gray", "grey", "серый"]
        case .brown: ["brown", "коричневый"]
        case .orange: ["orange", "оранжевый"]
        case .yellow: ["yellow", "жёлтый", "желтый"]
        case .green: ["green", "зелёный", "зеленый"]
        case .blue: ["blue", "синий", "голубой"]
        case .purple: ["purple", "violet", "фиолетовый"]
        case .pink: ["pink", "розовый"]
        case .red: ["red", "красный"]
        }
    }
}

/// A block's colour: the text, or the background behind it.
nonisolated struct BlockTint: Hashable, Sendable {
    var color: BlockColor
    var background: Bool

    /// The callout type it is stored as: `space-blue`, `space-blue-bg`.
    var calloutType: String { "space-\(color.rawValue)" + (background ? "-bg" : "") }

    init(_ color: BlockColor, background: Bool) {
        self.color = color
        self.background = background
    }

    init?(calloutType raw: String) {
        var t = raw.lowercased()
        guard t.hasPrefix("space-") else { return nil }
        t.removeFirst(6)
        let bg = t.hasSuffix("-bg")
        if bg { t.removeLast(3) }
        guard let c = BlockColor(rawValue: t) else { return nil }
        self.init(c, background: bg)
    }
}

/// What the "/" menu offers: a kind of block, or a callout on a coloured background.
nonisolated enum SlashItem: Hashable, Sendable {
    case block(BlockKind)
    case color(BlockColor)

    var title: String {
        switch self {
        case .block(let k): k.title
        case .color(let c): "Выноска: \(c.title.lowercased())"
        }
    }

    var icon: String {
        switch self {
        case .block(let k): k.icon
        case .color: "circle.fill"
        }
    }

    var swatch: BlockColor? { if case .color(let c) = self { c } else { nil } }

    var snippet: (text: String, caret: Int) {
        switch self {
        case .block(let k): return k.snippet
        case .color(let c):
            let text = "> [!\(BlockTint(c, background: true).calloutType)]\n> "
            return (text, (text as NSString).length)
        }
    }

    /// Coloured callouts show only once something is typed, so the full menu stays short.
    static func items(matching query: String) -> [SlashItem] {
        let q = query.lowercased()
        var out = BlockKind.allCases.filter { $0.matches(q) }.map(SlashItem.block)
        if !q.isEmpty {
            let words = ["color", "colour", "цвет", "цветной", "callout", "выноска", "фон", "background"]
            out += BlockColor.allCases.filter { c in
                (words + c.keywords).contains { $0.hasPrefix(q) } || c.title.lowercased().hasPrefix(q)
            }.map(SlashItem.color)
        }
        return out
    }
}

nonisolated extension Blocks {

    // MARK: Colours

    private static let calloutHeader = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?\[!([^\]]+)\]([+-]?)"#)

    /// The callout type and fold marker of a callout's first line (`> [!note]-` → ("note", "-")).
    static func calloutHeader(_ line: String) -> (type: String, fold: String)? {
        let ns = line as NSString
        guard let m = calloutHeader.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
    }

    /// The colour of a block stored as a `> [!space-…]` callout.
    static func tint(of lines: [String]) -> BlockTint? {
        guard let first = lines.first, let h = calloutHeader(first) else { return nil }
        return BlockTint(calloutType: h.type)
    }

    /// A callout's contents without its header and one level of "> ".
    static func unwrapQuote(_ lines: [String]) -> [String] {
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            if i == 0, calloutHeader(line) != nil {
                // "> [!space-blue] words" keeps the words that follow the header.
                let rest = strip(line).content
                if !rest.isEmpty { out.append(rest) }
                continue
            }
            var l = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
            if l.hasPrefix(">") {
                l = l.dropFirst()
                if l.hasPrefix(" ") { l = l.dropFirst() }
            }
            out.append(String(l))
        }
        return out.isEmpty ? [""] : out
    }

    /// The lines inside a `> [!space-…]` callout.
    static func wrap(_ lines: [String], in tint: BlockTint) -> [String] {
        ["> [!\(tint.calloutType)]"] + lines.map { $0.isEmpty ? ">" : "> " + $0 }
    }

    /// Can block `index` be coloured? Not columns, the frontmatter, or callouts other than our colours.
    static func canColor(_ text: String, index: Int) -> Bool {
        let all = blocks(in: text)
        guard all.indices.contains(index) else { return false }
        let b = all[index]
        let body = Array(lines(text)[b.lines])
        if tint(of: body) != nil { return true }
        if index == 0, b.lines.lowerBound == 0, body.count > 1, body[0].trimmingCharacters(in: .whitespaces) == "---" { return false }
        return ![.columns, .callout, .gallery].contains(b.kind) && !b.kind.isToggle
    }

    /// Colours block `index` (or takes its colour away, with nil).
    static func setColor(_ text: String, index: Int, tint: BlockTint?) -> String {
        guard canColor(text, index: index) else { return text }
        var all = lines(text)
        let b = blocks(in: text)[index]
        let body = Array(all[b.lines])
        let inner = Self.tint(of: body) != nil ? unwrapQuote(body) : body
        all.replaceSubrange(b.lines, with: tint.map { wrap(inner, in: $0) } ?? inner)
        return all.joined(separator: "\n")
    }

    /// The colour of block `index`, if it has one.
    static func tint(_ text: String, index: Int) -> BlockTint? {
        let all = blocks(in: text)
        guard all.indices.contains(index) else { return nil }
        return tint(of: Array(lines(text)[all[index].lines]))
    }

    // MARK: Folding

    /// Callouts that fold: toggles, and any callout written with "+" or "-". Never columns or colours.
    static func isFoldable(_ line: String) -> Bool {
        guard let h = calloutHeader(line) else { return false }
        let type = h.type.lowercased()
        if type == "multi-column" || type == "blank" || BlockTint(calloutType: type) != nil { return false }
        return !h.fold.isEmpty || type.hasPrefix("toggle")
    }

    static func isFolded(_ line: String) -> Bool { isFoldable(line) && calloutHeader(line)?.fold == "-" }

    /// The callout's first line folded (`-`) or unfolded (`+`).
    static func setFold(_ line: String, folded: Bool) -> String {
        guard isFoldable(line), let close = line.range(of: "]") else { return line }
        var rest = line[close.upperBound...]
        if rest.first == "+" || rest.first == "-" { rest = rest.dropFirst() }
        return String(line[..<close.upperBound]) + (folded ? "-" : "+") + rest
    }

    /// Folds or unfolds the foldable callout that block `index` is.
    static func toggleFold(_ text: String, index: Int) -> String {
        let all = blocks(in: text)
        guard all.indices.contains(index) else { return text }
        var ls = lines(text)
        let first = all[index].lines.lowerBound
        guard isFoldable(ls[first]) else { return text }
        ls[first] = setFold(ls[first], folded: !isFolded(ls[first]))
        return ls.joined(separator: "\n")
    }

    /// ⌘⌥T: folds every toggle, or unfolds them all when they are all folded already.
    static func toggleAllFolds(_ text: String) -> String {
        var ls = lines(text)
        let heads = blocks(in: text).map(\.lines.lowerBound).filter { isFoldable(ls[$0]) }
        guard !heads.isEmpty else { return text }
        let fold = heads.contains { !isFolded(ls[$0]) }
        for h in heads { ls[h] = setFold(ls[h], folded: fold) }
        return ls.joined(separator: "\n")
    }

    // MARK: Typing shortcuts

    /// A change the editor makes after a keystroke: replace `range` with `replacement`, then put the caret at `caret`.
    struct Edit: Equatable, Sendable {
        var range: NSRange
        var replacement: String
        var caret: Int
    }

    /// Notion's Markdown shortcuts, checked right after `typed` went in and the caret is at `caret`:
    /// at the start of a line `[] ` → task, `" ` → quote, `* `/`+ ` → "- ", ``` and `$$` get their closing line;
    /// inside text `->` → →, `<-` → ←, `--` → —. Nothing happens in code, formulas or the frontmatter.
    static func typingShortcut(in text: String, caret: Int, typed: String) -> Edit? {
        let ns = text as NSString
        guard typed.count == 1, caret > 0, caret <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: caret - 1, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        guard !insideCodeOrMath(ns, lineStart: lineStart) else { return nil }

        switch typed {
        case " ":
            let re = try! NSRegularExpression(pattern: #"^([ \t]*)(\[\]|\[ \]|\[[xX]\]|"|\*|\+) $"#)
            let b = before as NSString
            guard let m = re.firstMatch(in: before, range: NSRange(location: 0, length: b.length)) else { return nil }
            let indent = b.substring(with: m.range(at: 1)), mark = b.substring(with: m.range(at: 2))
            let new: String
            switch mark {
            case "\"": new = "> "
            case "*", "+": new = "- "
            case "[x]", "[X]": new = "- [x] "
            default: new = "- [ ] "
            }
            let r = NSRange(location: lineStart, length: caret - lineStart)
            return Edit(range: r, replacement: indent + new, caret: lineStart + ((indent + new) as NSString).length)
        case "`":
            guard before.trimmingCharacters(in: .whitespaces) == "```" else { return nil }
            return Edit(range: NSRange(location: caret, length: 0), replacement: "\n" + before, caret: caret)
        case "$":
            guard before.trimmingCharacters(in: .whitespaces) == "$$" else { return nil }
            return Edit(range: NSRange(location: caret, length: 0), replacement: "\n\n" + before, caret: caret + 1)
        case "-", ">":
            let line = before.trimmingCharacters(in: .whitespaces)
            // Tables (|---|), HTML comments and the inside of `inline code` keep their dashes.
            guard !line.hasPrefix("|"), !before.contains("<!--"), before.filter({ $0 == "`" }).count % 2 == 0 else { return nil }
            let chars = Array(before)
            guard chars.count >= 2 else { return nil }
            let pair = String(chars[(chars.count - 2)...])
            let symbol: String
            switch pair {
            case "->": symbol = "→"
            case "<-": symbol = "←"
            case "--":
                // Not at the start of a line ("---" is a divider) and not a third dash.
                let head = chars.dropLast(2)
                guard let prev = head.last, prev != "-", prev != "!", prev != "<",
                      head.contains(where: { $0 != " " && $0 != "\t" && $0 != "-" }) else { return nil }
                symbol = "—"
            default: return nil
            }
            let r = NSRange(location: caret - (pair as NSString).length, length: (pair as NSString).length)
            return Edit(range: r, replacement: symbol, caret: r.location + 1)
        default:
            return nil
        }
    }

    /// Is the line starting at `lineStart` inside a fenced code block, a `$$` formula or the frontmatter?
    private static func insideCodeOrMath(_ ns: NSString, lineStart: Int) -> Bool {
        let above = ns.substring(to: lineStart).components(separatedBy: "\n").dropLast()
        var code = false, math = false
        for (i, l) in above.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if i == 0, t == "---" {
                // Frontmatter: open until its closing "---".
                if !above.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) { return true }
                continue
            }
            if !math, t.hasPrefix("```") || t.hasPrefix("~~~") { code.toggle(); continue }
            if !code, t.hasPrefix("$$") {
                if math { math = !t.hasSuffix("$$") } else { math = isMathOpen(t) }
            } else if math, t.hasSuffix("$$") {
                math = false
            }
        }
        return code || math
    }

    // MARK: Links to blocks

    private static let trailingID = try! NSRegularExpression(pattern: #"\s\^([A-Za-z0-9-]+)\s*$"#)
    private static let lineID = try! NSRegularExpression(pattern: #"^\s*\^([A-Za-z0-9-]+)\s*$"#)

    static func isBlockIDLine(_ line: String) -> Bool {
        lineID.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// A short random id like Obsidian's ("a1b2c3").
    static func newBlockID() -> String {
        String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    /// What `[[Note#…]]` points at for block `index`: a heading by its words, any other block by its `^id`
    /// (added when it has none: at the end of the line, or on a line of its own after quotes, callouts,
    /// tables, code and formulas, as Obsidian wants). Nil for the frontmatter and columns.
    static func blockLink(_ text: String, index: Int, newID: () -> String = newBlockID) -> (text: String, anchor: String)? {
        let all = blocks(in: text)
        guard all.indices.contains(index) else { return nil }
        let b = all[index]
        var ls = lines(text)
        let first = ls[b.lines.lowerBound]
        if index == 0, b.lines.lowerBound == 0, b.lines.count > 1, first.trimmingCharacters(in: .whitespaces) == "---" { return nil }
        if b.kind == .columns { return nil }
        if [.h1, .h2, .h3].contains(b.kind) {
            let words = strip(first).content
            let ns = words as NSString
            let clean = trailingID.firstMatch(in: words, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(to: $0.range.location) } ?? words
            return (text, clean.trimmingCharacters(in: .whitespaces))
        }
        let structured = b.kind.isQuoted || [.code, .table, .equation].contains(b.kind)
        if structured {
            let after = b.lines.upperBound
            if after + 1 < ls.count, ls[after].trimmingCharacters(in: .whitespaces).isEmpty,
               let m = lineID.firstMatch(in: ls[after + 1], range: NSRange(location: 0, length: (ls[after + 1] as NSString).length)) {
                return (text, "^" + (ls[after + 1] as NSString).substring(with: m.range(at: 1)))
            }
            let id = newID()
            var insert = ["", "^" + id]
            if after < ls.count, !ls[after].trimmingCharacters(in: .whitespaces).isEmpty { insert.append("") }
            ls.insert(contentsOf: insert, at: after)
            return (ls.joined(separator: "\n"), "^" + id)
        }
        let ns = first as NSString
        if let m = trailingID.firstMatch(in: first, range: NSRange(location: 0, length: ns.length)) {
            return (text, "^" + ns.substring(with: m.range(at: 1)))
        }
        let id = newID()
        var line = first
        while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
        ls[b.lines.lowerBound] = line + " ^" + id
        return (ls.joined(separator: "\n"), "^" + id)
    }

    // MARK: Turning a block into a page

    /// The title and Markdown of a new note made from block `index`: a heading or toggle gives its title and
    /// its contents; any other block is named after its first words and moves whole.
    static func page(from text: String, index: Int) -> (title: String, body: String)? {
        let all = blocks(in: text)
        guard all.indices.contains(index), all[index].kind != .columns else { return nil }
        let b = all[index]
        let body = Array(lines(text)[b.lines])
        var title = strip(body[0]).content
        var content = body
        if b.kind.isToggle {
            content = Array(unwrapQuote(body).dropFirst(strip(body[0]).content.isEmpty ? 0 : 1))
        } else if [.h1, .h2, .h3].contains(b.kind) {
            content = Array(body.dropFirst())
        } else if b.kind == .code || b.kind == .equation || b.kind == .table || tint(of: body) != nil {
            title = strip(unwrapQuote(body).first ?? "").content
        }
        return (pageTitle(title), content.joined(separator: "\n"))
    }

    /// Words fit for a file name: no Markdown, links, block ids or characters files can't have.
    static func pageTitle(_ raw: String) -> String {
        var t = raw
        if let m = trailingID.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) {
            t = (t as NSString).substring(to: m.range.location)
        }
        t = t.replacingOccurrences(of: #"\[\[([^\]|]*\|)?([^\]]*)\]\]"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = String(t.filter { !"*_=~`#^[]|/\\:?\"<>$%".contains($0) })
        t = t.trimmingCharacters(in: .whitespaces)
        if t.count > 60 { t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return t.isEmpty ? "Без названия" : t
    }

    /// Block `index` replaced by these lines (e.g. the `[[link]]` to the page it became).
    static func replace(_ text: String, index: Int, with markdown: String) -> String {
        let all = blocks(in: text)
        guard all.indices.contains(index) else { return text }
        var ls = lines(text)
        ls.replaceSubrange(all[index].lines, with: markdown.components(separatedBy: "\n"))
        return ls.joined(separator: "\n")
    }
}

/// The CSS snippet that makes toggles, coloured blocks and columns look the same in Obsidian.
nonisolated enum ObsidianSnippet {
    static let name = "space-blocks"

    static func css() throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "css") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name + ".css"])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

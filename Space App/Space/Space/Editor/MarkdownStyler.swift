#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

extension PlatformColor {
    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> PlatformColor {
        let r = CGFloat((v >> 16) & 0xFF) / 255, g = CGFloat((v >> 8) & 0xFF) / 255, b = CGFloat(v & 0xFF) / 255
        #if os(macOS)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
        #endif
    }
}

/// Look of the editor. Same palette as the rest of Space.
struct EditorTheme {
    var bodySize: CGFloat = 17
    let ink = PlatformColor.hex(0xECE8DF)
    let muted = PlatformColor.hex(0x8A8F9C)
    let faint = PlatformColor.hex(0x5A6070)
    let accent = PlatformColor.hex(0xF2B544)
    let link = PlatformColor.hex(0x8FB3FF)
    let unresolved = PlatformColor.hex(0x8FB3FF, 0.55)
    let tag = PlatformColor.hex(0xC9A0FF)
    let tagBackground = PlatformColor.hex(0xC9A0FF, 0.14)
    let codeBackground = PlatformColor.hex(0xFFFFFF, 0.06)
    let highlight = PlatformColor.hex(0xF2B544, 0.28)
    let quote = PlatformColor.hex(0xC9C5BC)

    static let headingScale: [CGFloat] = [1.85, 1.55, 1.32, 1.16, 1.06, 1.0]

    private static var cache: [String: PlatformFont] = [:]

    /// Serif body text (as in the rest of the app), sans for headings, mono for code.
    func font(size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false, serif: Bool = true) -> PlatformFont {
        let key = "\(size)|\(bold)|\(italic)|\(mono)|\(serif)"
        if let f = Self.cache[key] { return f }
        let f: PlatformFont
        if mono {
            f = PlatformFont.monospacedSystemFont(ofSize: size * 0.88, weight: bold ? .semibold : .regular)
        } else {
            let base = PlatformFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            var d = base.fontDescriptor
            if serif, let s = d.withDesign(.serif) { d = s }
            #if os(macOS)
            if italic { d = d.withSymbolicTraits(d.symbolicTraits.union(.italic)) }
            f = NSFont(descriptor: d, size: size) ?? base
            #else
            if italic, let s = d.withSymbolicTraits(d.symbolicTraits.union(.traitItalic)) { d = s }
            f = UIFont(descriptor: d, size: size)
            #endif
        }
        Self.cache[key] = f
        return f
    }

    var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = bodySize * 0.32
        p.paragraphSpacing = bodySize * 0.35
        return p
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font(size: bodySize), .foregroundColor: ink, .paragraphStyle: paragraph]
    }
}

/// Live-preview styling in the spirit of Obsidian: Markdown stays plain text in the file,
/// the editor shows it formatted. Syntax characters (`**`, `##`, `[[ ]]` …) are hidden on every
/// line except the one being edited, where they reappear dimmed so they can be changed.
struct MarkdownStyler {
    var theme = EditorTheme()
    /// Columns are shown by editors laid over the text (macOS). When on, a columns block's own Markdown is
    /// hidden and keeps room of `columnHeights[k]` points for the k-th columns block of the note.
    var columnsEnabled = false
    var columnHeights: [CGFloat] = []
    /// Height kept for the properties panel shown over the frontmatter (same overlays as columns).
    var propertiesHeight: CGFloat = 80
    /// The properties panel is hidden: its frontmatter collapses to nothing.
    var propertiesHidden = false
    /// ```gallery blocks shown as card grids on top (macOS, with the vault at hand); room kept for each.
    var galleriesEnabled = false
    var galleryHeights: [CGFloat] = []
    /// ```dataview blocks shown as their query's results (macOS); room kept for each, by the block's text.
    /// A block the caret is in shows its Markdown, so the query can be edited.
    var dataviewEnabled = false
    var dataviewHeights: [String: CGFloat] = [:]
    /// Does `[[target]]` point to an existing note?
    var resolves: (String) -> Bool = { _ in true }
    /// The picture an embed points to (`![[photo.png]]`, `![](photo.png)`), if it is one and it exists.
    var image: (String) -> PlatformImage? = { _ in nil }
    /// Widest a picture may be drawn: the text column.
    var imageWidth: CGFloat = 560

    static let noteScheme = "space-note"
    static let taskScheme = "space-task"

    // Block level
    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})([ \\t]+)(.*)$")
    private static let fence = try! NSRegularExpression(pattern: "^[ \\t]*(```|~~~)(.*)$")
    private static let quote = try! NSRegularExpression(pattern: "^((?:>[ \\t]?)+)(.*)$")
    private static let callout = try! NSRegularExpression(pattern: "^>[ \\t]?\\[!([A-Za-z]+)\\][+-]?[ \\t]*(.*)$")
    private static let task = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+])[ \\t]+(\\[[ xX]\\])[ \\t]+")
    private static let list = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+]|\\d+[.)])[ \\t]+")
    private static let rule = try! NSRegularExpression(pattern: "^[ \\t]*([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")
    // Inline
    private static let code = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let wikilink = try! NSRegularExpression(pattern: "(!?)\\[\\[([^\\[\\]\\n|#]+)(#[^\\[\\]\\n|]*)?(?:\\|([^\\[\\]\\n]+))?\\]\\]")
    private static let mdLink = try! NSRegularExpression(pattern: "(!?)\\[([^\\[\\]\\n]*)\\]\\(([^)\\s]+)\\)")
    private static let footnote = try! NSRegularExpression(pattern: "\\[\\^[^\\]\\s]+\\]")
    private static let comment = try! NSRegularExpression(pattern: "%%.*?%%")
    private static let blockID = try! NSRegularExpression(pattern: "(?<=\\s)\\^[A-Za-z0-9-]+$")
    // A picture alone on its line: ![[photo.png|300]] or ![alt|300](photo.png)
    private static let embedLine = try! NSRegularExpression(pattern: "^[ \\t]*!\\[\\[([^\\[\\]\\n|#]+)(?:\\|(\\d+)(?:x(\\d+))?)?\\]\\][ \\t]*$")
    private static let imageLine = try! NSRegularExpression(pattern: "^[ \\t]*!\\[([^\\]\\n]*?)(?:\\|(\\d+)(?:x(\\d+))?)?\\]\\(([^)\\n]+)\\)[ \\t]*$")
    private static let bold = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicStar = try! NSRegularExpression(pattern: "(?<![\\*\\w])\\*(?![\\s\\*])(.+?)(?<![\\s\\*])\\*(?![\\*\\w])")
    private static let italicUnderscore = try! NSRegularExpression(pattern: "(?<![_\\w])_(?![\\s_])(.+?)(?<![\\s_])_(?![_\\w])")
    private static let strike = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")
    private static let mark = try! NSRegularExpression(pattern: "==(?=\\S)(.+?)(?<=\\S)==")
    private static let tag = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_/#&])#[\\p{L}_][\\p{L}\\p{N}_/-]*")
    private static let url = try! NSRegularExpression(pattern: "https?://[^\\s<>()\\[\\]]+")

    /// Restyles the whole text and returns the blocks (code, tables, quotes) the layout manager
    /// draws as boxes behind the text. `active` is the selection; what it touches shows its syntax.
    @discardableResult
    func apply(to storage: NSTextStorage, active: NSRange?, revealAll: Bool) -> [EditorBlock] {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(theme.baseAttributes, range: full)
        guard ns.length > 0 else { return [] }

        func touches(_ r: NSRange) -> Bool {
            if revealAll { return true }
            guard let a = active else { return false }
            if a.location >= r.location && a.location <= NSMaxRange(r) { return true }
            return a.length > 0 && NSIntersectionRange(a, r).length > 0
        }

        var lines: [NSRange] = []
        ns.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, r, _, _ in lines.append(r) }
        let str = ns as String
        var blocks: [EditorBlock] = []

        var i = 0
        if columnsEnabled, !revealAll, let fm = Properties.frontmatter(in: ns), Properties.parse(fm.yaml) != nil {
            // Shown as Obsidian's properties table: the YAML keeps the room, the panel sits on top.
            reserve(storage, ns: ns, lines: lines.filter { $0.location < NSMaxRange(fm.range) }, height: propertiesHidden ? 0.01 : propertiesHeight, spaced: !propertiesHidden)
            blocks.append(EditorBlock(kind: .properties, range: fm.range))
            while i < lines.count && lines[i].location < NSMaxRange(fm.range) { i += 1 }
        } else if let fm = frontmatterRange(ns) {
            storage.addAttributes([.font: theme.font(size: theme.bodySize * 0.82, mono: true), .foregroundColor: theme.muted], range: fm)
            while i < lines.count && lines[i].location < NSMaxRange(fm) { i += 1 }
        }

        while i < lines.count {
            let line = lines[i]

            // ``` code block: from the opening fence to the closing one (or the end of the note)
            if let open = Self.fence.firstMatch(in: str, range: line) {
                let marker = ns.substring(with: open.range(at: 1))
                var j = i + 1
                while j < lines.count, !(Self.fence.firstMatch(in: str, range: lines[j]).map { ns.substring(with: $0.range(at: 1)) == marker } ?? false) { j += 1 }
                let last = min(j, lines.count - 1)
                let range = NSRange(location: line.location, length: NSMaxRange(lines[last]) - line.location)
                let lang = ns.substring(with: open.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if galleriesEnabled, !revealAll, lang.lowercased() == GallerySpec.language {
                    let k = blocks.filter { $0.kind == .gallery }.count
                    reserve(storage, ns: ns, lines: Array(lines[i...last]), height: k < galleryHeights.count ? galleryHeights[k] : 240)
                    blocks.append(EditorBlock(kind: .gallery, range: range))
                    i = last + 1
                    continue
                }
                if dataviewEnabled, !revealAll, lang.lowercased() == Dataview.language, j < lines.count, !touches(range) {
                    reserve(storage, ns: ns, lines: Array(lines[i...last]), height: dataviewHeights[ns.substring(with: range)] ?? 120)
                    blocks.append(EditorBlock(kind: .dataview, range: range))
                    i = last + 1
                    continue
                }
                styleCode(storage, ns: ns, lines: Array(lines[i...last]), closed: j < lines.count, lang: lang, active: touches(range))
                blocks.append(EditorBlock(kind: .code(language: lang), range: range))
                i = last + 1
                continue
            }

            // | table | rows: a header row followed by a |---|---| separator
            if isTableRow(ns, line), i + 1 < lines.count, Self.tableSeparator.firstMatch(in: str, range: lines[i + 1]) != nil {
                var j = i + 2
                while j < lines.count, isTableRow(ns, lines[j]) { j += 1 }
                let rows = Array(lines[i..<j])
                let range = NSRange(location: line.location, length: NSMaxRange(rows.last!) - line.location)
                let active = touches(range)
                let columns = styleTable(storage, ns: ns, rows: rows, active: active)
                blocks.append(EditorBlock(kind: active ? .rawTable : .table(columnWidths: columns), range: range,
                                          rows: rows.enumerated().filter { $0.offset != 1 }.map(\.element)))
                i = j
                continue
            }

            // > quotes and > [!callouts]: consecutive quote lines form one block
            if Self.quote.firstMatch(in: str, range: line) != nil {
                var j = i + 1
                while j < lines.count, Self.quote.firstMatch(in: str, range: lines[j]) != nil { j += 1 }
                let group = Array(lines[i..<j])
                let range = NSRange(location: line.location, length: NSMaxRange(group.last!) - line.location)
                if columnsEnabled, !revealAll, Blocks.isColumnsHeader(ns.substring(with: line)) {
                    let k = blocks.filter { $0.kind == .columns }.count
                    reserve(storage, ns: ns, lines: group, height: k < columnHeights.count ? columnHeights[k] : 60)
                    blocks.append(EditorBlock(kind: .columns, range: range))
                    i = j
                    continue
                }
                var kind = EditorBlock.Kind.quote
                if let c = Self.callout.firstMatch(in: str, range: line) { kind = .callout(color: calloutColor(ns.substring(with: c.range(at: 1)))) }
                // Code blocks may live inside quotes and callouts ("> ```swift"): they get their own box.
                var nested: [EditorBlock] = []
                var k = 0
                while k < group.count {
                    let l = group[k]
                    guard let q = Self.quote.firstMatch(in: str, range: l) else { k += 1; continue }
                    if let f = Self.fence.firstMatch(in: str, range: q.range(at: 2)) {
                        let marker = ns.substring(with: f.range(at: 1))
                        var e = k + 1
                        while e < group.count {
                            if let qe = Self.quote.firstMatch(in: str, range: group[e]),
                               let fe = Self.fence.firstMatch(in: str, range: qe.range(at: 2)),
                               ns.substring(with: fe.range(at: 1)) == marker { break }
                            e += 1
                        }
                        let last = min(e, group.count - 1)
                        let sub = Array(group[k...last])
                        let blockRange = NSRange(location: sub[0].location, length: NSMaxRange(sub[sub.count - 1]) - sub[0].location)
                        let act = touches(blockRange)
                        var contents: [NSRange] = [], prefixes: [NSRange] = []
                        for line in sub {
                            if let qm = Self.quote.firstMatch(in: str, range: line) {
                                prefixes.append(qm.range(at: 1))
                                contents.append(qm.range(at: 2))
                            }
                        }
                        let lang = ns.substring(with: f.range(at: 2)).trimmingCharacters(in: .whitespaces)
                        styleCode(storage, ns: ns, lines: contents, closed: e < group.count, lang: lang, active: act, indent: 18)
                        for p in prefixes { hide(storage, p, active: act) }   // after styleCode, which restyles whole paragraphs
                        nested.append(EditorBlock(kind: .code(language: lang), range: blockRange, indent: 18))
                        k = last + 1
                        continue
                    }
                    styleQuoteLine(storage, ns: ns, line: l, active: touches(l), calloutBody: k > 0 && kind != .quote)
                    k += 1
                }
                blocks.append(EditorBlock(kind: kind, range: range))
                blocks.append(contentsOf: nested)        // drawn on top of the quote background
                i = j
                continue
            }

            if let picture = embeddedImage(ns, line) {
                styleImageLine(storage, ns: ns, line: line, size: picture.size, active: touches(line))
                blocks.append(EditorBlock(kind: .image(picture.image, size: picture.size), range: line))
                i += 1
                continue
            }

            styleLine(storage, ns: ns, line: line, active: touches(line))
            i += 1
        }
        return blocks
    }

    // MARK: Columns

    /// Hides a columns block's Markdown: its first line keeps `height` points for the column editors on top,
    /// the other lines shrink to nothing.
    private func reserve(_ s: NSTextStorage, ns: NSString, lines: [NSRange], height: CGFloat, spaced: Bool = true) {
        let tiny = theme.font(size: 1, serif: false)
        for (k, line) in lines.enumerated() {
            let p = NSMutableParagraphStyle()
            if k == 0 {
                p.minimumLineHeight = height
                p.maximumLineHeight = height
            } else {
                p.minimumLineHeight = 0.01
                p.maximumLineHeight = 0.01
            }
            p.paragraphSpacing = spaced && k == lines.count - 1 ? theme.bodySize * 0.6 : 0
            p.paragraphSpacingBefore = spaced && k == 0 ? 4 : 0
            s.addAttributes([.font: tiny, .foregroundColor: PlatformColor.clear, .paragraphStyle: p], range: ns.paragraphRange(for: line))
        }
    }

    // MARK: Pictures

    /// A line that is just a picture embed, with the picture and the size to draw it at.
    private func embeddedImage(_ ns: NSString, _ line: NSRange) -> (image: PlatformImage, size: CGSize)? {
        guard line.length > 4, ns.range(of: "![", options: [], range: line).location != NSNotFound else { return nil }
        let str = ns as String
        var ref: String, w: Int?, h: Int?
        func number(_ m: NSTextCheckingResult, _ k: Int) -> Int? { m.range(at: k).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: k))) }
        if let m = Self.embedLine.firstMatch(in: str, range: line) {
            ref = ns.substring(with: m.range(at: 1)); w = number(m, 2); h = number(m, 3)
        } else if let m = Self.imageLine.firstMatch(in: str, range: line) {
            ref = ns.substring(with: m.range(at: 4)); w = number(m, 2); h = number(m, 3)
            if let space = ref.range(of: " \"") { ref = String(ref[..<space.lowerBound]) }   // ![](a.png "title")
        } else { return nil }
        guard let img = image(ref), img.size.width > 0, img.size.height > 0 else { return nil }
        let natural = img.size
        var width = CGFloat(w ?? Int(natural.width))
        var height = h.map(CGFloat.init) ?? width * natural.height / natural.width
        if width > imageWidth { height *= imageWidth / width; width = imageWidth }
        if height > 900 { width *= 900 / height; height = 900 }
        return (img, CGSize(width: max(width, 1), height: max(height, 1)))
    }

    /// The picture is drawn in the room under its line. Away from the caret the Markdown itself folds away,
    /// on the caret's line it stays visible (dimmed) above the picture so it can be edited.
    private func styleImageLine(_ s: NSTextStorage, ns: NSString, line: NSRange, size: CGSize, active: Bool) {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 6
        p.paragraphSpacing = size.height + 12
        if active {
            s.addAttributes([.paragraphStyle: p, .font: theme.font(size: theme.bodySize * 0.82, mono: true), .foregroundColor: theme.faint], range: ns.paragraphRange(for: line))
        } else {
            p.minimumLineHeight = 0.01
            p.maximumLineHeight = 0.01
            s.addAttribute(.paragraphStyle, value: p, range: ns.paragraphRange(for: line))
            hide(s, line, active: false)
        }
    }

    // MARK: Code blocks

    private static let keywords = try! NSRegularExpression(pattern: "\\b(let|var|func|return|if|else|for|while|in|guard|switch|case|default|break|continue|struct|class|enum|protocol|extension|import|true|false|nil|null|None|True|False|def|const|function|async|await|try|catch|throw|throws|new|this|self|Self|public|private|static|final|override|init|where|as|is|do|from|export|interface|type|lambda|yield|with|pass|elif|and|or|not|package|fn|mut|impl|pub|use|go|defer|select|SELECT|FROM|WHERE|INSERT|UPDATE|DELETE)\\b")
    private static let types = try! NSRegularExpression(pattern: "\\b[A-Z][A-Za-z0-9_]+\\b")
    private static let numbers = try! NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")
    private static let strings = try! NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'")
    private static let slashComment = try! NSRegularExpression(pattern: "//.*$|/\\*.*?\\*/", options: [.anchorsMatchLines])
    private static let hashComment = try! NSRegularExpression(pattern: "(?<![\\w\"'])#.*$", options: [.anchorsMatchLines])

    private func styleCode(_ s: NSTextStorage, ns: NSString, lines: [NSRange], closed: Bool, lang: String, active: Bool, indent: CGFloat = 0) {
        let str = ns as String
        let mono = theme.font(size: theme.bodySize, mono: true)
        let body = NSMutableParagraphStyle()
        body.firstLineHeadIndent = 16 + indent
        body.headIndent = 16 + indent
        body.tailIndent = -16 - indent / 2
        body.lineSpacing = 3
        let fenceStyle = NSMutableParagraphStyle()
        fenceStyle.firstLineHeadIndent = 16 + indent
        if !active { fenceStyle.minimumLineHeight = 10; fenceStyle.maximumLineHeight = 10 }

        for (k, line) in lines.enumerated() {
            // Include the newline so the paragraph style covers the whole paragraph.
            let para = ns.paragraphRange(for: line)
            let isFence = k == 0 || (closed && k == lines.count - 1)
            if isFence {
                s.addAttributes([.font: mono, .paragraphStyle: fenceStyle, .foregroundColor: theme.faint], range: para)
                if !active { hide(s, line, active: false) }
                continue
            }
            s.addAttributes([.font: mono, .paragraphStyle: body, .foregroundColor: theme.ink], range: para)
            let l = lang.lowercased()
            if l == "" || l == "text" || l == "txt" || l == "plain" { continue }
            for m in Self.keywords.matches(in: str, range: line) { s.addAttribute(.foregroundColor, value: PlatformColor.hex(0xF28FB8), range: m.range) }
            for m in Self.types.matches(in: str, range: line) { s.addAttribute(.foregroundColor, value: PlatformColor.hex(0x8FB3FF), range: m.range) }
            for m in Self.numbers.matches(in: str, range: line) { s.addAttribute(.foregroundColor, value: PlatformColor.hex(0xFFB38A), range: m.range) }
            for m in Self.strings.matches(in: str, range: line) { s.addAttribute(.foregroundColor, value: PlatformColor.hex(0x7FD1A8), range: m.range) }
            let hashLangs: Set<String> = ["python", "py", "sh", "bash", "zsh", "shell", "ruby", "rb", "yaml", "yml", "toml", "r", "perl"]
            for m in (hashLangs.contains(l) ? Self.hashComment : Self.slashComment).matches(in: str, range: line) {
                s.addAttributes([.foregroundColor: theme.muted, .font: theme.font(size: theme.bodySize, italic: true, mono: true)], range: m.range)
            }
        }
    }

    // MARK: Tables

    private static let tableSeparator = try! NSRegularExpression(pattern: "^[ \\t]*\\|?[ \\t]*:?-{2,}:?[ \\t]*(\\|[ \\t]*:?-{2,}:?[ \\t]*)*\\|?[ \\t]*$")
    static let cellPadding: CGFloat = 12

    private func isTableRow(_ ns: NSString, _ line: NSRange) -> Bool {
        let t = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.count > 1
    }

    /// Cells of a row: (whole cell between pipes, trimmed content).
    private func cells(_ ns: NSString, _ line: NSRange) -> [(cell: NSRange, content: NSRange)] {
        var pipes: [Int] = []
        var k = line.location
        while k < NSMaxRange(line) {
            let c = ns.character(at: k)
            if c == 92 { k += 2; continue }               // backslash escapes the next char
            if c == 124 { pipes.append(k) }               // "|"
            k += 1
        }
        guard pipes.count >= 2 else { return [] }
        var out: [(cell: NSRange, content: NSRange)] = []
        for p in 0..<(pipes.count - 1) {
            let cell = NSRange(location: pipes[p] + 1, length: pipes[p + 1] - pipes[p] - 1)
            var a = cell.location, b = NSMaxRange(cell)
            while a < b, [32, 9].contains(ns.character(at: a)) { a += 1 }
            while b > a, [32, 9].contains(ns.character(at: b - 1)) { b -= 1 }
            out.append((cell: cell, content: NSRange(location: a, length: b - a)))
        }
        return out
    }

    /// Inactive tables are laid out as a grid: pipes and padding spaces vanish, and kerning pads every
    /// cell to its column width. Returns the column widths so the grid lines can be drawn.
    private func styleTable(_ s: NSTextStorage, ns: NSString, rows: [NSRange], active: Bool) -> [CGFloat] {
        let mono = theme.font(size: theme.bodySize * 0.92, mono: true)
        if active {
            for r in rows { s.addAttributes([.font: mono, .foregroundColor: theme.ink], range: r) }
            if rows.count > 1 { s.addAttribute(.foregroundColor, value: theme.faint, range: rows[1]) }
            return []
        }
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.minimumLineHeight = theme.bodySize * 2.1
        rowStyle.maximumLineHeight = theme.bodySize * 2.1
        let sepStyle = NSMutableParagraphStyle()
        sepStyle.minimumLineHeight = 0.5
        sepStyle.maximumLineHeight = 0.5

        // 1. Inline formatting inside cells, bold header.
        var table: [[(cell: NSRange, content: NSRange)]] = []
        for (k, r) in rows.enumerated() {
            let para = ns.paragraphRange(for: r)
            if k == 1 {
                s.addAttribute(.paragraphStyle, value: sepStyle, range: para)
                hide(s, r, active: false)
                continue
            }
            s.addAttributes([.paragraphStyle: rowStyle, .baselineOffset: theme.bodySize * 0.3], range: para)
            let cs = cells(ns, r)
            for c in cs where c.content.length > 0 {
                styleInline(s, ns: ns, range: c.content, active: false)
                if k == 0 { addTrait(s, c.content, bold: true) }
            }
            table.append(cs)
        }

        // 2. Column widths from the formatted text.
        var widths: [CGFloat] = []
        for row in table {
            for (c, cell) in row.enumerated() {
                let w = cell.content.length > 0 ? s.attributedSubstring(from: cell.content).size().width : 0
                if c < widths.count { widths[c] = max(widths[c], w) } else { widths.append(w) }
            }
        }

        // 3. Hide pipes and padding, kern every cell out to its column width.
        let pad = Self.cellPadding
        for (k, r) in rows.enumerated() where k != 1 {
            let row = cells(ns, r)
            hide(s, r, active: false, keepContentOf: row.map(\.content))
            for (c, cell) in row.enumerated() {
                let opening = cell.cell.location - 1                         // the "|" before the cell
                if cell.content.length == 0 {
                    s.addAttribute(.kern, value: widths[c] + 2 * pad, range: NSRange(location: opening, length: 1))
                    continue
                }
                s.addAttribute(.kern, value: pad, range: NSRange(location: opening, length: 1))
                let w = s.attributedSubstring(from: cell.content).size().width
                s.addAttribute(.kern, value: widths[c] - w + pad, range: NSRange(location: NSMaxRange(cell.content) - 1, length: 1))
            }
        }
        return widths.map { $0 + 2 * pad }
    }

    // MARK: Quotes

    private func styleQuoteLine(_ s: NSTextStorage, ns: NSString, line: NSRange, active: Bool, calloutBody: Bool) {
        let str = ns as String
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 18
        p.headIndent = 18
        p.tailIndent = -12
        p.lineSpacing = theme.bodySize * 0.3
        p.paragraphSpacing = 2
        s.addAttribute(.paragraphStyle, value: p, range: ns.paragraphRange(for: line))

        if let m = Self.callout.firstMatch(in: str, range: line) {
            let color = calloutColor(ns.substring(with: m.range(at: 1)))
            let titleRange = m.range(at: 2)
            if titleRange.length > 0 {
                s.addAttributes([.font: theme.font(size: theme.bodySize, bold: true, serif: false), .foregroundColor: color], range: titleRange)
                hide(s, NSRange(location: line.location, length: titleRange.location - line.location), active: active)
            } else {
                // "> [!tip]" without a title shows the type itself, like Obsidian.
                let type = m.range(at: 1)
                s.addAttributes([.font: theme.font(size: theme.bodySize, bold: true, serif: false), .foregroundColor: color], range: type)
                hide(s, NSRange(location: line.location, length: type.location - line.location), active: active)
                hide(s, NSRange(location: NSMaxRange(type), length: NSMaxRange(line) - NSMaxRange(type)), active: active)
            }
            return
        }
        guard let m = Self.quote.firstMatch(in: str, range: line) else { return }
        if !calloutBody { s.addAttributes([.foregroundColor: theme.quote, .font: theme.font(size: theme.bodySize, italic: true)], range: m.range(at: 2)) }
        hide(s, m.range(at: 1), active: active)
        styleInline(s, ns: ns, range: m.range(at: 2), active: active)
    }

    // MARK: Lines

    private func styleLine(_ s: NSTextStorage, ns: NSString, line: NSRange, active: Bool) {
        let str = ns as String
        var content = line          // the part that still gets inline formatting

        if let m = Self.rule.firstMatch(in: str, range: line) {
            s.addAttributes([.foregroundColor: theme.faint, .strikethroughStyle: NSUnderlineStyle.thick.rawValue,
                             .strikethroughColor: theme.faint], range: m.range)
            return
        }

        if let m = Self.heading.firstMatch(in: str, range: line) {
            let level = m.range(at: 1).length
            let size = theme.bodySize * EditorTheme.headingScale[level - 1]
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = size * 0.5
            p.paragraphSpacing = size * 0.25
            s.addAttributes([.font: theme.font(size: size, bold: true, serif: level > 2 ? false : true), .paragraphStyle: p], range: line)
            hide(s, NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length + m.range(at: 2).length), active: active)
            content = m.range(at: 3)
        } else if let m = Self.callout.firstMatch(in: str, range: line) {
            let color = calloutColor(ns.substring(with: m.range(at: 1)))
            s.addAttributes([.backgroundColor: color.withAlphaComponent(0.12), .foregroundColor: theme.ink], range: line)
            s.addAttributes([.font: theme.font(size: theme.bodySize, bold: true, serif: false), .foregroundColor: color], range: m.range(at: 2))
            hide(s, NSRange(location: line.location, length: m.range(at: 2).location - line.location), active: active)
            content = m.range(at: 2)
        } else if let m = Self.quote.firstMatch(in: str, range: line) {
            let depth = ns.substring(with: m.range(at: 1)).filter { $0 == ">" }.count
            let p = NSMutableParagraphStyle()
            p.headIndent = CGFloat(depth) * 18
            p.firstLineHeadIndent = CGFloat(depth) * 18
            p.lineSpacing = theme.bodySize * 0.3
            s.addAttributes([.paragraphStyle: p, .foregroundColor: theme.quote,
                             .font: theme.font(size: theme.bodySize, italic: true)], range: line)
            s.addAttributes([.foregroundColor: theme.accent], range: m.range(at: 1))
            if !active { hide(s, m.range(at: 1), active: false) }
            content = m.range(at: 2)
        } else if let m = Self.task.firstMatch(in: str, range: line) {
            let box = m.range(at: 3)
            let done = ns.substring(with: box).lowercased().contains("x")
            indent(s, prefix: m.range, line: line)
            s.addAttributes([.foregroundColor: theme.faint], range: m.range(at: 2))
            if !active { hide(s, m.range(at: 2), active: false) }
            s.addAttributes([.font: theme.font(size: theme.bodySize, bold: true, mono: true),
                             .foregroundColor: done ? theme.accent : theme.muted,
                             .link: URL(string: "\(Self.taskScheme):\(box.location)")!], range: box)
            let rest = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
            if done, rest.length > 0 {
                s.addAttributes([.foregroundColor: theme.muted, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
            }
            styleTaskDates(s, str: str, range: rest, done: done)
            content = rest
        } else if let m = Self.list.firstMatch(in: str, range: line) {
            indent(s, prefix: m.range, line: line)
            s.addAttributes([.foregroundColor: theme.accent, .font: theme.font(size: theme.bodySize, bold: true, serif: false)], range: m.range(at: 2))
            content = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(line) - NSMaxRange(m.range))
        }

        styleInline(s, ns: ns, range: content, active: active)
    }

    /// Tasks-plugin dates ("📅 2026-10-18") in a smaller face: a due date red when overdue, amber when today.
    private func styleTaskDates(_ s: NSTextStorage, str: String, range: NSRange, done: Bool) {
        let ns = str as NSString
        let today = Tasks.startOfToday()
        for m in Tasks.dateToken.matches(in: str, range: range) {
            var color = theme.muted
            if !done, ns.substring(with: m.range(at: 1)) == "📅", let d = Tasks.day(ns.substring(with: m.range(at: 2))) {
                if d < today { color = PlatformColor.hex(0xFF7A7A) } else if d == today { color = theme.accent }
            }
            s.addAttributes([.font: theme.font(size: theme.bodySize * 0.8, serif: false), .foregroundColor: color], range: m.range)
        }
    }

    private func indent(_ s: NSTextStorage, prefix: NSRange, line: NSRange) {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = theme.bodySize * 0.32
        p.paragraphSpacing = theme.bodySize * 0.15
        p.headIndent = CGFloat(prefix.length) * theme.bodySize * 0.55
        s.addAttribute(.paragraphStyle, value: p, range: line)
    }

    // MARK: Inline

    private func styleInline(_ s: NSTextStorage, ns: NSString, range: NSRange, active: Bool) {
        guard range.length > 0 else { return }
        let str = ns as String
        var protected: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !protected.contains { NSIntersectionRange($0, r).length > 0 } }

        // %%Obsidian comments%% stay in the file but aren't part of the text.
        for m in Self.comment.matches(in: str, range: range) {
            s.addAttributes([.foregroundColor: theme.faint, .font: theme.font(size: theme.bodySize, italic: true)], range: m.range)
            protected.append(m.range)
        }

        for m in Self.code.matches(in: str, range: range) where free(m.range) {
            s.addAttributes([.font: theme.font(size: theme.bodySize, mono: true), .backgroundColor: theme.codeBackground,
                             .foregroundColor: theme.accent], range: m.range(at: 1))
            hide(s, NSRange(location: m.range.location, length: 1), active: active)
            hide(s, NSRange(location: NSMaxRange(m.range) - 1, length: 1), active: active)
            protected.append(m.range)
        }

        for m in Self.wikilink.matches(in: str, range: range) where free(m.range) {
            let target = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let ok = resolves(target)
            // The "#…" part goes along (a book opens at "#page=N").
            let heading = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
            let encoded = (target + heading).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            let visible = m.range(at: 4).location != NSNotFound ? m.range(at: 4) : m.range(at: 2)
            s.addAttributes([.foregroundColor: ok ? theme.link : theme.unresolved,
                             .link: URL(string: "\(Self.noteScheme):\(encoded)")!], range: visible)
            if !ok { s.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: theme.unresolved], range: visible) }
            // Everything except the visible text is syntax: ![[, #heading, target| (when aliased), ]]
            hide(s, NSRange(location: m.range.location, length: visible.location - m.range.location), active: active)
            hide(s, NSRange(location: NSMaxRange(visible), length: NSMaxRange(m.range) - NSMaxRange(visible)), active: active)
            protected.append(m.range)
        }

        for m in Self.mdLink.matches(in: str, range: range) where free(m.range) {
            let address = ns.substring(with: m.range(at: 3))
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: theme.link, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                                        .underlineColor: theme.link.withAlphaComponent(0.4)]
            if let u = URL(string: address), u.scheme != nil { attrs[.link] = u }
            // "![](photo.png)" inside a line, or "[](…)" without text: the address stands for the text.
            let visible = m.range(at: 2).length > 0 ? m.range(at: 2) : m.range(at: 3)
            s.addAttributes(attrs, range: visible)
            hide(s, NSRange(location: m.range.location, length: visible.location - m.range.location), active: active)
            hide(s, NSRange(location: NSMaxRange(visible), length: NSMaxRange(m.range) - NSMaxRange(visible)), active: active)
            protected.append(m.range)
        }

        for m in Self.footnote.matches(in: str, range: range) where free(m.range) {
            s.addAttributes([.foregroundColor: theme.link, .font: theme.font(size: theme.bodySize * 0.75, serif: false),
                             .baselineOffset: theme.bodySize * 0.35], range: m.range)
            protected.append(m.range)
        }

        for m in Self.blockID.matches(in: str, range: range) where free(m.range) {
            if active { s.addAttribute(.foregroundColor, value: theme.faint, range: m.range) } else { hide(s, m.range, active: false) }
            protected.append(m.range)
        }

        for m in Self.url.matches(in: str, range: range) where free(m.range) {
            if let u = URL(string: ns.substring(with: m.range)) {
                s.addAttributes([.link: u, .foregroundColor: theme.link], range: m.range)
            }
            protected.append(m.range)
        }

        for m in Self.tag.matches(in: str, range: range) where free(m.range) {
            s.addAttributes([.foregroundColor: theme.tag, .backgroundColor: theme.tagBackground], range: m.range)
        }

        wrap(s, Self.bold, str, range, free, active, marker: { m in m.range(at: 1).length }) { r in self.addTrait(s, r, bold: true) }
        wrap(s, Self.italicStar, str, range, free, active, marker: { _ in 1 }) { r in self.addTrait(s, r, italic: true) }
        wrap(s, Self.italicUnderscore, str, range, free, active, marker: { _ in 1 }) { r in self.addTrait(s, r, italic: true) }
        wrap(s, Self.strike, str, range, free, active, marker: { _ in 2 }) { r in
            s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: self.theme.muted], range: r)
        }
        wrap(s, Self.mark, str, range, free, active, marker: { _ in 2 }) { r in
            s.addAttributes([.backgroundColor: self.theme.highlight], range: r)
        }
    }

    /// Formats the inside of `**…**`-style pairs and hides (or dims) the markers.
    private func wrap(_ s: NSTextStorage, _ re: NSRegularExpression, _ str: String, _ range: NSRange,
                      _ free: (NSRange) -> Bool, _ active: Bool,
                      marker: (NSTextCheckingResult) -> Int, style: (NSRange) -> Void) {
        for m in re.matches(in: str, range: range) where free(m.range) {
            let k = marker(m)
            let inner = NSRange(location: m.range.location + k, length: m.range.length - 2 * k)
            guard inner.length > 0 else { continue }
            style(inner)
            hide(s, NSRange(location: m.range.location, length: k), active: active)
            hide(s, NSRange(location: NSMaxRange(m.range) - k, length: k), active: active)
        }
    }

    private func addTrait(_ s: NSTextStorage, _ range: NSRange, bold: Bool = false, italic: Bool = false) {
        s.enumerateAttribute(.font, in: range) { value, r, _ in
            guard let f = value as? PlatformFont else { return }
            #if os(macOS)
            let traits = f.fontDescriptor.symbolicTraits
            let isBold = traits.contains(.bold), isItalic = traits.contains(.italic)
            let mono = traits.contains(.monoSpace)
            #else
            let traits = f.fontDescriptor.symbolicTraits
            let isBold = traits.contains(.traitBold), isItalic = traits.contains(.traitItalic)
            let mono = traits.contains(.traitMonoSpace)
            #endif
            let serif = f.fontDescriptor.object(forKey: .family) as? String != PlatformFont.systemFont(ofSize: 12).familyName
            s.addAttribute(.font, value: theme.font(size: f.pointSize, bold: isBold || bold, italic: isItalic || italic,
                                                    mono: mono, serif: serif), range: r)
        }
    }

    /// Hides everything in `r` except the given ranges.
    private func hide(_ s: NSTextStorage, _ r: NSRange, active: Bool, keepContentOf keep: [NSRange]) {
        var cursor = r.location
        for k in keep.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if k.location > cursor { hide(s, NSRange(location: cursor, length: k.location - cursor), active: active) }
            cursor = max(cursor, NSMaxRange(k))
        }
        if NSMaxRange(r) > cursor { hide(s, NSRange(location: cursor, length: NSMaxRange(r) - cursor), active: active) }
    }

    /// Syntax characters: dimmed on the line being edited, collapsed to nothing elsewhere.
    private func hide(_ s: NSTextStorage, _ r: NSRange, active: Bool) {
        guard r.length > 0, r.location != NSNotFound else { return }
        if active {
            s.addAttributes([.foregroundColor: theme.faint], range: r)
        } else {
            s.addAttributes([.foregroundColor: PlatformColor.clear, .font: theme.font(size: 0.1, serif: false),
                             .backgroundColor: PlatformColor.clear], range: r)
        }
    }

    private func calloutColor(_ type: String) -> PlatformColor {
        switch type.lowercased() {
        case "warning", "caution", "attention": return .hex(0xF2B544)
        case "danger", "error", "bug", "failure": return .hex(0xE8826B)
        case "tip", "hint", "important", "success", "check", "done": return .hex(0x7FD1A8)
        case "question", "help", "faq": return .hex(0xC9A0FF)
        case "quote", "cite": return .hex(0x9A9FAD)
        default: return .hex(0x8FB3FF)
        }
    }

    /// `---` … `---` at the very top of the file (Obsidian properties).
    private func frontmatterRange(_ ns: NSString) -> NSRange? {
        guard ns.hasPrefix("---\n") || ns.hasPrefix("---\r\n") else { return nil }
        let rest = NSRange(location: 4, length: ns.length - 4)
        let close = ns.range(of: "\n---", options: [], range: rest)
        guard close.location != NSNotFound else { return nil }
        var end = NSMaxRange(close)
        let lineEnd = ns.range(of: "\n", options: [], range: NSRange(location: end, length: ns.length - end))
        end = lineEnd.location == NSNotFound ? ns.length : lineEnd.location
        return NSRange(location: 0, length: end)
    }
}

// MARK: - Editing helpers shared by both platforms

enum MarkdownEditing {
    /// What to insert when Enter is pressed on `line`: continues lists, tasks and quotes,
    /// or ends the list when the current item is empty. `nil` means a plain newline.
    static func continuation(for line: String) -> (insert: String, clearLine: Bool)? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+])[ \\t]+\\[[ xX]\\][ \\t]+(.*)$").firstMatch(in: line, range: full) {
            let empty = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces).isEmpty
            return empty ? ("", true) : ("\n" + ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) + " [ ] ", false)
        }
        if let m = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+])[ \\t]+(.*)$").firstMatch(in: line, range: full) {
            let empty = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces).isEmpty
            return empty ? ("", true) : ("\n" + ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) + " ", false)
        }
        if let m = try! NSRegularExpression(pattern: "^([ \\t]*)(\\d+)([.)])[ \\t]+(.*)$").firstMatch(in: line, range: full) {
            let empty = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces).isEmpty
            let n = (Int(ns.substring(with: m.range(at: 2))) ?? 0) + 1
            return empty ? ("", true) : ("\n" + ns.substring(with: m.range(at: 1)) + "\(n)" + ns.substring(with: m.range(at: 3)) + " ", false)
        }
        if let m = try! NSRegularExpression(pattern: "^((?:>[ \\t]?)+)(.*)$").firstMatch(in: line, range: full) {
            let empty = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces).isEmpty
            return empty ? ("", true) : ("\n" + ns.substring(with: m.range(at: 1)), false)
        }
        return nil
    }

    /// If the caret sits right after an unclosed `[[`, returns the typed part and its range.
    static func linkQuery(in text: NSString, caret: Int) -> (query: String, range: NSRange)? {
        guard caret <= text.length else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: min(caret, max(text.length - 1, 0)), length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let typed = before.substring(from: NSMaxRange(open))
        if typed.contains("]]") || typed.contains("|") || typed.count > 60 { return nil }
        return (typed, NSRange(location: lineStart + NSMaxRange(open), length: typed.utf16.count))
    }

    /// Best matches first: names starting with the query, then containing it, then holding its letters
    /// in order ("мпв" finds "Моя первая вселенная"), the way Obsidian's switcher forgives typos.
    static func suggestions(for query: String, in titles: [String]) -> [String] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        func rank(_ title: String) -> Int? {
            let t = title.lowercased()
            if q.isEmpty || t.hasPrefix(q) { return 0 }
            if t.contains(q) { return 1 }
            var rest = t[...]
            for ch in q where ch != " " {
                guard let i = rest.firstIndex(of: ch) else { return nil }
                rest = rest[rest.index(after: i)...]
            }
            return 2
        }
        var seen = Set<String>()
        let hits = titles.compactMap { t in rank(t).map { (t, $0) } }.filter { seen.insert($0.0.lowercased()).inserted }
        return Array(hits.sorted { a, b in
            a.1 != b.1 ? a.1 < b.1 : a.0.localizedStandardCompare(b.0) == .orderedAscending
        }.prefix(8).map(\.0))
    }

    /// The headings of a note, for `[[Note#`. Lines inside code blocks don't count.
    static func headings(in text: String) -> [String] {
        var out: [String] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inCode.toggle(); continue }
            guard !inCode, t.hasPrefix("#") else { continue }
            let hashes = t.prefix { $0 == "#" }.count
            guard hashes <= 6, t.dropFirst(hashes).first == " " else { continue }
            let title = t.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            if !title.isEmpty { out.append(title) }
        }
        return out
    }

    static func isWebAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), !t.contains("\n"), let u = URL(string: t), let scheme = u.scheme?.lowercased() else { return false }
        return scheme == "mailto" || (["http", "https"].contains(scheme) && u.host != nil)
    }

    /// `[selection](address)` with the address taken from the clipboard when it holds one. The caret lands
    /// where typing is still needed: in the brackets, in the parentheses, or after the link.
    static func webLink(selected: String, clipboard: String?) -> (text: String, caret: Int) {
        if isWebAddress(selected) { return ("[](\(selected))", 1) }
        let address = clipboard.flatMap { isWebAddress($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? ""
        let text = "[\(selected)](\(address))"
        let length = (text as NSString).length
        if selected.isEmpty { return (text, 1) }
        return (text, address.isEmpty ? length - 1 : length)
    }

    /// Picture embeds to insert at `range`, each on a line of its own (a picture shows only when alone on its line),
    /// and where the caret goes: the start of the next line, so the pictures show right away.
    static func embedSnippet(_ names: [String], in text: NSString, at range: NSRange) -> (text: String, caret: Int) {
        var snippet = names.map(EditorImages.embed).joined(separator: "\n")
        let before = range.location > 0 ? text.character(at: range.location - 1) : 10
        let afterIndex = NSMaxRange(range)
        let lineFollows = afterIndex < text.length && text.character(at: afterIndex) == 10
        if before != 10 { snippet = "\n" + snippet }
        if !lineFollows { snippet += "\n" }
        return (snippet, (snippet as NSString).length + (lineFollows ? 1 : 0))
    }
}


// MARK: - Blocks drawn behind the text

/// A multi-line element drawn as a box (code, table, quote, callout).
struct EditorBlock {
    enum Kind: Equatable {
        case code(language: String)
        case table(columnWidths: [CGFloat])
        case rawTable
        case quote
        case callout(color: PlatformColor)
        /// Side-by-side columns: nothing is painted, editors on top show them.
        case columns
        /// The frontmatter, shown as a properties panel on top.
        case properties
        /// A ```gallery block: a grid of cards on top.
        case gallery
        /// A picture embed alone on its line, drawn under it at `size`.
        case image(PlatformImage, size: CGSize)
        /// A ```dataview block: the query's results on top.
        case dataview
    }
    var kind: Kind
    var range: NSRange
    /// Table rows (without the separator line), for the grid.
    var rows: [NSRange] = []
    /// Left offset of the box, e.g. a code block inside a callout.
    var indent: CGFloat = 0
}

extension EditorBlock.Kind {
    var isImage: Bool { if case .image = self { true } else { false } }
}

/// TextKit 1 layout manager that paints code boxes, table grids and quote bars under the glyphs.
final class BlockLayoutManager: NSLayoutManager {
    var blocks: [EditorBlock] = []
    var theme = EditorTheme()

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first, let ctx = Self.context else { return }
        let pad = container.lineFragmentPadding
        let fullWidth = container.size.width - 2 * pad

        for block in blocks {
            let glyphs = glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            guard glyphs.length > 0, NSIntersectionRange(glyphs, glyphsToShow).length > 0 || glyphsToShow.location > glyphs.location else { continue }
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x = pad + origin.x
            rect.origin.y += origin.y
            rect.size.width = fullWidth

            ctx.saveGState()
            switch block.kind {
            case .code(let language):
                var box = rect.insetBy(dx: 0, dy: -2)
                box.origin.x += block.indent
                box.size.width -= block.indent * 1.5
                fill(ctx, box, radius: 10, color: theme.codeBackground)
                stroke(ctx, box, radius: 10, color: PlatformColor.hex(0xFFFFFF, 0.06))
                if !language.isEmpty {
                    let label = NSAttributedString(string: language.lowercased(), attributes: [
                        .font: theme.font(size: 10.5, mono: true), .foregroundColor: theme.faint])
                    let size = label.size()
                    label.draw(at: CGPoint(x: box.maxX - size.width - 12, y: box.minY + 6))
                }
            case .rawTable:
                fill(ctx, rect.insetBy(dx: 0, dy: -2), radius: 8, color: theme.codeBackground)
            case .table(let widths):
                drawTable(ctx, rows: block.rows, widths: widths, container: container, origin: origin, left: rect.minX)
            case .quote:
                fill(ctx, CGRect(x: rect.minX + 2, y: rect.minY, width: 3, height: rect.height), radius: 1.5, color: theme.accent.withAlphaComponent(0.6))
            case .callout(let color):
                fill(ctx, rect.insetBy(dx: 0, dy: -4), radius: 10, color: color.withAlphaComponent(0.1))
                fill(ctx, CGRect(x: rect.minX, y: rect.minY - 4, width: 3, height: rect.height + 8), radius: 1.5, color: color)
            case .image(let image, let size):
                drawImage(ctx, image, size: size, line: glyphs.location, origin: origin, left: rect.minX)
            case .columns, .properties, .gallery, .dataview:
                break
            }
            ctx.restoreGState()
        }
    }

    private func drawTable(_ ctx: CGContext, rows: [NSRange], widths: [CGFloat], container: NSTextContainer, origin: CGPoint, left: CGFloat) {
        guard !rows.isEmpty, !widths.isEmpty else { return }
        let rects = rows.map { r -> CGRect in
            var b = boundingRect(forGlyphRange: glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: container)
            b.origin.y += origin.y
            return b
        }
        let top = rects.first!.minY, bottom = rects.last!.maxY
        let width = widths.reduce(0, +)
        let frame = CGRect(x: left, y: top, width: width, height: bottom - top)
        let line = PlatformColor.hex(0xFFFFFF, 0.12)

        fill(ctx, CGRect(x: frame.minX, y: rects[0].minY, width: width, height: rects[0].height), radius: 0, color: PlatformColor.hex(0xFFFFFF, 0.05))
        ctx.setStrokeColor(line.cgColor)
        ctx.setLineWidth(1)
        for r in rects.dropFirst() {                       // row separators
            ctx.move(to: CGPoint(x: frame.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: frame.maxX, y: r.minY))
        }
        var x = frame.minX
        for w in widths.dropLast() {                       // column separators
            x += w
            ctx.move(to: CGPoint(x: x, y: frame.minY)); ctx.addLine(to: CGPoint(x: x, y: frame.maxY))
        }
        ctx.strokePath()
        stroke(ctx, frame, radius: 8, color: line)
    }

    /// Pictures sit in the paragraph spacing under their line.
    private func drawImage(_ ctx: CGContext, _ image: PlatformImage, size: CGSize, line glyph: Int, origin: CGPoint, left: CGFloat) {
        let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let frame = CGRect(x: left, y: used.maxY + origin.y + 6, width: size.width, height: size.height)
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.clip()
        #if os(macOS)
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        #else
        image.draw(in: frame)
        #endif
    }

    private func fill(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, color: PlatformColor) {
        guard r.width > 0, r.height > 0 else { return }
        let rad = min(radius, r.width / 2, r.height / 2)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    private func stroke(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, color: PlatformColor) {
        let box = r.insetBy(dx: 0.5, dy: 0.5)
        guard box.width > 0, box.height > 0 else { return }
        let rad = min(radius, box.width / 2, box.height / 2)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    private static var context: CGContext? {
        #if os(macOS)
        return NSGraphicsContext.current?.cgContext
        #else
        return UIGraphicsGetCurrentContext()
        #endif
    }
}

#if os(macOS)
/// Text hidden under the columns and properties panels must not show the spell checker's red dots.
extension BlockLayoutManager: NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any] = [:],
                       forDrawingToScreen toScreen: Bool, atCharacterIndex charIndex: Int,
                       effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? {
        for block in blocks where block.kind == .columns || block.kind == .properties || block.kind == .gallery || block.kind == .dataview || block.kind.isImage {
            if charIndex >= block.range.location && charIndex <= NSMaxRange(block.range) { return [:] }
        }
        return attrs
    }
}
#endif

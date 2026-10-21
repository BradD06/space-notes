import Foundation

/// The Obsidian Dataview plugin's query language (DQL), enough for everyday vaults:
///
///     ```dataview
///     TABLE WITHOUT ID file.link AS "Слово", translation AS "Перевод"
///     FROM "Learning English/Словарь/Слова" AND -#archive
///     WHERE up = this.file.link
///     SORT added DESC, file.name ASC
///     LIMIT 20
///     ```
///
/// LIST, TABLE and TASK queries with FROM (folders, #tags, [[links]], [[]], outgoing(), and/or/-), WHERE,
/// SORT and LIMIT; fields from the frontmatter, inline `key:: value` fields, `file.*` and Tasks emoji dates.
/// GROUP BY, FLATTEN, CALENDAR and ```dataviewjs are not handled: the block says so instead of guessing.
nonisolated enum Dataview {
    static let language = "dataview"
}

// MARK: - Values

nonisolated struct DVLink: Hashable, Sendable {
    /// What the link points to as written: a title or a path, without ".md".
    var target: String
    var display: String?

    /// The bare note title, lowercased: two links are equal when these are.
    var key: String {
        var t = target
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        if let slash = t.lastIndex(of: "/") { t = String(t[t.index(after: slash)...]) }
        if t.lowercased().hasSuffix(".md") { t.removeLast(3) }
        return t.lowercased()
    }
    var title: String { display ?? (target.split(separator: "/").last.map(String.init) ?? target) }
}

nonisolated struct DVDuration: Hashable, Sendable {
    var months = 0
    var seconds: Double = 0
}

nonisolated indirect enum DVValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case date(Date)
    case duration(DVDuration)
    case link(DVLink)
    case list([DVValue])
    case object([String: DVValue])
    case lambda([String], DVExpr)

    var isNull: Bool { if case .null = self { true } else { false } }

    var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .number(let n): n != 0
        case .string(let s): !s.isEmpty
        case .list(let l): !l.isEmpty
        case .object(let o): !o.isEmpty
        default: true
        }
    }

    var list: [DVValue] {
        switch self {
        case .list(let l): l
        case .null: []
        default: [self]
        }
    }

    /// Field access, case-insensitive like Dataview ("Week_Start" finds "week_start").
    subscript(field: String) -> DVValue {
        switch self {
        case .object(let o):
            return o[field] ?? o[field.lowercased()] ?? o[Dataview.sanitize(field)] ?? .null
        case .link(let l):
            switch field {
            case "path": return .string(l.target)
            case "display": return l.display.map(DVValue.string) ?? .null
            case "file": return .null
            default: return .null
            }
        case .date(let d):
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: d)
            switch field {
            case "year": return .number(Double(c.year ?? 0))
            case "month": return .number(Double(c.month ?? 0))
            case "day": return .number(Double(c.day ?? 0))
            case "hour": return .number(Double(c.hour ?? 0))
            case "minute": return .number(Double(c.minute ?? 0))
            case "second": return .number(Double(c.second ?? 0))
            case "weekday": return .number(Double(((c.weekday ?? 1) + 5) % 7 + 1))
            default: return .null
            }
        case .list(let l):
            // `file.tasks.text` maps over the list, like Dataview's swizzling.
            return .list(l.map { $0[field] })
        default:
            return .null
        }
    }

    /// As shown in a cell, without links and markup.
    var plain: String {
        switch self {
        case .null: ""
        case .bool(let b): b ? "✓" : "✗"
        case .number(let n): Dataview.format(n)
        case .string(let s): s
        case .date(let d): Dataview.format(d)
        case .duration(let d): Dataview.format(d)
        case .link(let l): l.title
        case .list(let l): l.map(\.plain).joined(separator: ", ")
        case .object(let o): o.keys.sorted().map { "\($0): \(o[$0]!.plain)" }.joined(separator: ", ")
        case .lambda: "<функция>"
        }
    }
}

extension Dataview {
    /// "Week Start" → "week-start": the name Dataview also gives a field so it can be typed in queries.
    static func sanitize(_ key: String) -> String {
        key.lowercased()
            .replacingOccurrences(of: "[*_~`]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
    }

    static func format(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(format: "%.2f", n).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    }

    static func format(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
        let style = Date.FormatStyle(locale: RuDate.locale).day().month(.wide).year()
        if (c.hour ?? 0) == 0 && (c.minute ?? 0) == 0 && (c.second ?? 0) == 0 { return d.formatted(style) }
        return d.formatted(style.hour().minute())
    }

    static func format(_ d: DVDuration) -> String {
        var parts: [String] = []
        if d.months != 0 { parts.append("\(d.months) мес.") }
        let days = Int(d.seconds / 86400), rest = Int(d.seconds) % 86400
        if days != 0 { parts.append("\(days) дн.") }
        if rest / 3600 != 0 { parts.append("\(rest / 3600) ч") }
        if rest % 3600 / 60 != 0 { parts.append("\(rest % 3600 / 60) мин") }
        return parts.isEmpty ? "0" : parts.joined(separator: " ")
    }

    /// A frontmatter or inline-field text read the way Dataview types it: links, dates, numbers, booleans.
    static func typed(_ raw: String) -> DVValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return .null }
        if s.hasPrefix("[[") && s.hasSuffix("]]"), !s.dropFirst(2).dropLast(2).contains("]]") { return .link(link(String(s.dropFirst(2).dropLast(2)))) }
        if s == "true" || s == "false" { return .bool(s == "true") }
        if s.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil, let n = Double(s) { return .number(n) }
        if let d = date(s) { return .date(d) }
        return .string(s)
    }

    /// "Note|alias" → link.
    static func link(_ inner: String) -> DVLink {
        if let bar = inner.firstIndex(of: "|") {
            return DVLink(target: String(inner[..<bar]).trimmingCharacters(in: .whitespaces),
                          display: String(inner[inner.index(after: bar)...]).trimmingCharacters(in: .whitespaces))
        }
        return DVLink(target: inner.trimmingCharacters(in: .whitespaces), display: nil)
    }

    /// "2026-10-05", "2026-10-05T14:30", "2026-10", "2026-W41" isn't a date for Dataview either.
    static func date(_ s: String) -> Date? {
        guard s.range(of: #"^\d{4}-\d{2}(-\d{2}([T ]\d{2}:\d{2}(:\d{2})?)?)?$"#, options: .regularExpression) != nil else { return nil }
        let nums = s.split(whereSeparator: { "-T :".contains($0) }).compactMap { Int($0) }
        var c = DateComponents(year: nums[0], month: nums[1], day: nums.count > 2 ? nums[2] : 1)
        if nums.count > 3 { c.hour = nums[3]; c.minute = nums[4] }
        if nums.count > 5 { c.second = nums[5] }
        guard (1...12).contains(nums[1]) else { return nil }
        return Calendar.current.date(from: c)
    }
}

// MARK: - Pages

/// One note as Dataview sees it: its fields (frontmatter, inline fields, `file`) and tasks.
nonisolated struct DVPage: Sendable {
    let id: String
    var title: String
    var fields: [String: DVValue]
    var tasks: [TaskItem]
    /// Link keys (lowercased titles) this note points to.
    var outlinks: Set<String>
    var tags: [String]

    var link: DVLink { DVLink(target: title, display: nil) }
    var folder: String { (id as NSString).deletingLastPathComponent }

    private static let inlineLine = try! NSRegularExpression(pattern: "^[ \\t]*(?:[-*+][ \\t]+(?:\\[.\\][ \\t]+)?|>[ \\t]*)?([^\\s:\\[\\]()`#][^:\\[\\]()`]*?)::[ \\t]*(.*)$")
    private static let inlineBracket = try! NSRegularExpression(pattern: "[\\[(]([^\\[\\]():`]+?)::[ \\t]*([^\\])]*)[\\])]")
    private static let tagRegex = try! NSRegularExpression(pattern: "(?:^|\\s)#([\\p{L}\\p{N}_/-]*[\\p{L}_/-][\\p{L}\\p{N}_/-]*)")

    static func build(id: String, text: String, created: Date, modified: Date) -> DVPage {
        let title = ((id as NSString).lastPathComponent as NSString).deletingPathExtension
        var fields: [String: DVValue] = [:]
        func set(_ key: String, _ value: DVValue) {
            let k = key.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { return }
            // A key written twice (inline fields) becomes a list, as in Dataview.
            if let old = fields[k] { fields[k] = .list(old.list + [value]) } else { fields[k] = value }
            let s = Dataview.sanitize(k)
            if s != k, fields[s] == nil || fields[s]!.isNull { fields[s] = fields[k] }
        }

        // Frontmatter
        var frontmatter: [String: DVValue] = [:]
        if let fm = Properties.frontmatter(in: text as NSString) {
            for (key, value) in yaml(fm.yaml) {
                frontmatter[key] = value
                set(key, value)
            }
        }

        // Inline fields, outside code blocks
        let body = MarkdownParser.stripFrontmatter(text)
        var inCode = false
        for raw in body.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inCode.toggle(); continue }
            if inCode || !raw.contains("::") { continue }
            let ns = raw as NSString
            let all = NSRange(location: 0, length: ns.length)
            var found = false
            for m in inlineBracket.matches(in: raw, range: all) {
                set(ns.substring(with: m.range(at: 1)), Dataview.typed(ns.substring(with: m.range(at: 2))))
                found = true
            }
            if !found, let m = inlineLine.firstMatch(in: raw, range: all) {
                let key = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "[*_]", with: "", options: .regularExpression)
                set(key, Dataview.typed(ns.substring(with: m.range(at: 2))))
            }
        }

        let tasks = Tasks.parse(text, path: id)
        let tags = MarkdownParser.tags(in: text)
        let links = MarkdownParser.links(in: text)
        let page = DVPage(id: id, title: title, fields: fields, tasks: tasks,
                          outlinks: Set(links.map { $0.lowercased() }), tags: tags)
        var file: [String: DVValue] = [
            "name": .string(title),
            "path": .string(id),
            "folder": .string(page.folder),
            "ext": .string((id as NSString).pathExtension),
            "link": .link(page.link),
            "size": .number(Double(text.utf8.count)),
            "ctime": .date(created),
            "mtime": .date(modified),
            "cday": .date(Calendar.current.startOfDay(for: created)),
            "mday": .date(Calendar.current.startOfDay(for: modified)),
            "frontmatter": .object(frontmatter),
            "outlinks": .list(links.map { .link(DVLink(target: $0, display: nil)) }),
            "etags": .list(tags.map { .string("#" + $0) }),
            "tags": .list(Self.expand(tags).map { .string("#" + $0) }),
            "tasks": .list(tasks.map { $0.value(in: page) }),
            "lists": .list(tasks.map { $0.value(in: page) })
        ]
        if let d = Dataview.date(String(title.prefix(10))) { file["day"] = .date(d) }
        if case .list(let a)? = frontmatter["aliases"] { file["aliases"] = .list(a) }
        var result = page
        result.fields["file"] = .object(file)
        return result
    }

    /// "a/b/c" also counts as "a" and "a/b", like Dataview's file.tags.
    static func expand(_ tags: [String]) -> [String] {
        var out: [String] = []
        for t in tags {
            let parts = t.split(separator: "/")
            for k in 1...max(1, parts.count) {
                let s = parts.prefix(k).joined(separator: "/")
                if !out.contains(s) { out.append(s) }
            }
        }
        return out
    }

    /// Flat YAML: the properties panel's reader, or a plain "key: value" pass when the YAML is fancier.
    static func yaml(_ text: String) -> [(String, DVValue)] {
        if let props = Properties.parse(text) {
            return props.map { p in
                switch p.value {
                case .text(let s): (p.key, Dataview.typed(s))
                case .bool(let b): (p.key, .bool(b))
                case .list(let l): (p.key, .list(l.map(Dataview.typed)))
                }
            }
        }
        var out: [(String, DVValue)] = []
        for raw in text.components(separatedBy: "\n") {
            guard raw.first.map({ !$0.isWhitespace && $0 != "#" }) ?? false, let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { value = String(value.dropFirst().dropLast()) }
            if !key.isEmpty { out.append((key, Dataview.typed(value))) }
        }
        return out
    }
}

extension TaskItem {
    /// The task as a Dataview object (`t.completed`, `t.due`, `t.text` …).
    func value(in page: DVPage) -> DVValue {
        var o: [String: DVValue] = [
            "text": .string(text),
            "visual": .string(description),
            "status": .string(status),
            "completed": .bool(completed),
            "checked": .bool(checked),
            "fullyCompleted": .bool(completed),
            "line": .number(Double(line)),
            "path": .string(path),
            "link": .link(page.link),
            "tags": .list(MarkdownParser.tags(in: text).map { .string("#" + $0) }),
            "outlinks": .list(MarkdownParser.links(in: text).map { .link(DVLink(target: $0, display: nil)) }),
            "priority": .number(Double(priority))
        ]
        if let due { o["due"] = .date(due) }
        if let scheduled { o["scheduled"] = .date(scheduled) }
        if let start { o["start"] = .date(start) }
        if let created { o["created"] = .date(created) }
        if let done { o["completion"] = .date(done); o["done"] = .date(done) }
        if let cancelled { o["cancelled"] = .date(cancelled) }
        if let recurrence { o["recurrence"] = .string(recurrence) }
        // [due:: 2026-10-18] written as inline fields count too.
        let ns = text as NSString
        for m in DVPage.inlineFieldsInTask.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = Dataview.sanitize(ns.substring(with: m.range(at: 1)))
            if o[key] == nil { o[key] = Dataview.typed(ns.substring(with: m.range(at: 2))) }
        }
        return .object(o)
    }
}

extension DVPage {
    static let inlineFieldsInTask = try! NSRegularExpression(pattern: "[\\[(]([^\\[\\]():`]+?)::[ \\t]*([^\\])]*)[\\])]")
}

/// All pages of the vault, ready to be queried.
nonisolated struct DVIndex: Sendable {
    var pages: [String: DVPage]
    /// Lowercased title → note id (first by path, as Cosmos resolves links).
    var byTitle: [String: String]
    /// Lowercased title → ids of the notes linking to it.
    var inlinks: [String: [String]]

    init(pages list: [DVPage]) {
        var pages: [String: DVPage] = [:]
        var byTitle: [String: String] = [:]
        var inlinks: [String: [String]] = [:]
        for p in list.sorted(by: { $0.id < $1.id }) {
            if byTitle[p.title.lowercased()] == nil { byTitle[p.title.lowercased()] = p.id }
            for key in p.outlinks { inlinks[key, default: []].append(p.id) }
        }
        for var p in list {
            if case .object(var file)? = p.fields["file"] {
                file["inlinks"] = .list((inlinks[p.title.lowercased()] ?? []).map { id in
                    .link(DVLink(target: ((id as NSString).lastPathComponent as NSString).deletingPathExtension, display: nil))
                })
                p.fields["file"] = .object(file)
            }
            pages[p.id] = p
        }
        self.pages = pages
        self.byTitle = byTitle
        self.inlinks = inlinks
    }

    func page(for link: DVLink) -> DVPage? {
        if let p = pages[link.target] ?? pages[link.target + ".md"] { return p }
        return byTitle[link.key].flatMap { pages[$0] }
    }
}

// MARK: - Queries

nonisolated indirect enum DVExpr: Sendable {
    case literal(DVValue)
    case field(String)
    case member(DVExpr, String)
    case index(DVExpr, DVExpr)
    case call(String, [DVExpr])
    case unary(String, DVExpr)
    case binary(String, DVExpr, DVExpr)
    case list([DVExpr])
    case lambda([String], DVExpr)
}

nonisolated indirect enum DVSource: Sendable {
    case all
    case folder(String)
    case tag(String)
    case incoming(DVLink?)          // [[note]] — nil is [[]], this note
    case outgoing(DVLink?)
    case and(DVSource, DVSource)
    case or(DVSource, DVSource)
    case not(DVSource)
}

nonisolated struct DVQuery: Sendable {
    enum Kind: Sendable { case list, table, task }
    var kind: Kind
    var withoutID = false
    /// LIST's one expression, or TABLE's columns.
    var columns: [(expr: DVExpr, name: String)] = []
    var source: DVSource = .all
    var wheres: [DVExpr] = []
    var sorts: [(expr: DVExpr, ascending: Bool)] = []
    var limit: Int?
}

nonisolated struct DVError: Error, Sendable {
    let message: String
    init(_ m: String) { message = m }
}

nonisolated enum DVResult: Sendable {
    struct ListItem: Sendable {
        var link: DVLink?
        var value: DVValue?
    }
    struct TaskGroup: Sendable {
        var link: DVLink
        var tasks: [TaskItem]
    }
    case list([ListItem])
    case table(headers: [String], rows: [[DVValue]], links: [DVLink?])
    case tasks([TaskGroup])
    case failure(String)

    var count: Int {
        switch self {
        case .list(let l): l.count
        case .table(_, let rows, _): rows.count
        case .tasks(let g): g.reduce(0) { $0 + $1.tasks.count }
        case .failure: 0
        }
    }
}

extension Dataview {
    /// Runs the block's text (with or without its ``` fences) against the vault.
    static func run(_ block: String, index: DVIndex, current: String?) -> DVResult {
        let lines = block.components(separatedBy: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("```") && !t.hasPrefix("~~~")
        }
        let source = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return .failure("Пустой запрос") }
        do {
            var parser = try DVParser(source)
            let query = try parser.query()
            return try DVRunner(index: index, current: current).run(query)
        } catch let e as DVError {
            return .failure(e.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

// MARK: - Tokens and parsing

nonisolated private enum DVToken: Equatable {
    case number(Double)
    case string(String)
    case ident(String)
    case link(String)
    case tag(String)
    case op(String)
}

nonisolated private struct DVParser {
    private var tokens: [DVToken] = []
    private var pos = 0

    init(_ text: String) throws {
        tokens = try Self.tokenize(text)
    }

    private static let clauseWords: Set<String> = ["from", "where", "sort", "limit", "group", "flatten"]
    private static let dateWords: Set<String> = ["today", "now", "tomorrow", "yesterday", "sow", "eow", "som", "eom", "soy", "eoy"]

    private static func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" || (c.unicodeScalars.first?.properties.isEmojiPresentation ?? false) }
    private static func isIdent(_ c: Character) -> Bool { isIdentStart(c) || c.isNumber }

    static func tokenize(_ text: String) throws -> [DVToken] {
        var out: [DVToken] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {          // // comment to the end of the line
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "\"" || c == "'" {
                var s = "", j = i + 1
                while j < chars.count && chars[j] != c {
                    if chars[j] == "\\" && j + 1 < chars.count { j += 1; s.append(chars[j] == "n" ? "\n" : chars[j]) } else { s.append(chars[j]) }
                    j += 1
                }
                guard j < chars.count else { throw DVError("Незакрытая строка в запросе") }
                out.append(.string(s)); i = j + 1; continue
            }
            if c == "[" && i + 1 < chars.count && chars[i + 1] == "[" {
                var j = i + 2, s = ""
                while j + 1 < chars.count && !(chars[j] == "]" && chars[j + 1] == "]") { s.append(chars[j]); j += 1 }
                guard j + 1 < chars.count else { throw DVError("Незакрытая ссылка [[ в запросе") }
                out.append(.link(s)); i = j + 2; continue
            }
            if c == "#" && i + 1 < chars.count && (isIdent(chars[i + 1]) || chars[i + 1] == "/") {
                var j = i + 1, s = ""
                while j < chars.count && (isIdent(chars[j]) || chars[j] == "/" || chars[j] == "-") { s.append(chars[j]); j += 1 }
                out.append(.tag(s)); i = j; continue
            }
            if c.isNumber {
                var j = i, s = ""
                while j < chars.count && (chars[j].isNumber || (chars[j] == "." && j + 1 < chars.count && chars[j + 1].isNumber)) { s.append(chars[j]); j += 1 }
                out.append(.number(Double(s) ?? 0)); i = j; continue
            }
            if isIdentStart(c) {
                var j = i, s = ""
                while j < chars.count {
                    if isIdent(chars[j]) { s.append(chars[j]); j += 1; continue }
                    // "due-date" is one field; "a - b" is a subtraction.
                    if chars[j] == "-" && j + 1 < chars.count && isIdentStart(chars[j + 1]) && !s.isEmpty { s.append("-"); j += 1; continue }
                    break
                }
                out.append(.ident(s)); i = j; continue
            }
            let two = i + 1 < chars.count ? String([c, chars[i + 1]]) : ""
            if ["=>", "!=", "<=", ">=", "&&", "||", "=="].contains(two) { out.append(.op(two == "==" ? "=" : two)); i += 2; continue }
            if "()[],.=<>+-*/%!{}:".contains(c) { out.append(.op(String(c))); i += 1; continue }
            throw DVError("Непонятный символ «\(c)» в запросе")
        }
        return out
    }

    // MARK: Helpers

    private var peek: DVToken? { pos < tokens.count ? tokens[pos] : nil }
    private func peek(_ k: Int) -> DVToken? { pos + k < tokens.count ? tokens[pos + k] : nil }

    private func isWord(_ t: DVToken?, _ w: String) -> Bool {
        if case .ident(let s)? = t { return s.lowercased() == w }
        return false
    }
    private mutating func word(_ w: String) -> Bool {
        if isWord(peek, w) { pos += 1; return true }
        return false
    }
    private mutating func op(_ o: String) -> Bool {
        if peek == .op(o) { pos += 1; return true }
        return false
    }
    private mutating func expect(_ o: String) throws {
        guard op(o) else { throw DVError("Ожидалось «\(o)» в запросе") }
    }
    private var atClause: Bool {
        guard case .ident(let s)? = peek else { return peek == nil }
        return Self.clauseWords.contains(s.lowercased())
    }

    // MARK: Query

    mutating func query() throws -> DVQuery {
        var q: DVQuery
        if word("list") {
            q = DVQuery(kind: .list)
            if word("without") { guard word("id") else { throw DVError("После WITHOUT ожидалось ID") }; q.withoutID = true }
            if !atClause { q.columns = [(try expression(), "")] }
        } else if word("table") {
            q = DVQuery(kind: .table)
            if word("without") { guard word("id") else { throw DVError("После WITHOUT ожидалось ID") }; q.withoutID = true }
            while !atClause {
                let start = pos
                let e = try expression()
                var name = Self.describe(tokens[start..<pos])
                if word("as") {
                    switch peek {
                    case .string(let s)?: name = s; pos += 1
                    case .ident(let s)?: name = s; pos += 1
                    default: throw DVError("После AS ожидалось название столбца")
                    }
                }
                q.columns.append((e, name))
                if !op(",") { break }
            }
        } else if word("task") {
            q = DVQuery(kind: .task)
        } else if case .ident(let s)? = peek, s.lowercased() == "calendar" {
            throw DVError("CALENDAR пока не поддерживается")
        } else {
            throw DVError("Запрос должен начинаться с LIST, TABLE или TASK")
        }

        while let t = peek {
            if word("from") {
                q.source = try sourceOr()
            } else if word("where") {
                q.wheres.append(try expression())
            } else if word("sort") {
                repeat {
                    let e = try expression()
                    var asc = true
                    if word("desc") || word("descending") { asc = false } else { _ = word("asc") || word("ascending") }
                    q.sorts.append((e, asc))
                } while op(",")
            } else if word("limit") {
                guard case .number(let n)? = peek else { throw DVError("После LIMIT ожидалось число") }
                pos += 1
                q.limit = Int(n)
            } else if isWord(t, "group") {
                throw DVError("GROUP BY пока не поддерживается")
            } else if isWord(t, "flatten") {
                throw DVError("FLATTEN пока не поддерживается")
            } else {
                throw DVError("Лишнее в запросе: «\(Self.describe(tokens[pos...].prefix(3)))»")
            }
        }
        return q
    }

    /// The column's own text, as Dataview titles columns without AS.
    private static func describe<C: Collection>(_ ts: C) -> String where C.Element == DVToken {
        var s = ""
        for t in ts {
            switch t {
            case .number(let n): s += Dataview.format(n)
            case .string(let v): s += "\"\(v)\""
            case .ident(let v): s += v
            case .link(let v): s += "[[\(v)]]"
            case .tag(let v): s += "#" + v
            case .op(let o): s += [".", "(", ")", "[", "]"].contains(o) ? o : (o == "," ? ", " : " \(o) ")
            }
        }
        return s
    }

    // MARK: FROM

    private mutating func sourceOr() throws -> DVSource {
        var s = try sourceAnd()
        while word("or") || op("||") { s = .or(s, try sourceAnd()) }
        return s
    }

    private mutating func sourceAnd() throws -> DVSource {
        var s = try sourceUnary()
        while word("and") || op("&&") { s = .and(s, try sourceUnary()) }
        return s
    }

    private mutating func sourceUnary() throws -> DVSource {
        if op("-") || op("!") { return .not(try sourceUnary()) }
        switch peek {
        case .string(let s)?:
            pos += 1
            return .folder(s)
        case .tag(let t)?:
            pos += 1
            return .tag(t.lowercased())
        case .link(let l)?:
            pos += 1
            return .incoming(l.isEmpty ? nil : Dataview.link(l))
        case .ident(let w)? where w.lowercased() == "outgoing":
            pos += 1
            try expect("(")
            guard case .link(let l)? = peek else { throw DVError("outgoing() ждёт ссылку [[…]]") }
            pos += 1
            try expect(")")
            return .outgoing(l.isEmpty ? nil : Dataview.link(l))
        case .op("(")?:
            pos += 1
            let s = try sourceOr()
            try expect(")")
            return s
        default:
            throw DVError("После FROM ожидалась папка в кавычках, #тег или [[ссылка]]")
        }
    }

    // MARK: Expressions

    mutating func expression() throws -> DVExpr { try orExpr() }

    private mutating func orExpr() throws -> DVExpr {
        var e = try andExpr()
        while word("or") || op("||") { e = .binary("or", e, try andExpr()) }
        return e
    }

    private mutating func andExpr() throws -> DVExpr {
        var e = try comparison()
        while word("and") || op("&&") { e = .binary("and", e, try comparison()) }
        return e
    }

    private mutating func comparison() throws -> DVExpr {
        var e = try additive()
        while case .op(let o)? = peek, ["=", "!=", "<", "<=", ">", ">="].contains(o) {
            pos += 1
            e = .binary(o, e, try additive())
        }
        return e
    }

    private mutating func additive() throws -> DVExpr {
        var e = try multiplicative()
        while case .op(let o)? = peek, o == "+" || o == "-" {
            pos += 1
            e = .binary(o, e, try multiplicative())
        }
        return e
    }

    private mutating func multiplicative() throws -> DVExpr {
        var e = try unary()
        while case .op(let o)? = peek, ["*", "/", "%"].contains(o) {
            pos += 1
            e = .binary(o, e, try unary())
        }
        return e
    }

    private mutating func unary() throws -> DVExpr {
        if op("-") { return .unary("-", try unary()) }
        if op("!") { return .unary("!", try unary()) }
        return try postfix()
    }

    private mutating func postfix() throws -> DVExpr {
        var e = try primary()
        while true {
            if op(".") {
                guard case .ident(let name)? = peek else { throw DVError("После точки ожидалось имя поля") }
                pos += 1
                e = .member(e, name)
            } else if peek == .op("[") {
                pos += 1
                let i = try expression()
                try expect("]")
                e = .index(e, i)
            } else {
                return e
            }
        }
    }

    private mutating func primary() throws -> DVExpr {
        guard let t = peek else { throw DVError("Запрос оборвался") }
        switch t {
        case .number(let n):
            pos += 1
            return .literal(.number(n))
        case .string(let s):
            pos += 1
            return .literal(.string(s))
        case .link(let l):
            pos += 1
            return .literal(.link(Dataview.link(l)))
        case .tag(let s):
            pos += 1
            return .literal(.string("#" + s))
        case .ident(let name):
            pos += 1
            if peek == .op("=>") {                                        // t => t.completed
                pos += 1
                return .lambda([name], try expression())
            }
            switch name.lowercased() {
            case "true": return .literal(.bool(true))
            case "false": return .literal(.bool(false))
            case "null": return .literal(.null)
            default: break
            }
            if op("(") {
                var args: [DVExpr] = []
                if !op(")") {
                    repeat { args.append(try callArgument(of: name)) } while op(",")
                    try expect(")")
                }
                return .call(name.lowercased(), args)
            }
            return .field(name)
        case .op("("):
            if let params = lambdaParams() {
                return .lambda(params, try expression())
            }
            pos += 1
            let e = try expression()
            try expect(")")
            return e
        case .op("["):
            pos += 1
            var items: [DVExpr] = []
            if !op("]") {
                repeat { items.append(try expression()) } while op(",")
                try expect("]")
            }
            return .list(items)
        default:
            throw DVError("Непонятное место в запросе: «\(Self.describe([t]))»")
        }
    }

    /// `date(today)`, `dur(7 days)`: their bare words are text, not fields.
    private mutating func callArgument(of function: String) throws -> DVExpr {
        let f = function.lowercased()
        if f == "date", case .ident(let w)? = peek, Self.dateWords.contains(w.lowercased()), peek(1) == .op(")") || peek(1) == .op(",") {
            pos += 1
            return .literal(.string(w))
        }
        if f == "dur" {
            // dur(7 days), dur(1 week 2 days): numbers and unit words up to the closing bracket
            var parts: [String] = []
            var p = pos
            scan: while p < tokens.count {
                switch tokens[p] {
                case .number(let n): parts.append(Dataview.format(n))
                case .ident(let w): parts.append(w)
                case .op(")"), .op(","): break scan
                default: return try expression()
                }
                p += 1
            }
            if !parts.isEmpty { pos = p; return .literal(.string(parts.joined(separator: " "))) }
        }
        return try expression()
    }

    /// "(a, b) =>" ahead: consumes it and returns the parameter names.
    private mutating func lambdaParams() -> [String]? {
        var p = pos + 1
        var names: [String] = []
        while p < tokens.count {
            if case .ident(let n) = tokens[p] { names.append(n); p += 1 } else if tokens[p] != .op(")") { return nil }
            if p < tokens.count, tokens[p] == .op(",") { p += 1; continue }
            break
        }
        guard p + 1 < tokens.count, tokens[p] == .op(")"), tokens[p + 1] == .op("=>") else { return nil }
        pos = p + 2
        return names
    }
}

// MARK: - Running

nonisolated private struct DVRunner {
    let index: DVIndex
    let current: String?

    private var currentPage: DVPage? { current.flatMap { index.pages[$0] } }

    func run(_ q: DVQuery) throws -> DVResult {
        let ids = try pages(q.source).sorted()
        let this = currentPage.map { DVValue.object($0.fields) } ?? .null

        if q.kind == .task {
            var rows: [(task: TaskItem, scope: Scope)] = []
            for id in ids {
                guard let page = index.pages[id] else { continue }
                for t in page.tasks {
                    let scope = Scope(row: t.value(in: page), page: .object(page.fields), this: this)
                    rows.append((t, scope))
                }
            }
            rows = try rows.filter { r in try q.wheres.allSatisfy { try eval($0, r.scope).truthy } }
            rows = try sorted(rows, by: q.sorts) { $0.scope }
            if let l = q.limit { rows = Array(rows.prefix(l)) }
            // Grouped by note, in the order their first task comes.
            var order: [String] = [], groups: [String: [TaskItem]] = [:]
            for r in rows {
                if groups[r.task.path] == nil { order.append(r.task.path) }
                groups[r.task.path, default: []].append(r.task)
            }
            return .tasks(order.compactMap { id in index.pages[id].map { DVResult.TaskGroup(link: $0.link, tasks: groups[id] ?? []) } })
        }

        var rows: [(page: DVPage, scope: Scope)] = ids.compactMap { id in
            index.pages[id].map { ($0, Scope(row: .object($0.fields), page: .object($0.fields), this: this)) }
        }
        rows = try rows.filter { r in try q.wheres.allSatisfy { try eval($0, r.scope).truthy } }
        rows = try sorted(rows, by: q.sorts) { $0.scope }
        if let l = q.limit { rows = Array(rows.prefix(l)) }

        switch q.kind {
        case .list:
            return .list(try rows.map { r in
                let value = try q.columns.first.map { try eval($0.expr, r.scope) }
                return DVResult.ListItem(link: q.withoutID ? nil : r.page.link, value: value)
            })
        default:
            let headers = (q.withoutID ? [] : ["Файл"]) + q.columns.map(\.name)
            let table = try rows.map { r in
                (q.withoutID ? [] : [DVValue.link(r.page.link)]) + (try q.columns.map { try eval($0.expr, r.scope) })
            }
            return .table(headers: headers, rows: table, links: rows.map { $0.page.link })
        }
    }

    private func sorted<T>(_ rows: [T], by sorts: [(expr: DVExpr, ascending: Bool)], scope: (T) -> Scope) throws -> [T] {
        guard !sorts.isEmpty else { return rows }
        let keyed = try rows.map { r in (r, try sorts.map { try eval($0.expr, scope(r)) }) }
        return keyed.enumerated().sorted { a, b in
            for (k, s) in sorts.enumerated() {
                let c = compare(a.element.1[k], b.element.1[k])
                if c != 0 { return s.ascending ? c < 0 : c > 0 }
            }
            return a.offset < b.offset
        }.map(\.element.0)
    }

    // MARK: FROM

    private func pages(_ s: DVSource) throws -> Set<String> {
        switch s {
        case .all:
            return Set(index.pages.keys)
        case .folder(let raw):
            let f = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if f.isEmpty { return Set(index.pages.keys) }
            let lower = f.lowercased()
            return Set(index.pages.keys.filter {
                let id = $0.lowercased()
                return id.hasPrefix(lower + "/") || id == lower || id == lower + ".md"
            })
        case .tag(let t):
            return Set(index.pages.values.filter { p in
                p.tags.contains { $0 == t || $0.hasPrefix(t + "/") }
            }.map(\.id))
        case .incoming(let link):
            guard let key = link?.key ?? currentPage?.title.lowercased() else { return [] }
            return Set(index.inlinks[key] ?? [])
        case .outgoing(let link):
            guard let page = link.flatMap({ index.page(for: $0) }) ?? currentPage else { return [] }
            return Set(page.outlinks.compactMap { index.byTitle[$0] })
        case .and(let a, let b):
            return try pages(a).intersection(pages(b))
        case .or(let a, let b):
            return try pages(a).union(pages(b))
        case .not(let a):
            return Set(index.pages.keys).subtracting(try pages(a))
        }
    }

    // MARK: Expressions

    struct Scope {
        var row: DVValue
        var page: DVValue
        var this: DVValue
        var locals: [String: DVValue] = [:]
    }

    func eval(_ e: DVExpr, _ s: Scope) throws -> DVValue {
        switch e {
        case .literal(let v):
            return v
        case .field(let name):
            if let v = s.locals[name] { return v }
            if name == "this" { return s.this }
            if name == "row" { return s.row }
            let v = s.row[name]
            return v.isNull ? s.page[name] : v
        case .member(let base, let name):
            let b = try eval(base, s)
            if case .link(let l) = b {
                // [[note]].field reads the note's own fields.
                if let page = index.page(for: l) { return DVValue.object(page.fields)[name] }
                return b[name]
            }
            return b[name]
        case .index(let base, let i):
            let b = try eval(base, s), k = try eval(i, s)
            switch (b, k) {
            case (.list(let l), .number(let n)):
                let j = Int(n)
                return l.indices.contains(j) ? l[j] : .null
            case (_, .string(let key)):
                if case .link(let l) = b, let page = index.page(for: l) { return DVValue.object(page.fields)[key] }
                return b[key]
            default:
                return .null
            }
        case .list(let items):
            return .list(try items.map { try eval($0, s) })
        case .lambda(let params, let body):
            return .lambda(params, body)
        case .unary(let o, let x):
            let v = try eval(x, s)
            if o == "!" { return .bool(!v.truthy) }
            if case .number(let n) = v { return .number(-n) }
            if case .duration(let d) = v { return .duration(DVDuration(months: -d.months, seconds: -d.seconds)) }
            return .null
        case .binary(let o, let a, let b):
            if o == "and" { return .bool(try eval(a, s).truthy && eval(b, s).truthy) }
            if o == "or" { return .bool(try eval(a, s).truthy || eval(b, s).truthy) }
            return binary(o, try eval(a, s), try eval(b, s))
        case .call(let name, let args):
            return try call(name, args, s)
        }
    }

    private func apply(_ f: DVValue, _ args: [DVValue], _ s: Scope) throws -> DVValue {
        guard case .lambda(let params, let body) = f else { throw DVError("Ожидалась функция вида (x) => …") }
        var inner = s
        for (k, p) in params.enumerated() { inner.locals[p] = k < args.count ? args[k] : .null }
        return try eval(body, inner)
    }

    private func binary(_ o: String, _ a: DVValue, _ b: DVValue) -> DVValue {
        switch o {
        case "=": return .bool(equal(a, b))
        case "!=": return .bool(!equal(a, b))
        case "<": return .bool(!a.isNull && !b.isNull && compare(a, b) < 0)
        case "<=": return .bool(!a.isNull && !b.isNull && compare(a, b) <= 0)
        case ">": return .bool(!a.isNull && !b.isNull && compare(a, b) > 0)
        case ">=": return .bool(!a.isNull && !b.isNull && compare(a, b) >= 0)
        default: break
        }
        switch (o, a, b) {
        case ("+", .number(let x), .number(let y)): return .number(x + y)
        case ("-", .number(let x), .number(let y)): return .number(x - y)
        case ("*", .number(let x), .number(let y)): return .number(x * y)
        case ("/", .number(let x), .number(let y)): return y == 0 ? .null : .number(x / y)
        case ("%", .number(let x), .number(let y)): return y == 0 ? .null : .number(x.truncatingRemainder(dividingBy: y))
        case ("+", .list(let x), .list(let y)): return .list(x + y)
        case ("+", .date(let d), .duration(let u)), ("+", .duration(let u), .date(let d)): return .date(shift(d, u, 1))
        case ("-", .date(let d), .duration(let u)): return .date(shift(d, u, -1))
        case ("-", .date(let x), .date(let y)): return .duration(DVDuration(seconds: x.timeIntervalSince(y)))
        case ("+", .duration(let x), .duration(let y)): return .duration(DVDuration(months: x.months + y.months, seconds: x.seconds + y.seconds))
        case ("-", .duration(let x), .duration(let y)): return .duration(DVDuration(months: x.months - y.months, seconds: x.seconds - y.seconds))
        case ("*", .duration(let x), .number(let n)): return .duration(DVDuration(months: Int(Double(x.months) * n), seconds: x.seconds * n))
        case ("+", .string, _), ("+", _, .string): return .string(a.plain + b.plain)
        default: return .null
        }
    }

    private func shift(_ d: Date, _ u: DVDuration, _ sign: Int) -> Date {
        let m = Calendar.current.date(byAdding: .month, value: sign * u.months, to: d) ?? d
        return m.addingTimeInterval(Double(sign) * u.seconds)
    }

    func equal(_ a: DVValue, _ b: DVValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.link(let x), .link(let y)): return x.key == y.key
        case (.link(let x), .string(let y)), (.string(let y), .link(let x)): return x.key == DVLink(target: y, display: nil).key
        case (.list(let x), .list(let y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        default: return !a.isNull && !b.isNull && compare(a, b) == 0
        }
    }

    /// Order of values: null first, then by kind; numbers, dates, text and links by their value.
    func compare(_ a: DVValue, _ b: DVValue) -> Int {
        func rank(_ v: DVValue) -> Int {
            switch v {
            case .null: 0
            case .bool: 1
            case .number: 2
            case .duration: 3
            case .date: 4
            case .string: 5
            case .link: 6
            case .list: 7
            case .object: 8
            case .lambda: 9
            }
        }
        func cmp<T: Comparable>(_ x: T, _ y: T) -> Int { x < y ? -1 : (x > y ? 1 : 0) }
        switch (a, b) {
        case (.bool(let x), .bool(let y)): return cmp(x ? 1 : 0, y ? 1 : 0)
        case (.number(let x), .number(let y)): return cmp(x, y)
        case (.date(let x), .date(let y)): return cmp(x, y)
        case (.duration(let x), .duration(let y)): return cmp(Double(x.months) * 2_629_800 + x.seconds, Double(y.months) * 2_629_800 + y.seconds)
        case (.string(let x), .string(let y)): return cmp(x, y)
        case (.link(let x), .link(let y)): return cmp(x.title.lowercased(), y.title.lowercased())
        case (.link(let x), .string(let y)): return cmp(x.title.lowercased(), y.lowercased())
        case (.string(let x), .link(let y)): return cmp(x.lowercased(), y.title.lowercased())
        case (.list(let x), .list(let y)):
            for (p, q) in zip(x, y) { let c = compare(p, q); if c != 0 { return c } }
            return cmp(x.count, y.count)
        default: return cmp(rank(a), rank(b))
        }
    }

    // MARK: Functions

    private func call(_ name: String, _ argExprs: [DVExpr], _ s: Scope) throws -> DVValue {
        let args = try argExprs.map { try eval($0, s) }
        func arg(_ k: Int) -> DVValue { k < args.count ? args[k] : .null }
        func text(_ k: Int) -> String { arg(k).plain }
        switch name {
        case "length":
            switch arg(0) {
            case .list(let l): return .number(Double(l.count))
            case .string(let t): return .number(Double(t.count))
            case .object(let o): return .number(Double(o.count))
            case .null: return .number(0)
            default: return .number(1)
            }
        case "filter", "where":
            return .list(try arg(0).list.filter { try apply(arg(1), [$0], s).truthy })
        case "map":
            return .list(try arg(0).list.map { try apply(arg(1), [$0], s) })
        case "any":
            if args.count > 1, case .lambda = arg(1) { return .bool(try arg(0).list.contains { try apply(arg(1), [$0], s).truthy }) }
            return .bool((args.count == 1 ? arg(0).list : args).contains { $0.truthy })
        case "all":
            if args.count > 1, case .lambda = arg(1) { return .bool(try arg(0).list.allSatisfy { try apply(arg(1), [$0], s).truthy }) }
            return .bool((args.count == 1 ? arg(0).list : args).allSatisfy { $0.truthy })
        case "none":
            if args.count > 1, case .lambda = arg(1) { return .bool(!(try arg(0).list.contains { try apply(arg(1), [$0], s).truthy })) }
            return .bool(!arg(0).list.contains { $0.truthy })
        case "contains", "icontains", "econtains":
            let fold = name == "icontains"
            switch arg(0) {
            case .list(let l):
                if name == "econtains" { return .bool(l.contains { equal($0, arg(1)) }) }
                return .bool(l.contains { v in
                    if case .string(let x) = v, case .string(let y) = arg(1) { return fold ? x.lowercased().contains(y.lowercased()) : x.contains(y) }
                    return equal(v, arg(1))
                })
            case .string(let x):
                let y = text(1)
                return .bool(fold ? x.lowercased().contains(y.lowercased()) : (name == "econtains" ? x == y : x.contains(y)))
            case .object(let o):
                return .bool(o[text(1)] != nil)
            case .link(let l):
                return .bool(l.title.lowercased().contains(text(1).lowercased()))
            default:
                return .bool(false)
            }
        case "containsword":
            return .bool(text(0).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == Substring(text(1).lowercased()) })
        case "lower": return .string(text(0).lowercased())
        case "upper": return .string(text(0).uppercased())
        case "string": return .string(text(0))
        case "number":
            if case .number = arg(0) { return arg(0) }
            if let r = text(0).range(of: #"-?\d+(\.\d+)?"#, options: .regularExpression), let n = Double(text(0)[r]) { return .number(n) }
            return .null
        case "default":
            return arg(0).isNull ? arg(1) : arg(0)
        case "choice":
            return arg(0).truthy ? arg(1) : arg(2)
        case "round":
            guard case .number(let n) = arg(0) else { return .null }
            let digits = { if case .number(let d) = arg(1) { return Int(d) } else { return 0 } }()
            let f = pow(10, Double(digits))
            return .number((n * f).rounded() / f)
        case "floor", "ceil":
            guard case .number(let n) = arg(0) else { return .null }
            return .number(name == "floor" ? n.rounded(.down) : n.rounded(.up))
        case "sum", "average", "min", "max":
            let list = args.count == 1 ? arg(0).list : args
            let nums = list.compactMap { v -> Double? in if case .number(let n) = v { n } else { nil } }
            switch name {
            case "sum": return .number(nums.reduce(0, +))
            case "average": return nums.isEmpty ? .null : .number(nums.reduce(0, +) / Double(nums.count))
            default:
                let vals = list.filter { !$0.isNull }
                guard var best = vals.first else { return .null }
                for v in vals.dropFirst() where (name == "min" ? compare(v, best) < 0 : compare(v, best) > 0) { best = v }
                return best
            }
        case "sort":
            var l = arg(0).list
            if case .lambda = arg(1) {
                let keys = try l.map { try apply(arg(1), [$0], s) }
                l = zip(l, keys).sorted { compare($0.1, $1.1) < 0 }.map(\.0)
            } else {
                l.sort { compare($0, $1) < 0 }
            }
            return .list(l)
        case "reverse": return .list(arg(0).list.reversed())
        case "flat": return .list(arg(0).list.flatMap { $0.list })
        case "nonnull": return .list((args.count == 1 ? arg(0).list : args).filter { !$0.isNull })
        case "unique", "distinct":
            var out: [DVValue] = []
            for v in arg(0).list where !out.contains(where: { equal($0, v) }) { out.append(v) }
            return .list(out)
        case "join":
            return .string(arg(0).list.map(\.plain).joined(separator: args.count > 1 ? text(1) : ", "))
        case "split":
            return .list(text(0).components(separatedBy: text(1)).map { .string($0) })
        case "replace":
            return .string(text(0).replacingOccurrences(of: text(1), with: text(2)))
        case "regexreplace":
            return .string(text(0).replacingOccurrences(of: text(1), with: text(2), options: .regularExpression))
        case "regextest":
            return .bool(text(1).range(of: text(0), options: .regularExpression) != nil)
        case "regexmatch":
            return .bool(text(1).range(of: "^(?:" + text(0) + ")$", options: .regularExpression) != nil)
        case "startswith": return .bool(text(0).hasPrefix(text(1)))
        case "endswith": return .bool(text(0).hasSuffix(text(1)))
        case "substring":
            let t = Array(text(0))
            let a = { if case .number(let n) = arg(1) { return max(0, Int(n)) } else { return 0 } }()
            let b = { if case .number(let n) = arg(2) { return min(t.count, Int(n)) } else { return t.count } }()
            return .string(a < b ? String(t[a..<b]) : "")
        case "truncate":
            let t = text(0)
            let n = { if case .number(let n) = arg(1) { return Int(n) } else { return t.count } }()
            return .string(t.count > n ? String(t.prefix(n)) + (args.count > 2 ? text(2) : "…") : t)
        case "padleft", "padright":
            let t = text(0)
            let n = { if case .number(let n) = arg(1) { return Int(n) } else { return 0 } }()
            let pad = String(repeating: args.count > 2 ? text(2) : " ", count: max(0, n - t.count))
            return .string(name == "padleft" ? pad + t : t + pad)
        case "typeof":
            switch arg(0) {
            case .null: return .string("null")
            case .bool: return .string("boolean")
            case .number: return .string("number")
            case .string: return .string("string")
            case .date: return .string("date")
            case .duration: return .string("duration")
            case .link: return .string("link")
            case .list: return .string("array")
            case .object: return .string("object")
            case .lambda: return .string("function")
            }
        case "link":
            if case .link = arg(0) { return arg(0) }
            return .link(DVLink(target: text(0), display: args.count > 1 ? text(1) : nil))
        case "elink":
            return .string(args.count > 1 ? text(1) : text(0))
        case "meta":
            if case .link(let l) = arg(0) {
                return .object(["path": .string(l.target), "display": l.display.map(DVValue.string) ?? .null, "type": .string("file")])
            }
            return .null
        case "date":
            return date(arg(0), args.count > 1 ? text(1) : nil)
        case "dur":
            return duration(text(0)).map(DVValue.duration) ?? .null
        case "striptime":
            if case .date(let d) = arg(0) { return .date(Calendar.current.startOfDay(for: d)) }
            return .null
        case "dateformat":
            guard case .date(let d) = arg(0) else { return .null }
            let f = DateFormatter()
            f.locale = RuDate.locale
            f.dateFormat = luxonToICU(text(1))
            return .string(f.string(from: d))
        case "localtime":
            return arg(0)
        case "object":
            var o: [String: DVValue] = [:]
            for k in stride(from: 0, to: args.count - 1, by: 2) { o[args[k].plain] = args[k + 1] }
            return .object(o)
        case "list", "array":
            return .list(args)
        case "extract":
            var o: [String: DVValue] = [:]
            for k in args.dropFirst() { o[k.plain] = arg(0)[k.plain] }
            return .object(o)
        case "currencyformat":
            return arg(0)
        default:
            throw DVError("Функция \(name)() пока не поддерживается")
        }
    }

    private func date(_ v: DVValue, _ format: String?) -> DVValue {
        switch v {
        case .date: return v
        case .link(let l):
            if let p = index.page(for: l), case .object(let file)? = p.fields["file"], let day = file["day"] { return day }
            return Dataview.date(l.title).map(DVValue.date) ?? .null
        case .string(let raw):
            let cal = Calendar.current
            let today = cal.startOfDay(for: .now)
            switch raw.lowercased() {
            case "today": return .date(today)
            case "now": return .date(.now)
            case "tomorrow": return .date(cal.date(byAdding: .day, value: 1, to: today)!)
            case "yesterday": return .date(cal.date(byAdding: .day, value: -1, to: today)!)
            case "sow": return .date(cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today)
            case "eow": return .date(cal.date(byAdding: .day, value: 6, to: cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today)!)
            case "som": return .date(cal.dateInterval(of: .month, for: today)?.start ?? today)
            case "eom": return .date(cal.date(byAdding: .day, value: -1, to: cal.dateInterval(of: .month, for: today)?.end ?? today)!)
            case "soy": return .date(cal.dateInterval(of: .year, for: today)?.start ?? today)
            case "eoy": return .date(cal.date(byAdding: .day, value: -1, to: cal.dateInterval(of: .year, for: today)?.end ?? today)!)
            default: break
            }
            if let format {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = luxonToICU(format)
                return f.date(from: raw).map(DVValue.date) ?? .null
            }
            return Dataview.date(raw).map(DVValue.date) ?? .null
        default:
            return .null
        }
    }

    /// "7 days", "1 week 2 days", "3h", "1 month".
    private func duration(_ raw: String) -> DVDuration? {
        let re = try! NSRegularExpression(pattern: "(-?\\d+(?:\\.\\d+)?)\\s*([a-zа-я]+)", options: .caseInsensitive)
        let ns = raw as NSString
        var d = DVDuration()
        var any = false
        for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let n = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            any = true
            switch unit {
            case "s", "sec", "secs", "second", "seconds": d.seconds += n
            case "m", "min", "mins", "minute", "minutes": d.seconds += n * 60
            case "h", "hr", "hrs", "hour", "hours": d.seconds += n * 3600
            case "d", "day", "days": d.seconds += n * 86400
            case "w", "wk", "wks", "week", "weeks": d.seconds += n * 7 * 86400
            case "mo", "month", "months": d.months += Int(n)
            case "y", "yr", "yrs", "year", "years": d.months += Int(n) * 12
            default: any = false
            }
        }
        return any ? d : nil
    }

    /// Luxon's tokens ("yyyy-MM-dd", "cccc", "WW") into DateFormatter's.
    private func luxonToICU(_ f: String) -> String {
        f.replacingOccurrences(of: "cccc", with: "EEEE")
            .replacingOccurrences(of: "ccc", with: "EEE")
            .replacingOccurrences(of: "WW", with: "ww")
            .replacingOccurrences(of: "kkkk", with: "YYYY")
    }
}

import Foundation

/// A checkbox line as the Obsidian Tasks plugin reads it:
///
///     - [ ] Выучить [[E01-01 am is are]] ⏫ 🔁 every week 📅 2026-10-18 ✅ 2026-10-18
///
/// Dates and the priority sit at the end of the line; what's left is the description.
nonisolated struct TaskItem: Hashable, Sendable {
    /// Note id and 0-based line number, to find the line again when the box is ticked.
    var path: String
    var line: Int
    /// The character between the brackets: " ", "x", "/", "-" …
    var status: String
    /// Everything after the checkbox, as written.
    var text: String
    /// The text without the Tasks metadata.
    var description: String
    var due: Date?
    var scheduled: Date?
    var start: Date?
    var created: Date?
    var done: Date?
    var cancelled: Date?
    /// 0 highest (🔺), 1 high (⏫), 2 medium (🔼), 3 normal, 4 low (🔽), 5 lowest (⏬).
    var priority = 3
    var recurrence: String?
    var indent = 0

    var completed: Bool { status.lowercased() == "x" }
    var checked: Bool { status != " " }
}

nonisolated enum Tasks {

    private static let line = try! NSRegularExpression(pattern: "^([ \\t]*)[-*+][ \\t]+\\[(.)\\][ \\t]+(.*)$")
    private static let dateField = try! NSRegularExpression(pattern: "[ \\t]*(📅|⏳|🛫|✅|➕|❌)\u{FE0F}?[ \\t]*(\\d{4}-\\d{2}-\\d{2})[ \\t]*$")
    private static let priorityField = try! NSRegularExpression(pattern: "[ \\t]*(🔺|⏫|🔼|🔽|⏬)\u{FE0F}?[ \\t]*$")
    private static let recurrenceField = try! NSRegularExpression(pattern: "[ \\t]*🔁\u{FE0F}?[ \\t]*((?:every|каждый|каждую|каждое)\\b[^📅⏳🛫✅➕❌🔺⏫🔼🔽⏬]*?)[ \\t]*$", options: [.caseInsensitive])
    private static let trailingTag = try! NSRegularExpression(pattern: "[ \\t]+(#[\\p{L}\\p{N}_/-]+)[ \\t]*$")
    /// A date with its emoji anywhere in a line (for styling in the editor).
    static let dateToken = try! NSRegularExpression(pattern: "(📅|⏳|🛫|✅|➕|❌)\u{FE0F}?[ \\t]*(\\d{4}-\\d{2}-\\d{2})")
    /// Emojis that mark a line as written for the Tasks plugin.
    static let markers: [String] = ["📅", "⏳", "🛫", "➕", "🔁", "✅", "❌", "🔺", "⏫", "🔼", "🔽", "⏬"]

    /// Every checkbox line of a note (code blocks and the frontmatter skipped).
    static func parse(_ text: String, path: String) -> [TaskItem] {
        var out: [TaskItem] = []
        var inCode = false
        var inFrontmatter = text.hasPrefix("---")
        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
            let l = raw.replacingOccurrences(of: "\r", with: "")
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if inFrontmatter {
                if n > 0 && trimmed == "---" { inFrontmatter = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inCode.toggle(); continue }
            if inCode { continue }
            if let t = item(l, path: path, line: n) { out.append(t) }
        }
        return out
    }

    /// One line read as a task, or nil if it isn't a checkbox line.
    static func item(_ l: String, path: String, line n: Int) -> TaskItem? {
        let ns = l as NSString
        guard let m = line.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: m.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = ns.substring(with: m.range(at: 3))
        var task = TaskItem(path: path, line: n, status: ns.substring(with: m.range(at: 2)), text: body, description: body, indent: indent)
        var rest = body
        var tags: [String] = []
        // Metadata is read from the end, one field at a time, like the Tasks plugin does.
        while true {
            let r = rest as NSString
            let all = NSRange(location: 0, length: r.length)
            if let d = dateField.firstMatch(in: rest, range: all) {
                let date = day(r.substring(with: d.range(at: 2)))
                switch r.substring(with: d.range(at: 1)) {
                case "📅": task.due = task.due ?? date
                case "⏳": task.scheduled = task.scheduled ?? date
                case "🛫": task.start = task.start ?? date
                case "✅": task.done = task.done ?? date
                case "➕": task.created = task.created ?? date
                default: task.cancelled = task.cancelled ?? date
                }
                rest = r.substring(to: d.range.location)
            } else if let p = priorityField.firstMatch(in: rest, range: all) {
                task.priority = ["🔺": 0, "⏫": 1, "🔼": 2, "🔽": 4, "⏬": 5][r.substring(with: p.range(at: 1))] ?? 3
                rest = r.substring(to: p.range.location)
            } else if let e = recurrenceField.firstMatch(in: rest, range: all) {
                task.recurrence = r.substring(with: e.range(at: 1))
                rest = r.substring(to: e.range.location)
            } else if let t = trailingTag.firstMatch(in: rest, range: all), task.due != nil || task.done != nil || task.scheduled != nil {
                tags.insert(r.substring(with: t.range(at: 1)), at: 0)    // tags between fields stay part of the text
                rest = r.substring(to: t.range.location)
            } else {
                break
            }
        }
        task.description = ([rest.trimmingCharacters(in: .whitespaces)] + tags).joined(separator: " ")
        return task
    }

    /// The line with its box ticked or unticked. A line written for Tasks (it carries 📅, ⏳ …) also gets
    /// "✅ today" when ticked and loses it when unticked, as the plugin does.
    static func toggled(_ l: String, today: Date = .now) -> String {
        let ns = l as NSString
        guard let m = line.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { return l }
        let box = m.range(at: 2)
        let wasDone = ns.substring(with: box).lowercased() == "x"
        var out = ns.replacingCharacters(in: box, with: wasDone ? " " : "x")
        let isTasksLine = markers.contains { out.contains($0) }
        if wasDone {
            out = out.replacingOccurrences(of: "[ \\t]*✅\u{FE0F}?[ \\t]*\\d{4}-\\d{2}-\\d{2}", with: "", options: .regularExpression)
        } else if isTasksLine, !out.contains("✅") {
            var trimmed = out
            while trimmed.hasSuffix(" ") || trimmed.hasSuffix("\t") { trimmed.removeLast() }
            out = trimmed + " ✅ " + string(today)
        }
        return out
    }

    // MARK: Days

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// "2026-10-18" → local midnight of that day.
    static func day(_ s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func string(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func startOfToday(_ now: Date = .now) -> Date { calendar.startOfDay(for: now) }
}

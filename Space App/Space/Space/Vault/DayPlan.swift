import SwiftUI

/// Today's tasks as stars on the line of the day: what is done, what is ahead, what is about to go out.
/// A task belongs to today when it is due or scheduled today or earlier (and still open), or was done today.
/// A time in its text ("созвон 13:30") places it on the line; tasks without one are spread over the day.
nonisolated struct DayStar: Identifiable, Hashable, Sendable {
    enum State: Sendable { case done, ahead, dying }

    let task: TaskItem
    let title: String
    /// Hour of the day (13.5 = 13:30); for tasks with no time, the place they were given on the line.
    let hour: Double
    let timed: Bool
    let state: State
    let overdue: Bool

    var id: String { task.path + ":" + String(task.line) }
    var time: String {
        guard timed else { return "" }
        return String(format: "%d:%02d", Int(hour), Int((hour - floor(hour)) * 60 + 0.5))
    }
}

nonisolated enum DayPlan {
    /// The day the line spans, in hours.
    static let start: Double = 8, end: Double = 23
    /// An open task this close to its time (or past it) is "going out".
    static let dyingWithin: Double = 2

    private static let timePattern = try! NSRegularExpression(pattern: "(?<![\\d:.])([01]?\\d|2[0-3])[:.]([0-5]\\d)(?![\\d:])")

    static func stars(_ index: DVIndex, now: Date = .now) -> [DayStar] {
        let today = Tasks.startOfToday(now)
        let tomorrow = today.addingTimeInterval(24 * 3600)
        let cal = Calendar.current
        let nowHour = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
        var picked: [(TaskItem, Double?, DayStar.State, Bool)] = []
        for page in index.pages.values {
            for t in page.tasks {
                let when = t.due ?? t.scheduled
                let hour = Self.hour(in: t.description)
                if t.completed {
                    guard let done = t.done, done >= today, done < tomorrow else { continue }
                    picked.append((t, hour, .done, false))
                } else if !t.checked, let when, when < tomorrow {
                    let overdue = when < today
                    let late = hour.map { $0 - nowHour <= dyingWithin } ?? false
                    picked.append((t, hour, overdue || late ? .dying : .ahead, overdue))
                }
            }
        }
        // Timed ones first by time; the rest keep the order of their notes.
        picked.sort { a, b in
            switch (a.1, b.1) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.0.path, a.0.line) < (b.0.path, b.0.line)
            }
        }
        let untimed = picked.filter { $0.1 == nil }.count
        var slot = 0
        return picked.prefix(14).map { t, hour, state, overdue in
            var h = hour ?? 0
            if hour == nil {
                // Spread evenly over the waking hours.
                slot += 1
                h = 9 + 12 * Double(slot) / Double(untimed + 1)
            }
            return DayStar(task: t, title: Self.title(t.description), hour: min(max(h, start), end),
                           timed: hour != nil, state: state, overdue: overdue)
        }
    }

    static func hour(in text: String) -> Double? {
        let ns = text as NSString
        guard let m = timePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let h = Double(ns.substring(with: m.range(at: 1))), let mm = Double(ns.substring(with: m.range(at: 2))) else { return nil }
        return h + mm / 60
    }

    /// The task's words without its time, links' brackets and tags.
    static func title(_ text: String) -> String {
        let ns = text as NSString
        var s = timePattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        s = s.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        s = s.replacingOccurrences(of: "#[\\p{L}\\p{N}_/-]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—,:")).isEmpty ? text : s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—,:"))
    }

    /// The one thing to do now: what is going out first, else the next one ahead.
    static func now(_ stars: [DayStar]) -> DayStar? {
        stars.first { $0.state == .dying } ?? stars.first { $0.state == .ahead }
    }

    /// Done fraction of the tasks in each universe (only universes that have tasks).
    static func progress(_ index: DVIndex, cosmos: Cosmos) -> [String: (done: Int, total: Int)] {
        var out: [String: (done: Int, total: Int)] = [:]
        for page in index.pages.values where !page.tasks.isEmpty {
            guard let u = cosmos.universeOf[page.id] else { continue }
            let done = page.tasks.filter(\.completed).count
            let total = page.tasks.filter { $0.status != "-" }.count
            let old = out[u] ?? (0, 0)
            out[u] = (old.done + done, old.total + total)
        }
        return out.filter { $0.value.total > 0 }
    }
}

extension VaultStore {
    /// Moves a task's date to tomorrow: its 📅 (or ⏳) date, or a new 📅 if it had none.
    func postponeToTomorrow(_ task: TaskItem) {
        var lines = text(of: task.path).components(separatedBy: "\n")
        guard lines.indices.contains(task.line), Tasks.item(lines[task.line], path: task.path, line: task.line) != nil else { return }
        let tomorrow = Tasks.string(Tasks.startOfToday().addingTimeInterval(24 * 3600))
        var line = lines[task.line]
        if let r = line.range(of: "(📅|⏳)\u{FE0F}?[ \\t]*\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) {
            let marker = line[r].hasPrefix("⏳") ? "⏳" : "📅"
            line.replaceSubrange(r, with: marker + " " + tomorrow)
        } else {
            line += " 📅 " + tomorrow
        }
        lines[task.line] = line
        save(task.path, text: lines.joined(separator: "\n"))
    }
}

/// Notes pinned to the top of the sidebar, remembered per vault.
@MainActor
@Observable
final class Pins {
    static let shared = Pins()
    private(set) var ids: [String] = []
    private var key = ""

    func load(vault name: String) {
        key = "space.pins." + name
        ids = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        if !key.isEmpty { UserDefaults.standard.set(ids, forKey: key) }
    }

    /// A pinned note was renamed or moved.
    func retarget(old: String, new: String) {
        guard let i = ids.firstIndex(of: old) else { return }
        ids[i] = new
        if !key.isEmpty { UserDefaults.standard.set(ids, forKey: key) }
    }
}

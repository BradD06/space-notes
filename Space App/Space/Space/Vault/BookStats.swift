import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// How far you got in each book of the vault and how long you've been reading it.
/// Kept in the vault's ".space/books.json", so it travels with the vault.
@MainActor
@Observable
final class BookStats {
    static let shared = BookStats()

    nonisolated struct Stat: Codable, Equatable, Sendable {
        /// Where you stopped last time.
        var page = 1
        /// The furthest page you've reached: what "read" means for the progress bar.
        var furthest = 1
        var pages = 0
        /// Time spent reading, in seconds.
        var seconds: Double = 0
        var started: Date?
        var lastRead: Date?

        /// 0…1. A book read to its last page is done.
        var progress: Double { pages > 0 ? min(1, Double(furthest) / Double(pages)) : 0 }
    }

    private(set) var stats: [String: Stat] = [:]
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        #if os(macOS)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BookStats.shared.flush() }
        }
        #endif
    }

    private var url: URL? { root?.appending(path: ".space", directoryHint: .isDirectory).appending(path: "books.json") }

    func load(root: URL?) {
        flush()
        self.root = root
        stats = [:]
        if let url, let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder.iso.decode([String: Stat].self, from: data) { stats = s }
    }

    func stat(_ id: String) -> Stat {
        if let s = stats[id] { return s }
        // Pages remembered before the stats existed.
        let saved = UserDefaults.standard.integer(forKey: "space.book.page." + id)
        return saved > 0 ? Stat(page: saved, furthest: saved) : Stat()
    }

    /// The book is open at `page` of `pages`.
    func reached(page: Int, of pages: Int, in id: String) {
        var s = stat(id)
        guard s.page != page || s.pages != pages || page > s.furthest || s.started == nil else { return }
        s.page = page
        s.pages = pages
        s.furthest = max(s.furthest, page)
        if s.started == nil { s.started = Date() }
        stats[id] = s
        scheduleSave()
    }

    func addReading(_ seconds: Double, to id: String) {
        var s = stat(id)
        s.seconds += seconds
        s.lastRead = Date()
        if s.started == nil { s.started = Date() }
        stats[id] = s
        scheduleSave()
    }

    /// The book was moved or renamed: its numbers go along.
    func rename(_ old: String, to new: String) {
        guard let s = stats.removeValue(forKey: old) else { return }
        stats[new] = s
        scheduleSave()
    }

    /// "3 ч 20 мин", "12 мин", "меньше минуты".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return seconds > 0 ? "меньше минуты" : "ещё не читали" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) мин" }
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard let url, !stats.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(stats) { try? data.write(to: url, options: .atomic) }
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}

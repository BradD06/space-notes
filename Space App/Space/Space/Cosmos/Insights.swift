import Foundation

/// What the map can tell about the vault beyond the picture: stars that need attention.
///
/// - hubs       = the most connected stars, landmarks of the vault
/// - orphans    = stars with no links at all; nothing leads to them
/// - forgotten  = stars that once mattered (have links) but haven't been touched for a long time
/// - suggestions = pairs of stars that are not linked but probably should be: they share neighbours
///                 (both link to the same notes) and/or tags
nonisolated struct Insights: Sendable {

    struct Suggestion: Hashable, Sendable {
        let a: String
        let b: String
        /// Why: the notes both stars link to, and the tags they share.
        let via: [String]
        let tags: [String]
        let score: Double

        func other(than id: String) -> String { id == a ? b : a }
    }

    /// Untouched for this long counts as forgotten.
    static let forgottenAfter: TimeInterval = 60 * 24 * 3600

    private(set) var hubs: [String] = []
    private(set) var orphans: [String] = []
    private(set) var forgotten: [String] = []
    private(set) var recent: [String] = []
    private(set) var suggestions: [Suggestion] = []
    /// Suggestions for each star, best first.
    private(set) var suggestionsFor: [String: [Suggestion]] = [:]
    /// Per universe: how many orphans it holds.
    private(set) var orphansIn: [String: Int] = [:]
    let orphanSet: Set<String>
    let forgottenSet: Set<String>
    /// Stars that are part of some suggestion.
    let suggestedSet: Set<String>
    /// The two or three biggest stars of each universe: always named on the map, so it can be read at a glance.
    private(set) var landmarks: Set<String> = []

    init(_ cosmos: Cosmos, now: Date = .now) {
        // Books (PDF) live on the map but are not written in, so they are left out of the hints.
        let ids = cosmos.notes.keys.filter { !Books.isBook($0) }
        let title: (String) -> String = { cosmos.title($0) }
        let byTitle: (String, String) -> Bool = { title($0).localizedStandardCompare(title($1)) == .orderedAscending }

        hubs = ids.filter { cosmos.degree($0) >= 2 }
            .sorted { (cosmos.degree($0), title($1)) > (cosmos.degree($1), title($0)) }
            .prefix(12).map { $0 }

        orphans = ids.filter { cosmos.degree($0) == 0 }
            .sorted { (cosmos.notes[$0]?.modified ?? .distantPast) > (cosmos.notes[$1]?.modified ?? .distantPast) }
        orphanSet = Set(orphans)
        for id in orphans { orphansIn[cosmos.universeOf[id] ?? "", default: 0] += 1 }

        // The more links a forgotten star has, the more it is worth coming back to.
        let cutoff = now.addingTimeInterval(-Self.forgottenAfter)
        forgotten = ids.filter { cosmos.degree($0) > 0 && (cosmos.notes[$0]?.modified ?? now) < cutoff }
            .sorted { (cosmos.degree($0), cosmos.notes[$1]?.modified ?? now) > (cosmos.degree($1), cosmos.notes[$0]?.modified ?? now) }
        forgottenSet = Set(forgotten)

        for u in cosmos.universes {
            let top = u.constellations.flatMap(\.noteIDs).filter { cosmos.degree($0) >= 3 }
                .sorted { (cosmos.degree($0), title($1)) > (cosmos.degree($1), title($0)) }
            landmarks.formUnion(top.prefix(u.starCount > 40 ? 3 : 2))
        }

        recent = ids.sorted { (cosmos.notes[$0]?.modified ?? .distantPast) > (cosmos.notes[$1]?.modified ?? .distantPast) }
            .prefix(8).map { $0 }

        // Candidate pairs: two hops apart (a common neighbour), or sharing a tag.
        // A common neighbour counts for more when it is a small note (Adamic–Adar): two stars that both
        // link to a big hub like "Index" say little, two that both link to a niche note say a lot.
        var score: [Cosmos.Edge: Double] = [:]
        var via: [Cosmos.Edge: [String]] = [:]
        for n in ids {
            guard let around = cosmos.neighbors[n], around.count >= 2, around.count <= 60 else { continue }
            let weight = 1 / log(Double(around.count) + 1)
            let list = around.sorted()
            for i in 0..<list.count {
                for j in (i + 1)..<list.count {
                    let a = list[i], b = list[j]
                    guard !Books.isBook(a), !Books.isBook(b), !(cosmos.neighbors[a]?.contains(b) ?? false) else { continue }
                    let e = Cosmos.Edge(a, b)
                    score[e, default: 0] += weight
                    via[e, default: []].append(n)
                }
            }
        }
        var byTag: [String: [String]] = [:]
        for id in ids { for t in Set(cosmos.notes[id]?.tags.map { $0.lowercased() } ?? []) { byTag[t, default: []].append(id) } }
        var tagsOf: [Cosmos.Edge: [String]] = [:]
        for (tag, members) in byTag where members.count >= 2 && members.count <= 25 {
            // A rare tag is a strong hint, a tag on half the vault is not.
            let weight = 0.8 / log(Double(members.count) + 1)
            let list = members.sorted()
            for i in 0..<list.count {
                for j in (i + 1)..<list.count {
                    let a = list[i], b = list[j]
                    guard !(cosmos.neighbors[a]?.contains(b) ?? false) else { continue }
                    let e = Cosmos.Edge(a, b)
                    score[e, default: 0] += weight
                    tagsOf[e, default: []].append(tag)
                }
            }
        }
        // One shared neighbour alone is weak; it takes two signals, or one rare one.
        let all = score.compactMap { e, s -> Suggestion? in
            guard s >= 0.9 else { return nil }
            return Suggestion(a: e.a, b: e.b, via: (via[e] ?? []).sorted(by: byTitle), tags: (tagsOf[e] ?? []).sorted(), score: s)
        }
        .sorted { ($0.score, $1.a, $1.b) > ($1.score, $0.a, $0.b) }
        for s in all {
            if (suggestionsFor[s.a]?.count ?? 0) < 5 { suggestionsFor[s.a, default: []].append(s) }
            if (suggestionsFor[s.b]?.count ?? 0) < 5 { suggestionsFor[s.b, default: []].append(s) }
        }
        // The overall list: the best pairs, no star more than twice, so it doesn't fill up with one hub's friends.
        var used: [String: Int] = [:]
        for s in all where suggestions.count < 40 {
            guard used[s.a, default: 0] < 2, used[s.b, default: 0] < 2 else { continue }
            suggestions.append(s)
            used[s.a, default: 0] += 1
            used[s.b, default: 0] += 1
        }
        suggestedSet = Set(suggestions.flatMap { [$0.a, $0.b] })
    }
}

/// Keeps one `Insights` per version of the vault, so the dashboard and the map share the work.
@MainActor
enum InsightsCache {
    private static var generation = -1
    private static var value = Insights(Cosmos())

    static func insights(_ vault: VaultStore) -> Insights {
        if generation != vault.generation {
            value = Insights(vault.cosmos)
            generation = vault.generation
        }
        return value
    }
}

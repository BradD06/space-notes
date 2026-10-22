import Foundation

/// The vault as a map that can be read: groups (universes) of constellations, sized by how many notes they hold.
///
/// The groups are chosen from the data, so any vault works:
/// - folders  = top-level folders, constellations = second-level folders;
/// - tags     = the most used tag of every note, constellations = its nested tag;
/// - clusters = communities of the link graph, named after their most linked note.
/// Without folders the map falls back to tags, without tags to clusters.
nonisolated struct Atlas: Sendable {

    enum Grouping: String, CaseIterable, Identifiable, Sendable {
        case folders, tags, clusters
        var id: String { rawValue }
        var title: String {
            switch self {
            case .folders: "Папки"
            case .tags: "Теги"
            case .clusters: "Кластеры"
            }
        }
        /// "Ещё 23 папки"
        func more(_ n: Int) -> String {
            switch self {
            case .folders: "Ещё \(n) \(plural(n, "папка", "папки", "папок"))"
            case .tags: "Ещё \(n) \(plural(n, "тег", "тега", "тегов"))"
            case .clusters: "Ещё \(n) \(plural(n, "кластер", "кластера", "кластеров"))"
            }
        }
    }

    struct Constellation: Identifiable, Sendable {
        let id: String
        let name: String
        let groupID: String
        /// Most linked first.
        let noteIDs: [String]
        /// The note the constellation turns around: its most linked one, if it has links at all.
        let head: String?
        /// The notes that are drawn; in a vault of thousands only the most linked ones, the rest is a number.
        let shown: [String]
        var count: Int { noteIDs.count }
    }

    struct Group: Identifiable, Sendable {
        let id: String
        let name: String
        let constellations: [Constellation]
        let modified: Date
        /// The bucket of small groups folded together ("Ещё 23 папки").
        let isOthers: Bool
        let count: Int
        var noteIDs: [String] { constellations.flatMap(\.noteIDs) }
    }

    /// Links between two groups (or two constellations), counted once.
    struct Bridge: Hashable, Sendable {
        let a: String
        let b: String
        let count: Int
        func other(than id: String) -> String { id == a ? b : a }
    }

    /// Below this the map has no atlas: every star is on one screen, with its name.
    static let tinyLimit = 30
    /// The most stars drawn in one group; the rest is shown as a number.
    static let starBudget = 80
    /// Groups smaller than this share of the vault are folded into "Ещё N", once the vault is big.
    static let smallShare = 0.02
    static let othersID = "others"
    static let untaggedName = "Без тегов"
    static let unlinkedName = "Без связей"

    let grouping: Grouping
    /// What the map picks by itself for this vault.
    let automatic: Grouping
    let total: Int
    private(set) var groups: [Group] = []
    private(set) var groupOf: [String: String] = [:]
    private(set) var constellationOf: [String: String] = [:]
    private(set) var bridges: [Bridge] = []
    /// Links between constellations of one group, by group id.
    private(set) var innerBridges: [String: [Bridge]] = [:]
    /// Notes with an unusually large number of links (about the top 2 %), found by degree, never by name.
    private(set) var hubs: Set<String> = []
    /// How many small groups were folded into "Ещё N".
    private(set) var foldedCount = 0
    private var groupIndex: [String: Int] = [:]
    private var constellationIndex: [String: (Int, Int)] = [:]

    var isTiny: Bool { total <= Self.tinyLimit }
    var isLarge: Bool { total > 1000 }

    init(_ cosmos: Cosmos = Cosmos(), grouping requested: Grouping? = nil, expandOthers: Bool = false) {
        let ids = cosmos.notes.keys.sorted()
        total = ids.count
        automatic = Self.pick(cosmos)
        grouping = requested ?? automatic
        hubs = Self.findHubs(cosmos)

        // Raw buckets: group name → constellation name → notes.
        var raw: [(id: String, name: String, cons: [(id: String, name: String, ids: [String])])]
        switch grouping {
        case .folders: raw = Self.byFolders(cosmos)
        case .tags: raw = Self.byTags(cosmos, ids: ids)
        case .clusters: raw = Self.byClusters(cosmos, ids: ids)
        }
        raw.removeAll { g in g.cons.allSatisfy(\.ids.isEmpty) }

        // Small groups fold into one, once there are many of them and the vault is big enough to need it.
        let limit = Double(total) * Self.smallShare
        let small = raw.filter { Double($0.cons.reduce(0) { $0 + $1.ids.count }) < limit }
        if !expandOthers, total >= 200, raw.count > 6, small.count >= 2 {
            let names = Set(small.map(\.id))
            raw.removeAll { names.contains($0.id) }
            raw.append((Self.othersID, grouping.more(small.count), [(Self.othersID + "/", "", small.flatMap { $0.cons.flatMap(\.ids) })]))
            foldedCount = small.count
        }

        let degree: (String) -> Int = { cosmos.degree($0) }
        let byDegree: (String, String) -> Bool = { a, b in
            let da = degree(a), db = degree(b)
            return da != db ? da > db : cosmos.title(a).localizedStandardCompare(cosmos.title(b)) == .orderedAscending
        }
        groups = raw.map { g in
            let count = g.cons.reduce(0) { $0 + $1.ids.count }
            // In a big group only the most linked stars are drawn, shared out between its constellations.
            let limited = total > 1000 && count > Self.starBudget
            let cons = g.cons.filter { !$0.ids.isEmpty }.map { c -> Constellation in
                let sorted = c.ids.sorted(by: byDegree)
                let share = !limited ? sorted.count
                    : max(min(3, sorted.count), Int((Double(Self.starBudget) * Double(sorted.count) / Double(count)).rounded()))
                let head = sorted.first.flatMap { degree($0) >= 2 ? $0 : nil }
                return Constellation(id: c.id, name: c.name, groupID: g.id, noteIDs: sorted, head: head, shown: Array(sorted.prefix(share)))
            }
            let modified = cons.flatMap(\.noteIDs).compactMap { cosmos.notes[$0]?.modified }.max() ?? .distantPast
            return Group(id: g.id, name: g.name, constellations: cons, modified: modified, isOthers: g.id == Self.othersID, count: count)
        }
        // Biggest first, the folded bucket last: that order also hands out the colours.
        groups.sort { a, b in
            if a.isOthers != b.isOthers { return b.isOthers }
            return a.count != b.count ? a.count > b.count : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for (gi, g) in groups.enumerated() {
            groupIndex[g.id] = gi
            for (ci, c) in g.constellations.enumerated() {
                constellationIndex[c.id] = (gi, ci)
                for id in c.noteIDs { groupOf[id] = g.id; constellationOf[id] = c.id }
            }
        }

        var between: [Cosmos.Edge: Int] = [:]
        var inside: [String: [Cosmos.Edge: Int]] = [:]
        for e in cosmos.edges {
            guard let ga = groupOf[e.a], let gb = groupOf[e.b] else { continue }
            if ga != gb { between[Cosmos.Edge(ga, gb), default: 0] += 1; continue }
            // Inside a universe a hub would tie every constellation to its own; those links are left to the orbit.
            guard !hubs.contains(e.a), !hubs.contains(e.b), let ca = constellationOf[e.a], let cb = constellationOf[e.b], ca != cb else { continue }
            inside[ga, default: [:]][Cosmos.Edge(ca, cb), default: 0] += 1
        }
        let sortBridges: ([Cosmos.Edge: Int]) -> [Bridge] = { map in
            map.map { Bridge(a: $0.key.a, b: $0.key.b, count: $0.value) }.sorted { ($0.count, $1.a, $1.b) > ($1.count, $0.a, $0.b) }
        }
        bridges = sortBridges(between)
        innerBridges = inside.mapValues(sortBridges)
    }

    func group(_ id: String) -> Group? { groupIndex[id].map { groups[$0] } }

    func constellation(_ id: String) -> Constellation? {
        constellationIndex[id].map { groups[$0.0].constellations[$0.1] }
    }

    /// Position of a group in size order; the default colours follow it.
    func rank(of group: String) -> Int { groupIndex[group] ?? 0 }

    /// Links from this group to each other group, most first.
    func bridges(of group: String) -> [Bridge] { bridges.filter { $0.a == group || $0.b == group } }

    func links(between a: String, and b: String) -> Int {
        bridges.first { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }?.count ?? 0
    }

    /// The group is the folder itself, so its colour is the one the user gave the universe.
    var colorsFollowUniverses: Bool { grouping == .folders }

    // MARK: Choosing the grouping

    /// Folders when the vault has them, else tags when enough notes carry one, else link clusters.
    static func pick(_ cosmos: Cosmos) -> Grouping {
        let folders = cosmos.universes.filter { $0.name != Cosmos.inboxName && $0.starCount > 0 }
        if folders.count >= 2 || (folders.count == 1 && cosmos.universes.count >= 2) { return .folders }
        let tagged = cosmos.notes.values.filter { !$0.tags.isEmpty }.count
        if tagged * 10 >= cosmos.notes.count * 3, tagged > 0 { return .tags }
        return .clusters
    }

    /// The degree that makes a hub: about the top 2 % of linked notes, and well above the average.
    static func findHubs(_ cosmos: Cosmos) -> Set<String> {
        let degrees = cosmos.notes.keys.map { cosmos.degree($0) }.filter { $0 > 0 }.sorted()
        guard degrees.count >= 5 else { return [] }
        let p98 = degrees[Int(Double(degrees.count - 1) * 0.98)]
        let mean = Double(degrees.reduce(0, +)) / Double(degrees.count)
        let threshold = max(6, p98, Int((3 * mean).rounded(.up)))
        return Set(cosmos.notes.keys.filter { cosmos.degree($0) >= threshold })
    }

    // MARK: Grouping by folders

    private typealias RawGroup = (id: String, name: String, cons: [(id: String, name: String, ids: [String])])

    private static func byFolders(_ cosmos: Cosmos) -> [RawGroup] {
        cosmos.universes.map { u in
            (u.id, u.name, u.constellations.map { ($0.id, $0.name, $0.noteIDs) })
        }
    }

    // MARK: Grouping by tags

    /// Every note goes under its most used tag (vault-wide), its nested part becomes the constellation.
    private static func byTags(_ cosmos: Cosmos, ids: [String]) -> [RawGroup] {
        var uses: [String: Int] = [:]
        let tagsOf: [String: [String]] = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, Array(Set((cosmos.notes[id]?.tags ?? []).map { $0.lowercased() })).sorted())
        })
        for tags in tagsOf.values { for top in Set(tags.map(Self.topTag)) { uses[top, default: 0] += 1 } }
        var grouped: [String: [String: [String]]] = [:]
        for id in ids {
            let tags = tagsOf[id] ?? []
            guard let top = tags.map(Self.topTag).max(by: { (uses[$0] ?? 0, $1) < (uses[$1] ?? 0, $0) }) else {
                grouped[untaggedName, default: [:]][Cosmos.looseName, default: []].append(id)
                continue
            }
            let nested = tags.filter { $0.hasPrefix(top + "/") }.max { $0.count < $1.count }
            let sub = nested.map { String($0.dropFirst(top.count + 1).split(separator: "/").first ?? "") } ?? ""
            grouped["#" + top, default: [:]][sub.isEmpty ? "Без подтега" : sub, default: []].append(id)
        }
        return grouped.keys.sorted().map { g in
            let gid = "t:" + g
            return (gid, g, grouped[g]!.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { (gid + "/" + $0, $0, grouped[g]![$0]!) })
        }
    }

    private static func topTag(_ tag: String) -> String { String(tag.split(separator: "/").first ?? Substring(tag)) }

    // MARK: Grouping by link clusters

    private static func byClusters(_ cosmos: Cosmos, ids: [String]) -> [RawGroup] {
        let linked = ids.filter { cosmos.degree($0) > 0 }
        let lonely = ids.filter { cosmos.degree($0) == 0 }
        let hubs = findHubs(cosmos)
        let headOf: ([String]) -> String = { members in
            members.max { (cosmos.degree($0), $1) < (cosmos.degree($1), $0) } ?? members[0]
        }
        var result: [RawGroup] = merged(communities(of: linked, in: cosmos), in: cosmos, below: 3).map { members in
            let gid = "k:" + headOf(members)
            // A big cluster splits once more. Hubs are left out of that split: through a hub everything is one.
            var cons: [(id: String, name: String, ids: [String])] = []
            if members.count >= 16 {
                var parts = merged(communities(of: members, in: cosmos, ignoring: hubs), in: cosmos, below: max(3, members.count / 12))
                // At most a dozen constellations; the smallest share one.
                if parts.count > 12 { parts = Array(parts.prefix(11)) + [parts.dropFirst(11).flatMap { $0 }] }
                for sub in parts {
                    let top = headOf(sub.filter { !hubs.contains($0) }.isEmpty ? sub : sub.filter { !hubs.contains($0) })
                    cons.append((gid + "/" + top, cosmos.title(top), sub))
                }
            }
            if cons.count <= 1 { cons = [(gid + "/", "Все звёзды", members)] }
            return (gid, cosmos.title(headOf(members)), cons)
        }
        if !lonely.isEmpty { result.append(("k:", unlinkedName, [("k:/", Cosmos.looseName, lonely)])) }
        return result
    }

    /// Communities smaller than `below` join the community they have most links to, so the map isn't dotted with pairs.
    static func merged(_ parts: [[String]], in cosmos: Cosmos, below: Int) -> [[String]] {
        guard parts.contains(where: { !$0.isEmpty }) else { return [] }
        var big = parts.filter { $0.count >= below }
        guard !big.isEmpty else { return [parts.flatMap { $0 }] }
        var home: [String: Int] = [:]
        for (i, p) in big.enumerated() { for id in p { home[id] = i } }
        var rest = parts.filter { $0.count < below }.flatMap { $0 }
        // A few passes: a small piece may reach a big community only through another small piece.
        for _ in 0..<4 where !rest.isEmpty {
            var left: [String] = []
            for id in rest {
                var votes: [Int: Int] = [:]
                for n in cosmos.neighbors[id] ?? [] { if let h = home[n] { votes[h, default: 0] += 1 } }
                if let pick = votes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
                    big[pick].append(id); home[id] = pick
                } else { left.append(id) }
            }
            rest = left
        }
        if !rest.isEmpty { big.append(rest) }
        return big.sorted { ($0.count, $1[0]) > ($1.count, $0[0]) }
    }

    /// Label propagation: every note takes the label most of its neighbours have, until nothing changes.
    /// Deterministic (fixed order, ties go to the smaller label), so the map doesn't reshuffle between launches.
    static func communities(of members: [String], in cosmos: Cosmos, ignoring skip: Set<String> = []) -> [[String]] {
        let order = members.sorted()
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var label = Array(0..<order.count)
        let adjacency: [[Int]] = order.map { id in
            skip.contains(id) ? [] : (cosmos.neighbors[id] ?? []).filter { !skip.contains($0) }.compactMap { index[$0] }.sorted()
        }
        for _ in 0..<20 {
            var changed = false
            for i in 0..<order.count where !adjacency[i].isEmpty {
                var votes: [Int: Int] = [:]
                for j in adjacency[i] { votes[label[j], default: 0] += 1 }
                let best = votes.values.max() ?? 0
                if votes[label[i]] == best { continue }
                let pick = votes.filter { $0.value == best }.keys.min()!
                label[i] = pick
                changed = true
            }
            if !changed { break }
        }
        var groups: [Int: [String]] = [:]
        for (i, id) in order.enumerated() { groups[label[i], default: []].append(id) }
        return groups.values.sorted { ($0.count, $1[0]) > ($1.count, $0[0]) }
    }
}

// MARK: - Orbit of one note

/// One note and its surroundings, by meaning rather than by distance:
/// who links here (left), where it leads (right), its neighbours in the same constellation (top)
/// and what is worth linking (bottom). Hubs don't flood it: links to a hub fold into one chip.
nonisolated struct NoteOrbit: Sendable {

    struct Row: Hashable, Sendable {
        let id: String
        /// Linked both ways.
        let mutual: Bool
    }

    struct Section: Identifiable, Sendable {
        let id: String
        let title: String
        let groupID: String
        let rows: [Row]
        let total: Int
        var hidden: Int { total - rows.count }
    }

    /// Notes shown per section before "ещё N".
    static let sectionLimit = 5

    let center: String
    let isHub: Bool
    private(set) var incoming: [Section] = []
    private(set) var outgoing: [Section] = []
    private(set) var incomingCount = 0
    private(set) var outgoingCount = 0
    /// Hubs this note is linked to, folded away so their hundreds of links don't fill the orbit.
    private(set) var hubLinks: [String] = []
    /// How many notes those hubs lead to beyond this note.
    private(set) var hubReach = 0
    /// Neighbours in the same constellation, in title order, and the note the constellation turns around.
    private(set) var previous: String?
    private(set) var next: String?
    private(set) var head: String?
    let constellationTitle: String

    init(center: String, cosmos: Cosmos, atlas: Atlas, expanded: Set<String> = [], showHubs: Bool = false) {
        self.center = center
        isHub = atlas.hubs.contains(center)
        let neighbors = cosmos.neighbors[center] ?? []
        let ownTitles = Set((cosmos.notes[center]?.links ?? []).map { $0.lowercased() })
        let incomingSet = Set(cosmos.backlinks(to: center))
        let outgoingSet = neighbors.filter { ownTitles.contains(cosmos.title($0).lowercased()) || !incomingSet.contains($0) }

        if !showHubs, !isHub {
            hubLinks = neighbors.filter { atlas.hubs.contains($0) }
                .sorted { cosmos.degree($0) > cosmos.degree($1) }
            var reach = Set<String>()
            for h in hubLinks { reach.formUnion(cosmos.neighbors[h] ?? []) }
            reach.subtract(neighbors)
            reach.remove(center)
            hubReach = reach.count
        }
        let folded = Set(hubLinks)
        incomingCount = incomingSet.count
        outgoingCount = outgoingSet.count

        let ownGroup = atlas.groupOf[center]
        let ownConstellation = atlas.constellationOf[center]
        let hub = isHub
        func sections(_ set: Set<String>) -> [Section] {
            var buckets: [String: [String]] = [:]
            for id in set where !folded.contains(id) {
                // Same group: by constellation. Elsewhere: by group, so the orbit says which part of the vault it reaches.
                let key = atlas.groupOf[id] == ownGroup ? (atlas.constellationOf[id] ?? "") : (atlas.groupOf[id] ?? "")
                buckets[key, default: []].append(id)
            }
            let list = buckets.map { key, ids -> Section in
                // A hub's neighbours are many: the freshest come first. Otherwise the most linked ones.
                let sorted = ids.sorted { a, b in
                    let ma = cosmos.notes[a]?.modified ?? .distantPast, mb = cosmos.notes[b]?.modified ?? .distantPast
                    if hub { return ma != mb ? ma > mb : a < b }
                    let da = cosmos.degree(a), db = cosmos.degree(b)
                    return da != db ? da > db : (ma != mb ? ma > mb : a < b)
                }
                let inGroup = atlas.groupOf[ids[0]] == ownGroup
                let title = inGroup ? (atlas.constellation(key)?.name ?? "") : (atlas.group(key)?.name ?? "")
                let rows = (expanded.contains(key) ? sorted : Array(sorted.prefix(Self.sectionLimit)))
                    .map { Row(id: $0, mutual: incomingSet.contains($0) && outgoingSet.contains($0)) }
                return Section(id: key, title: title, groupID: atlas.groupOf[ids[0]] ?? "", rows: rows, total: ids.count)
            }
            return list.sorted { a, b in
                let ra = a.id == ownConstellation ? 0 : (a.groupID == ownGroup ? 1 : 2)
                let rb = b.id == ownConstellation ? 0 : (b.groupID == ownGroup ? 1 : 2)
                return ra != rb ? ra < rb : (a.total != b.total ? a.total > b.total : a.title < b.title)
            }
        }
        incoming = sections(incomingSet)
        outgoing = sections(outgoingSet)

        let cons = ownConstellation.flatMap { atlas.constellation($0) }
        constellationTitle = cons?.name ?? ""
        if let cons {
            let byTitle = cons.noteIDs.sorted { cosmos.title($0).localizedStandardCompare(cosmos.title($1)) == .orderedAscending }
            if let i = byTitle.firstIndex(of: center) {
                previous = i > 0 ? byTitle[i - 1] : nil
                next = i + 1 < byTitle.count ? byTitle[i + 1] : nil
            }
            head = cons.head == center ? nil : cons.head
        }
    }

    var hasSiblings: Bool { previous != nil || next != nil || head != nil }
}

import Foundation

/// The vault seen as space: folders become universes and constellations, notes become stars,
/// and [[wikilinks]] become the lines between them.
///
/// - universe      = top-level folder (notes in the vault root go to "Входящие")
/// - constellation = second-level folder (notes directly inside a universe go to "Свободные звёзды")
nonisolated struct Cosmos: Sendable {

    struct Universe: Identifiable, Sendable {
        let id: String
        let name: String
        let colorIndex: Int
        var constellations: [Constellation]
        var starCount: Int { constellations.reduce(0) { $0 + $1.noteIDs.count } }
    }

    struct Constellation: Identifiable, Sendable {
        let id: String
        let name: String
        let universeID: String
        /// Most connected note first, so the brightest star sits in the middle.
        var noteIDs: [String]
    }

    struct Edge: Hashable, Sendable {
        let a: String
        let b: String
        init(_ x: String, _ y: String) { if x < y { a = x; b = y } else { a = y; b = x } }
    }

    static let inboxName = "Входящие"
    static let looseName = "Свободные звёзды"

    private(set) var universes: [Universe] = []
    private(set) var notes: [String: Note] = [:]
    private(set) var edges: [Edge] = []
    private(set) var neighbors: [String: Set<String>] = [:]
    private(set) var universeOf: [String: String] = [:]
    private(set) var constellationOf: [String: String] = [:]
    private(set) var constellationName: [String: String] = [:]
    private(set) var universeIndex: [String: Int] = [:]
    /// Folder paths (any depth) that exist on disk, even if they hold no notes yet.
    private(set) var folders: [String] = []

    init(notes list: [Note] = [], folders: [String] = []) {
        self.folders = folders
        notes = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Resolve [[Title]] → note id. Titles are matched case-insensitively, first match wins.
        var byTitle: [String: String] = [:]
        for note in list.sorted(by: { $0.id < $1.id }) where byTitle[note.title.lowercased()] == nil {
            byTitle[note.title.lowercased()] = note.id
        }
        var edgeSet = Set<Edge>()
        for note in list {
            for target in note.links {
                guard let other = byTitle[target.lowercased()], other != note.id else { continue }
                edgeSet.insert(Edge(note.id, other))
            }
        }
        edges = edgeSet.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
        for edge in edges {
            neighbors[edge.a, default: []].insert(edge.b)
            neighbors[edge.b, default: []].insert(edge.a)
        }

        // Group into universes and constellations.
        var grouped: [String: [String: [String]]] = [:]
        for note in list {
            let u = note.universe.isEmpty ? Self.inboxName : note.universe
            let c = note.constellation.isEmpty ? Self.looseName : note.constellation
            grouped[u, default: [:]][c, default: []].append(note.id)
        }
        // Empty folders still become (empty) universes and constellations.
        for path in folders {
            let parts = path.split(separator: "/").map(String.init)
            guard let u = parts.first else { continue }
            if grouped[u] == nil { grouped[u] = [:] }
            if parts.count == 2, grouped[u]![parts[1]] == nil { grouped[u]![parts[1]] = [] }
        }
        let degree: (String) -> Int = { [neighbors] id in neighbors[id]?.count ?? 0 }
        let titleOf: (String) -> String = { [notes] id in notes[id]?.title ?? id }

        universes = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.enumerated().map { (index, uName) -> Universe in
            let uID = "u:" + uName
            let cons = grouped[uName]!.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { cName -> Constellation in
                let ids = grouped[uName]![cName]!.sorted {
                    let d0 = degree($0), d1 = degree($1)
                    return d0 != d1 ? d0 > d1 : titleOf($0).localizedStandardCompare(titleOf($1)) == .orderedAscending
                }
                return Constellation(id: uID + "/" + cName, name: cName, universeID: uID, noteIDs: ids)
            }
            return Universe(id: uID, name: uName, colorIndex: index, constellations: cons)
        }
        for (i, u) in universes.enumerated() {
            universeIndex[u.id] = i
            for c in u.constellations {
                constellationName[c.id] = c.name
                for id in c.noteIDs { universeOf[id] = u.id; constellationOf[id] = c.id }
            }
        }
    }

    func universe(_ id: String) -> Universe? { universeIndex[id].map { universes[$0] } }
    func title(_ id: String) -> String { notes[id]?.title ?? id }
    func degree(_ id: String) -> Int { neighbors[id]?.count ?? 0 }

    /// Notes that link to `id` (the edges are undirected, so this is every neighbour that mentions it).
    func backlinks(to id: String) -> [String] {
        guard let title = notes[id]?.title.lowercased() else { return [] }
        return (neighbors[id] ?? []).filter { other in
            notes[other]?.links.contains { $0.lowercased() == title } ?? false
        }.sorted()
    }

    /// Replaces one note (after editing) and rebuilds the graph.
    func updating(_ note: Note) -> Cosmos {
        var list = Array(notes.values)
        if let i = list.firstIndex(where: { $0.id == note.id }) { list[i] = note } else { list.append(note) }
        return Cosmos(notes: list, folders: folders)
    }
}

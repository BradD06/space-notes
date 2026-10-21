import SwiftUI
import Observation

/// Where the map is looking and what is picked on it. Three levels, each with its own job:
/// the atlas (all groups), one universe (its constellations), the orbit of one note.
@MainActor
@Observable
final class MapModel {

    enum Focus: Equatable {
        case multiverse
        case universe(String)
        case star(String)
    }

    /// A hint lens over the map: it lights up the stars that need attention and dims the rest.
    enum Lens: String, CaseIterable, Identifiable {
        case suggestions, orphans, forgotten
        var id: String { rawValue }
        var title: String {
            switch self {
            case .suggestions: "Связать"
            case .orphans: "Сироты"
            case .forgotten: "Забытые"
            }
        }
        var icon: String {
            switch self {
            case .suggestions: "link.badge.plus"
            case .orphans: "circle.dotted"
            case .forgotten: "moon.zzz"
            }
        }
    }

    private(set) var focus: Focus = .multiverse
    /// The universe and the star looked at last: the level switch can go back to them.
    private(set) var lastUniverse: String?
    private(set) var lastStar: String?
    private(set) var trail: [String] = []
    /// Set by other screens ("show on map"); the map goes there when it appears.
    var pendingStar: String?
    var searchText = ""
    var lens: Lens?
    var hoveredStar: String?
    var hoveredGroup: String?

    /// Picked by the user with "Папки / Теги / Кластеры"; nil lets the map choose for the vault.
    var grouping: Atlas.Grouping? = MapModel.loadGrouping() {
        didSet { UserDefaults.standard.set(grouping?.rawValue, forKey: Self.groupingKey) }
    }
    /// "Ещё N папок" opened up.
    var expandOthers = false
    /// The constellation whose notes are listed beside a universe.
    var selectedConstellation: String?
    /// Orbit sections opened past their first five.
    var expandedSections: Set<String> = []
    /// Links to hubs shown one by one instead of folded into a chip.
    var showHubLinks = false
    /// On a phone the side panel opens on request.
    var showPanel = false
    /// Suggestions put off with "Не сейчас" (for this session).
    var dismissed: Set<Cosmos.Edge> = []

    var focusedStar: String? { if case .star(let id) = focus { id } else { nil } }
    var focusedUniverse: String? { if case .universe(let id) = focus { id } else { nil } }

    // MARK: Atlas (built once per version of the vault and grouping)

    @ObservationIgnored private var cached = Atlas()
    @ObservationIgnored private var cachedKey = ""

    func atlas(_ vault: VaultStore) -> Atlas {
        let key = "\(vault.generation)|\(grouping?.rawValue ?? "auto")|\(expandOthers)"
        if key != cachedKey {
            cached = Atlas(vault.cosmos, grouping: grouping, expandOthers: expandOthers)
            cachedKey = key
        }
        return cached
    }

    // MARK: Navigation

    /// Call whenever the vault may have changed. Drops a focus whose note or group is gone.
    func sync(with cosmos: Cosmos, atlas: Atlas) {
        trail.removeAll { cosmos.notes[$0] == nil }
        if let s = lastStar, cosmos.notes[s] == nil { lastStar = nil }
        if let u = lastUniverse, atlas.group(u) == nil { lastUniverse = nil }
        switch focus {
        case .star(let id) where cosmos.notes[id] == nil: focus = .multiverse
        case .universe(let id) where atlas.group(id) == nil && !id.hasPrefix("u:"): focus = .multiverse
        default: break
        }
    }

    func go(to newFocus: Focus) {
        switch newFocus {
        case .star(let id):
            lastStar = id
            trail.removeAll { $0 == id }
            trail.append(id)
            if trail.count > 6 { trail.removeFirst() }
            expandedSections = []
            showHubLinks = false
        case .universe(let id):
            // A folder picked in the sidebar is a universe of the folder grouping.
            if id.hasPrefix("u:"), let g = grouping, g != .folders { grouping = .folders }
            if lastUniverse != id { selectedConstellation = nil }
            lastUniverse = id
        case .multiverse:
            break
        }
        hoveredStar = nil
        hoveredGroup = nil
        withAnimation(.smooth(duration: 0.35)) { focus = newFocus }
    }

    func fly(to id: String, cosmos: Cosmos) { go(to: .star(id)) }

    /// Esc: star → its universe → all universes.
    func up(atlas: Atlas) {
        switch focus {
        case .star(let id): go(to: atlas.groupOf[id].map(Focus.universe) ?? .multiverse)
        case .universe: go(to: .multiverse)
        case .multiverse: break
        }
    }

    /// The universe the map is in or was last in, as a group of the current grouping.
    func currentUniverse(_ atlas: Atlas) -> String? {
        switch focus {
        case .universe(let id): return id
        case .star(let id): return atlas.groupOf[id]
        case .multiverse: return lastUniverse ?? lastStar.flatMap { atlas.groupOf[$0] }
        }
    }

    /// Whether a lens lights this star up; nil when no lens is on.
    func lensMatches(_ id: String, _ insights: Insights) -> Bool? {
        switch lens {
        case nil: nil
        case .suggestions: insights.suggestedSet.contains(id)
        case .orphans: insights.orphanSet.contains(id)
        case .forgotten: insights.forgottenSet.contains(id)
        }
    }

    private static let groupingKey = "space.map.grouping"

    private static func loadGrouping() -> Atlas.Grouping? {
        UserDefaults.standard.string(forKey: groupingKey).flatMap(Atlas.Grouping.init(rawValue:))
    }
}

import CoreGraphics
import Foundation

/// Where everything lives on the map, in world units. Pure geometry, recomputed when the cosmos changes.
///
/// Stars inside a constellation sit on a sunflower spiral (the hub in the middle), constellations sit
/// on a ring inside their universe, and universes sit on a larger sunflower spiral. This scales from
/// a handful of notes to thousands without overlaps.
struct WorldLayout: Sendable {
    var star: [String: CGPoint] = [:]
    var constellationCenter: [String: CGPoint] = [:]
    var constellationRadius: [String: CGFloat] = [:]
    var universeCenter: [String: CGPoint] = [:]
    var universeRadius: [String: CGFloat] = [:]
    var bounds: CGRect = CGRect(x: -100, y: -100, width: 200, height: 200)

    static let golden = CGFloat.pi * (3 - sqrt(5))
    static let starSpacing: CGFloat = 11

    init() {}

    init(cosmos: Cosmos) {
        var local: [String: CGPoint] = [:]
        var consR: [String: CGFloat] = [:]
        for u in cosmos.universes {
            for c in u.constellations {
                for (i, id) in c.noteIDs.enumerated() {
                    let r = i == 0 ? 0 : Self.starSpacing * sqrt(CGFloat(i)) + 8
                    let a = CGFloat(i) * Self.golden
                    local[id] = CGPoint(x: r * cos(a), y: r * sin(a))
                }
                consR[c.id] = Self.starSpacing * sqrt(CGFloat(max(c.noteIDs.count - 1, 0))) + 22
            }
        }

        var consLocal: [String: CGPoint] = [:]
        var uR: [String: CGFloat] = [:]
        for u in cosmos.universes {
            let cs = u.constellations
            guard !cs.isEmpty else { uR[u.id] = 40; continue }
            if cs.count == 1 {
                consLocal[cs[0].id] = .zero
                uR[u.id] = (consR[cs[0].id] ?? 30) + 12
                continue
            }
            let radii = cs.map { consR[$0.id] ?? 30 }
            let maxR = radii.max() ?? 30
            // Neighbouring constellations must not overlap: the chord between two neighbours
            // has to fit two of the biggest circles plus room for a name between them.
            let noOverlap = (2 * maxR + 34) / (2 * sin(.pi / CGFloat(cs.count)))
            let ring = max(maxR * 1.2, radii.map { $0 * 2 + 16 }.reduce(0, +) / (2 * .pi), noOverlap)
            for (i, c) in cs.enumerated() {
                let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(cs.count)
                consLocal[c.id] = CGPoint(x: ring * cos(a), y: ring * sin(a))
            }
            uR[u.id] = ring + maxR + 12
        }

        // A universe's size follows how many constellations it holds (and always fits its contents).
        for u in cosmos.universes {
            uR[u.id] = max(uR[u.id] ?? 40, 40 + 24 * CGFloat(u.constellations.count))
        }

        // Universes are packed tightly: the biggest goes in the middle, every next one walks out
        // along a spiral and stops at the first spot where it doesn't touch any universe already placed.
        // Small universes therefore settle close to the big ones instead of far away.
        let gap: CGFloat = 10
        var placedU: [(center: CGPoint, radius: CGFloat)] = []
        var packed: [String: CGPoint] = [:]
        let bySize = cosmos.universes.sorted { (uR[$0.id] ?? 0, $1.name) > (uR[$1.id] ?? 0, $0.name) }
        for u in bySize {
            let radius = uR[u.id] ?? 60
            var spot = CGPoint.zero
            if !placedU.isEmpty {
                var t: CGFloat = 0
                while true {
                    let r = 3 * t
                    let candidate = CGPoint(x: r * cos(t - .pi / 2), y: r * sin(t - .pi / 2))
                    let free = placedU.allSatisfy { hypot($0.center.x - candidate.x, $0.center.y - candidate.y) >= $0.radius + radius + gap }
                    if free { spot = candidate; break }
                    t += max(0.008, 3 / max(r, 1))
                }
            }
            placedU.append((spot, radius))
            packed[u.id] = spot
        }

        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for u in cosmos.universes {
            let center = packed[u.id] ?? .zero
            let radius = uR[u.id] ?? 60
            universeCenter[u.id] = center
            universeRadius[u.id] = radius
            minX = min(minX, center.x - radius); maxX = max(maxX, center.x + radius)
            minY = min(minY, center.y - radius); maxY = max(maxY, center.y + radius)
            for c in u.constellations {
                let cc = consLocal[c.id] ?? .zero
                let cw = CGPoint(x: center.x + cc.x, y: center.y + cc.y)
                constellationCenter[c.id] = cw
                constellationRadius[c.id] = consR[c.id] ?? 30
                for id in c.noteIDs {
                    let l = local[id] ?? .zero
                    star[id] = CGPoint(x: cw.x + l.x, y: cw.y + l.y)
                }
            }
        }
        if minX.isFinite { bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
    }
}

extension WorldLayout {
    /// The same layout with whole universes moved by the user (stars and constellations move along).
    func shifted(by offsets: [String: CGVector], cosmos: Cosmos) -> WorldLayout {
        guard !offsets.isEmpty else { return self }
        var out = self
        let move: (CGPoint, CGVector) -> CGPoint = { CGPoint(x: $0.x + $1.dx, y: $0.y + $1.dy) }
        for u in cosmos.universes {
            guard let o = offsets[u.id], o != .zero else { continue }
            if let c = universeCenter[u.id] { out.universeCenter[u.id] = move(c, o) }
            for c in u.constellations {
                if let cc = constellationCenter[c.id] { out.constellationCenter[c.id] = move(cc, o) }
                for id in c.noteIDs { if let p = star[id] { out.star[id] = move(p, o) } }
            }
        }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for (id, c) in out.universeCenter {
            let r = out.universeRadius[id] ?? 60
            minX = min(minX, c.x - r); maxX = max(maxX, c.x + r)
            minY = min(minY, c.y - r); maxY = max(maxY, c.y + r)
        }
        if minX.isFinite { out.bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
        return out
    }
}

/// The focus view: the chosen star in the middle, everything it is connected to on orbits around it.
///
/// 1 — direct links inside its constellation
/// 2 — the rest of its constellation
/// 3 — direct links into other constellations of the same universe (grouped by constellation)
/// 4 — direct links into other universes (grouped by constellation, or by universe when there are many)
/// Empty orbits are skipped, so the number of orbits says how widely a note is connected.
struct OrbitLayout: Sendable {
    struct Ring: Sendable { let kind: Int; let radius: CGFloat; let title: String; let count: Int }
    struct Group: Sendable {
        let title: String
        let universeID: String
        let kind: Int
        let midAngle: CGFloat
        let radius: CGFloat
        let noteIDs: [String]
    }

    static let radii: [CGFloat] = [17, 32, 50, 72]
    static let titles = [1: "связи в созвездии", 2: "остальное созвездие", 3: "эта вселенная", 4: "другие вселенные"]

    let center: String
    let origin: CGPoint
    var position: [String: CGPoint] = [:]
    var ringOf: [String: Int] = [:]
    var rings: [Ring] = []
    var groups: [Group] = []

    init(center: String, cosmos: Cosmos, layout: WorldLayout) {
        self.center = center
        origin = layout.star[center] ?? .zero
        guard let myCons = cosmos.constellationOf[center], let myU = cosmos.universeOf[center] else { return }

        let direct = (cosmos.neighbors[center] ?? []).sorted { cosmos.title($0) < cosmos.title($1) }
        let own1 = direct.filter { cosmos.constellationOf[$0] == myCons }
        let consNotes = cosmos.universe(myU)?.constellations.first { $0.id == myCons }?.noteIDs ?? []
        let own2 = consNotes.filter { $0 != center && !own1.contains($0) }

        func grouped(_ ids: [String], byUniverse: Bool) -> [(key: String, title: String, universe: String, ids: [String])] {
            var order: [String] = []
            var map: [String: (title: String, universe: String, ids: [String])] = [:]
            for id in ids {
                let u = cosmos.universeOf[id] ?? ""
                let key = byUniverse ? u : (cosmos.constellationOf[id] ?? "")
                let uName = cosmos.universe(u)?.name ?? ""
                let cName = cosmos.constellationName[cosmos.constellationOf[id] ?? ""] ?? ""
                let title = byUniverse ? uName : (u == myU ? cName : "\(uName) › \(cName)")
                if map[key] == nil { order.append(key); map[key] = (title, u, []) }
                map[key]!.ids.append(id)
            }
            return order.map { (key: $0, title: map[$0]!.title, universe: map[$0]!.universe, ids: map[$0]!.ids) }
                .sorted { ($0.universe, $0.title) < ($1.universe, $1.title) }
        }
        let inU = grouped(direct.filter { cosmos.universeOf[$0] == myU && cosmos.constellationOf[$0] != myCons }, byUniverse: false)
        let outIDs = direct.filter { cosmos.universeOf[$0] != myU }
        var outU = grouped(outIDs, byUniverse: false)
        if outU.count > 12 { outU = grouped(outIDs, byUniverse: true) }

        var slot = 0
        func at(_ angle: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: origin.x + r * cos(angle), y: origin.y + r * sin(angle)) }

        for (kind, ids) in [(1, own1), (2, own2)] where !ids.isEmpty {
            let r = Self.radii[slot]; slot += 1
            rings.append(Ring(kind: kind, radius: r, title: Self.titles[kind]!, count: ids.count))
            for (j, id) in ids.enumerated() {
                position[id] = at(-.pi / 2 + (CGFloat(j) + 0.5) * 2 * .pi / CGFloat(ids.count), r)
                ringOf[id] = kind
            }
        }
        for (kind, list) in [(3, inU), (4, outU)] where !list.isEmpty {
            let r = Self.radii[slot]; slot += 1
            let slots = list.reduce(0) { $0 + $1.ids.count }
            rings.append(Ring(kind: kind, radius: r, title: Self.titles[kind]!, count: slots))
            let gap: CGFloat = 1.4
            let step = 2 * .pi / (CGFloat(slots) + gap * CGFloat(list.count))
            var t = -CGFloat.pi / 2 + gap * step / 2
            for (gi, g) in list.enumerated() {
                if gi > 0 { t += gap * step }
                let start = t
                for id in g.ids {
                    position[id] = at(t, r)
                    ringOf[id] = kind
                    t += step
                }
                groups.append(Group(title: g.title, universeID: g.universe, kind: kind,
                                    midAngle: start + CGFloat(g.ids.count - 1) * step / 2, radius: r, noteIDs: g.ids))
            }
        }
        position[center] = origin
    }

    /// Radius of the outermost orbit, used to frame the camera.
    var outerRadius: CGFloat { rings.last?.radius ?? 20 }
}

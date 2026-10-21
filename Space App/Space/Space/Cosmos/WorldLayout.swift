import CoreGraphics
import Foundation

/// Where everything lives on the map, in world units. Pure geometry, recomputed when the cosmos changes.
///
/// Inside a universe the stars are laid out by a small physics simulation (links are springs,
/// stars repel each other, constellations keep together), and universes are packed tightly around
/// each other, pulled towards the ones they share links with.
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
        // 1. A first guess: constellations on a ring, stars on a sunflower inside each of them.
        var seed: [String: CGPoint] = [:]       // star position relative to its universe centre
        var anchor: [String: CGPoint] = [:]     // constellation anchor relative to its universe centre
        for u in cosmos.universes {
            let cs = u.constellations
            let ring: CGFloat = cs.count <= 1 ? 0 : max(50, 26 * CGFloat(cs.count))
            for (k, c) in cs.enumerated() {
                let a = -CGFloat.pi / 2 + CGFloat(k) * 2 * .pi / CGFloat(max(cs.count, 1))
                let ac = CGPoint(x: ring * cos(a), y: ring * sin(a))
                anchor[c.id] = ac
                for (i, id) in c.noteIDs.enumerated() {
                    let r = i == 0 ? 0 : Self.starSpacing * sqrt(CGFloat(i))
                    let t = CGFloat(i) * Self.golden
                    seed[id] = CGPoint(x: ac.x + r * cos(t), y: ac.y + r * sin(t))
                }
            }
        }

        // 2. Let physics settle every universe, like Obsidian's graph: links are springs, stars push
        //    each other away, and each constellation keeps a soft pull towards its own spot,
        //    so related notes end up close together and the shapes look natural instead of geometric.
        var uniLocal: [String: CGPoint] = [:]
        var consLocal: [String: CGPoint] = [:]
        var consR: [String: CGFloat] = [:]
        var uR: [String: CGFloat] = [:]
        for u in cosmos.universes {
            let ids = u.constellations.flatMap(\.noteIDs)
            guard !ids.isEmpty else { uR[u.id] = 36; continue }
            let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            var pos = ids.map { seed[$0] ?? .zero }
            let home = ids.map { id -> CGPoint in
                anchor[cosmos.constellationOf[id] ?? ""] ?? .zero
            }
            var links: [(Int, Int)] = []
            for e in cosmos.edges { if let a = index[e.a], let b = index[e.b] { links.append((a, b)) } }
            Self.settle(&pos, links: links, home: home)

            // Centre the universe on its stars.
            let cx = pos.map(\.x).reduce(0, +) / CGFloat(pos.count), cy = pos.map(\.y).reduce(0, +) / CGFloat(pos.count)
            var far: CGFloat = 0
            for (k, id) in ids.enumerated() {
                let p = CGPoint(x: pos[k].x - cx, y: pos[k].y - cy)
                uniLocal[id] = p
                far = max(far, hypot(p.x, p.y))
            }
            for c in u.constellations where !c.noteIDs.isEmpty {
                let ps = c.noteIDs.compactMap { uniLocal[$0] }
                let mx = ps.map(\.x).reduce(0, +) / CGFloat(ps.count), my = ps.map(\.y).reduce(0, +) / CGFloat(ps.count)
                consLocal[c.id] = CGPoint(x: mx, y: my)
                consR[c.id] = (ps.map { hypot($0.x - mx, $0.y - my) }.max() ?? 0) + 14
            }
            uR[u.id] = far + 22
        }

        // A universe is only as big as its contents need (plus a little room for its name).
        for u in cosmos.universes {
            uR[u.id] = max(uR[u.id] ?? 36, 30 + 4 * CGFloat(u.constellations.count))
        }

        // How strongly two universes are linked: the number of notes linking across them.
        var bond: [String: [String: CGFloat]] = [:]
        for e in cosmos.edges {
            guard let a = cosmos.universeOf[e.a], let b = cosmos.universeOf[e.b], a != b else { continue }
            bond[a, default: [:]][b, default: 0] += 1
            bond[b, default: [:]][a, default: 0] += 1
        }

        // Packing: the biggest universe goes in the middle. Every next one is put right against the
        // universes already placed — at the free spot closest to the middle of the group, and pulled
        // towards the universes it shares the most links with. The result is a tight cluster.
        let gap: CGFloat = 14
        var placedU: [(id: String, center: CGPoint, radius: CGFloat)] = []
        var packed: [String: CGPoint] = [:]
        let bySize = cosmos.universes.sorted { (uR[$0.id] ?? 0, $1.name) > (uR[$1.id] ?? 0, $0.name) }
        for u in bySize {
            let radius = uR[u.id] ?? 60
            var spot = CGPoint.zero
            if !placedU.isEmpty {
                var candidates: [CGPoint] = []
                for a in placedU {
                    let d = a.radius + radius + gap
                    for k in 0..<36 {
                        let t = CGFloat(k) * 2 * .pi / 36
                        candidates.append(CGPoint(x: a.center.x + d * cos(t), y: a.center.y + d * sin(t)))
                    }
                }
                // Spots touching two placed universes at once: the tightest possible fits.
                for x in 0..<placedU.count {
                    for y in (x + 1)..<placedU.count {
                        let a = placedU[x], b = placedU[y]
                        let ra = a.radius + radius + gap, rb = b.radius + radius + gap
                        let dx = b.center.x - a.center.x, dy = b.center.y - a.center.y
                        let dist = hypot(dx, dy)
                        guard dist > 0.001, dist < ra + rb, dist > abs(ra - rb) else { continue }
                        let along = (ra * ra - rb * rb + dist * dist) / (2 * dist)
                        let h = sqrt(max(0, ra * ra - along * along))
                        let mx = a.center.x + dx * along / dist, my = a.center.y + dy * along / dist
                        candidates.append(CGPoint(x: mx - dy * h / dist, y: my + dx * h / dist))
                        candidates.append(CGPoint(x: mx + dy * h / dist, y: my - dx * h / dist))
                    }
                }
                // Middle of the group, weighted by area.
                var cx: CGFloat = 0, cy: CGFloat = 0, wsum: CGFloat = 0
                for a in placedU { let w = a.radius * a.radius; cx += a.center.x * w; cy += a.center.y * w; wsum += w }
                let mid = CGPoint(x: cx / wsum, y: cy / wsum)
                let links = bond[u.id] ?? [:]
                let linkTotal = links.values.reduce(0, +)

                var best: (CGPoint, CGFloat)?
                for c in candidates {
                    let free = placedU.allSatisfy { hypot($0.center.x - c.x, $0.center.y - c.y) >= $0.radius + radius + gap - 0.5 }
                    guard free else { continue }
                    var cost = hypot(c.x - mid.x, c.y - mid.y)
                    if linkTotal > 0 {
                        var pull: CGFloat = 0
                        for a in placedU { if let w = links[a.id] { pull += w * hypot(c.x - a.center.x, c.y - a.center.y) } }
                        cost += 0.8 * pull / linkTotal
                    }
                    if best == nil || cost < best!.1 { best = (c, cost) }
                }
                spot = best?.0 ?? CGPoint(x: (placedU.map { $0.center.x + $0.radius }.max() ?? 0) + radius + gap, y: 0)
            }
            placedU.append((u.id, spot, radius))
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
                constellationCenter[c.id] = CGPoint(x: center.x + cc.x, y: center.y + cc.y)
                constellationRadius[c.id] = consR[c.id] ?? 30
                for id in c.noteIDs {
                    let l = uniLocal[id] ?? .zero
                    star[id] = CGPoint(x: center.x + l.x, y: center.y + l.y)
                }
            }
        }
        if minX.isFinite { bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
    }

    /// A small force-directed simulation (the same idea as d3-force in Obsidian), run to rest.
    /// Deterministic: the same vault always gives the same picture.
    static func settle(_ pos: inout [CGPoint], links: [(Int, Int)], home: [CGPoint]) {
        let n = pos.count
        guard n > 1 else { return }
        var vel = [CGVector](repeating: .zero, count: n)
        var degree = [CGFloat](repeating: 0, count: n)
        for (a, b) in links { degree[a] += 1; degree[b] += 1 }
        let rest: CGFloat = 15, charge: CGFloat = 110, linkK: CGFloat = 0.06, homeK: CGFloat = 0.03
        // Fewer steps for huge universes so opening a big vault stays quick.
        let steps = max(60, min(320, Int(9_000_000 / CGFloat(n * n))))
        var heat: CGFloat = 1
        for _ in 0..<steps {
            var f = [CGVector](repeating: .zero, count: n)
            // Everyone pushes everyone away (stronger up close).
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y
                    var d2 = dx * dx + dy * dy
                    if d2 < 0.01 { dx = CGFloat(i - j) * 0.1 + 0.05; dy = 0.07; d2 = dx * dx + dy * dy }
                    guard d2 < 160 * 160 else { continue }
                    let push = charge / max(d2, 16)
                    let d = sqrt(d2)
                    f[i].dx -= dx / d * push; f[i].dy -= dy / d * push
                    f[j].dx += dx / d * push; f[j].dy += dy / d * push
                }
            }
            // Links pull their ends to a comfortable distance; a hub's links are a little softer.
            for (a, b) in links {
                let dx = pos[b].x - pos[a].x, dy = pos[b].y - pos[a].y
                let d = max(0.01, hypot(dx, dy))
                let k = linkK * (d - rest) / d
                let wa = degree[b] / (degree[a] + degree[b]), wb = 1 - wa
                f[a].dx += dx * k * wa * 2; f[a].dy += dy * k * wa * 2
                f[b].dx -= dx * k * wb * 2; f[b].dy -= dy * k * wb * 2
            }
            for i in 0..<n {
                f[i].dx += (home[i].x - pos[i].x) * homeK
                f[i].dy += (home[i].y - pos[i].y) * homeK
                vel[i].dx = (vel[i].dx + f[i].dx * heat) * 0.6
                vel[i].dy = (vel[i].dy + f[i].dy * heat) * 0.6
                pos[i].x += vel[i].dx; pos[i].y += vel[i].dy
            }
            heat = max(0.02, heat * 0.985)
        }
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

/// The focus view: the chosen star in the middle, everything reachable through links on orbits around it.
///
/// One orbit per universe:
/// 1 — stars of the centre's own universe
/// 2 — stars of the other universe it is most connected to
/// 3, 4, … — the next universes, closest first
/// Inside an orbit the stars follow the cascade of links: each one sits next to the star it was reached
/// through (its `parent`), and stars many link-steps away fade out (`depth`).
struct OrbitLayout: Sendable {
    struct Ring: Sendable { let kind: Int; let radius: CGFloat; let title: String; let count: Int; let universeID: String }
    struct Group: Sendable {
        let title: String
        let universeID: String
        let kind: Int
        let midAngle: CGFloat
        let radius: CGFloat
        let noteIDs: [String]
    }

    /// How many link steps are followed at all.
    static let maxDepth = 8
    /// Steps beyond this one only fade out.
    static let visibleDepth = 4
    /// How visible a star is by its number of link steps: 1 up to 4, then dimmer and dimmer, nearly gone at 8.
    static func fade(_ depth: Int) -> Double {
        depth <= visibleDepth ? 1 : [0.5, 0.26, 0.11, 0.035][min(depth, maxDepth) - visibleDepth - 1]
    }

    /// All orbits get titles, the side panel and the camera frame.
    var visibleRings: [Ring] { rings }

    /// Smallest distance between neighbouring stars on one orbit, in world units.
    static let minArc: CGFloat = 6

    let center: String
    let origin: CGPoint
    var position: [String: CGPoint] = [:]
    var ringOf: [String: Int] = [:]
    /// Number of link steps from the centre.
    var depth: [String: Int] = [:]
    /// The star this one was reached through.
    var parent: [String: String] = [:]
    var rings: [Ring] = []
    /// Kept for the renderer; this layout has no constellation groups.
    var groups: [Group] = []

    init(center: String, cosmos: Cosmos, layout: WorldLayout) {
        self.center = center
        origin = layout.star[center] ?? .zero
        position[center] = origin
        guard cosmos.notes[center] != nil, let home = cosmos.universeOf[center] else { return }

        // 1. Breadth-first walk over links: how many steps away every reachable star is, and through whom.
        var order: [String] = []
        var seen: Set<String> = [center]
        var frontier = [center]
        var d = 0
        while !frontier.isEmpty, d < Self.maxDepth {
            d += 1
            var next: [String] = []
            for p in frontier {
                let kids = (cosmos.neighbors[p] ?? []).filter { !seen.contains($0) }
                    .sorted { cosmos.title($0).localizedStandardCompare(cosmos.title($1)) == .orderedAscending }
                for k in kids { seen.insert(k); parent[k] = p; depth[k] = d; next.append(k); order.append(k) }
            }
            frontier = next
        }
        guard !order.isEmpty else { return }

        // 2. Group by universe. Own universe first; then the others, closest first:
        //    fewest steps to reach, then most stars reached, then name.
        var byUniverse: [String: [String]] = [:]
        for id in order { byUniverse[cosmos.universeOf[id] ?? "", default: []].append(id) }
        let others = byUniverse.keys.filter { $0 != home }.sorted { a, b in
            let da = byUniverse[a]!.map { depth[$0] ?? 9 }.min() ?? 9, db = byUniverse[b]!.map { depth[$0] ?? 9 }.min() ?? 9
            if da != db { return da < db }
            if byUniverse[a]!.count != byUniverse[b]!.count { return byUniverse[a]!.count > byUniverse[b]!.count }
            return (cosmos.universe(a)?.name ?? a) < (cosmos.universe(b)?.name ?? b)
        }
        let universes = (byUniverse[home] == nil ? [] : [home]) + others

        // 3. One orbit per universe. Inside it, a star aims for the angle of the star it was reached through
        //    (if that one is already placed), so the cascade of links stays readable across orbits.
        var angleOf: [String: CGFloat] = [center: -.pi / 2]
        var radius: CGFloat = 0
        for (i, u) in universes.enumerated() {
            let kind = i + 1
            let ids = byUniverse[u]!.sorted { (depth[$0] ?? 9, $0) < (depth[$1] ?? 9, $1) }
            let n = CGFloat(ids.count)
            radius = max(radius + (i == 0 ? 20 : 19), n * Self.minArc / (2 * .pi))
            rings.append(Ring(kind: kind, radius: radius, title: cosmos.universe(u)?.name ?? "", count: ids.count, universeID: u))

            // Target angles: near the parent, siblings fanned out around it; stars whose parent is not placed yet
            // get a free spot, filled in afterwards.
            var target: [String: CGFloat] = [:]
            var siblings: [String: Int] = [:]
            var pending: [String] = []
            for id in ids {
                if let p = parent[id], let pa = angleOf[p] ?? target[p] {
                    let k = siblings[p, default: 0]; siblings[p] = k + 1
                    let spread: CGFloat = 0.16
                    let off = CGFloat((k + 1) / 2) * spread * (k % 2 == 0 ? 1 : -1)
                    target[id] = pa + off
                } else {
                    pending.append(id)
                }
            }
            for (k, id) in pending.enumerated() { target[id] = -.pi / 2 + CGFloat(k) * 2 * .pi / CGFloat(max(pending.count, 1)) + 0.3 }

            // Keep that order, blended with even spacing so nobody collides.
            let ordered = ids.sorted { target[$0]! < target[$1]! }
            let step = 2 * .pi / n
            var sx: CGFloat = 0, sy: CGFloat = 0
            for (j, id) in ordered.enumerated() {
                let dd = target[id]! - CGFloat(j) * step
                sx += cos(dd); sy += sin(dd)
            }
            let base = atan2(sy, sx)
            for (j, id) in ordered.enumerated() {
                var even = base + CGFloat(j) * step
                let t = target[id]!
                while even - t > .pi { even -= 2 * .pi }
                while t - even > .pi { even += 2 * .pi }
                var angle = n <= 2 ? t : 0.45 * t + 0.55 * even
                // A little chaos: every star sits a bit off the perfect circle and off its even slot.
                let seed = stableSeed(id)
                let r1 = CGFloat(seed % 1000) / 1000 - 0.5, r2 = CGFloat((seed / 1000) % 1000) / 1000 - 0.5
                if n > 2 { angle += r2 * step * 0.6 }
                let r = radius + r1 * 2 * (i == 0 ? 5 : 8)
                position[id] = CGPoint(x: origin.x + r * cos(angle), y: origin.y + r * sin(angle))
                angleOf[id] = angle
                ringOf[id] = kind
            }
        }
    }

    /// The chain from a star back to the centre: [star, its parent, …].
    func path(to id: String) -> [String] {
        var out = [id]
        var cur = id
        while let p = parent[cur], p != center, out.count < 8 { out.append(p); cur = p }
        return out
    }

    /// Radius of the outermost orbit, used to frame the camera.
    var outerRadius: CGFloat { visibleRings.last?.radius ?? 20 }
}

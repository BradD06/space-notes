import SwiftUI
import Observation

struct Camera {
    var center: CGPoint
    var scale: CGFloat
}

/// Everything the map needs to know between frames: where we are looking, what is hovered,
/// the trail of visited stars, and the timing of fly-overs and orbit arrangements.
/// Positions are pure functions of time, so the Canvas can redraw every frame without state churn.
@MainActor
@Observable
final class MapModel {

    enum Focus: Equatable {
        case multiverse
        case universe(String)
        case star(String)
    }

    /// World geometry for the current cosmos. Rebuilt only when the vault changes.
    private(set) var layout = WorldLayout()
    @ObservationIgnored private var baseLayout = WorldLayout()
    @ObservationIgnored private var cosmos = Cosmos()
    @ObservationIgnored private var layoutGeneration = -1
    /// Area the overview frames. Updated when the vault loads, not while a universe is dragged,
    /// so the camera doesn't jump around under your finger.
    @ObservationIgnored private var frameBounds = CGRect(x: -100, y: -100, width: 200, height: 200)
    /// Where the user has moved universes to, relative to their automatic place. Remembered between launches.
    private(set) var universeOffsets: [String: CGVector] = MapModel.loadOffsets()
    /// Set by other screens ("show on map"); the map flies there when it appears.
    var pendingStar: String?

    private(set) var focus: Focus = .multiverse
    private(set) var orbit: OrbitLayout?
    private(set) var trail: [String] = []
    private(set) var hoveredStar: String?
    private(set) var hoveredUniverse: String?
    var searchText = ""
    /// The orbit list on the right of the map can be folded away.
    var showFocusPanel = true

    // Gestures
    var pan: CGSize = .zero
    var zoom: CGFloat = 1
    @ObservationIgnored var panAtGestureStart: CGSize = .zero
    @ObservationIgnored var zoomAtGestureStart: CGFloat = 1

    // Timing (not observed: the TimelineView redraws every frame anyway)
    @ObservationIgnored private var from = Camera(center: .zero, scale: 0.3)
    @ObservationIgnored private var flyStart: Date = .distantPast
    @ObservationIgnored private var orbitStart: Date = .distantPast
    @ObservationIgnored private var oldOrbit: OrbitLayout?
    @ObservationIgnored private var oldOrbitStart: Date = .distantPast
    @ObservationIgnored private var timeShift: [String: Double] = [:]
    @ObservationIgnored private var hoverStart: Date = .now
    @ObservationIgnored private var seeds: [String: UInt64] = [:]
    @ObservationIgnored var lastSize = CGSize(width: 1000, height: 700)
    /// Camera scale of the last drawn frame; drift is measured in screen points through it.
    @ObservationIgnored var lastScale: CGFloat = 1

    static let flyDuration = 0.65
    static let arrangeDuration = 0.5
    static let collapseDuration = 0.28

    var focusedStar: String? { if case .star(let id) = focus { id } else { nil } }

    var focusedUniverse: String? {
        if case .universe(let id) = focus { id } else { nil }
    }

    // MARK: Navigation

    /// Call whenever the vault may have changed. Keeps the focus if its star still exists.
    func sync(with cosmos: Cosmos, generation: Int) {
        guard generation != layoutGeneration else { return }
        layoutGeneration = generation
        self.cosmos = cosmos
        baseLayout = WorldLayout(cosmos: cosmos)
        layout = baseLayout.shifted(by: universeOffsets, cosmos: cosmos)
        frameBounds = layout.bounds
        bodies = layout.universeCenter.mapValues { Body(pos: $0) }
        switch focus {
        case .star(let id):
            if cosmos.notes[id] != nil { orbit = OrbitLayout(center: id, cosmos: cosmos, layout: layout) }
            else { focus = .multiverse; orbit = nil }
        case .universe(let id):
            if cosmos.universe(id) == nil { focus = .multiverse }
        case .multiverse:
            break
        }
        trail.removeAll { cosmos.notes[$0] == nil }
        from = targetCamera(for: focus, layout: layout, size: lastSize)
        flyStart = .distantPast
        orbitStart = .distantPast
        oldOrbit = nil
    }

    // MARK: Universes: floating, dragging, pushing each other

    /// A universe as a physical body. `pos` is its centre without the gentle drift.
    private struct Body { var pos: CGPoint; var vel: CGVector = .zero }
    @ObservationIgnored private var bodies: [String: Body] = [:]
    @ObservationIgnored private var lastStep: Date?
    @ObservationIgnored private var dragged: String?
    @ObservationIgnored private var dragTarget: CGPoint = .zero
    @ObservationIgnored private var previousFocus: Focus = .multiverse

    func offset(of universe: String) -> CGVector { universeOffsets[universe] ?? .zero }

    /// Called while a universe is dragged. Only the dragged body is moved; the others react in `step`.
    func move(universe: String, to offset: CGVector) {
        guard let base = baseLayout.universeCenter[universe] else { return }
        dragged = universe
        dragTarget = CGPoint(x: base.x + offset.dx, y: base.y + offset.dy)
    }

    /// Drop: wherever every universe is now becomes its new home (pushed ones stay out of the way).
    func finishMovingUniverse() {
        dragged = nil
        for (id, body) in bodies {
            guard let base = baseLayout.universeCenter[id] else { continue }
            universeOffsets[id] = CGVector(dx: body.pos.x - base.x, dy: body.pos.y - base.y)
        }
        layout = baseLayout.shifted(by: universeOffsets, cosmos: cosmos)
        Self.saveOffsets(universeOffsets)
        if case .star(let id) = focus { orbit = OrbitLayout(center: id, cosmos: cosmos, layout: layout) }
    }

    func resetUniversePositions() {
        universeOffsets = [:]
        Self.saveOffsets([:])
        from = camera(at: .now, layout: layout, size: lastSize)
        layout = baseLayout
        frameBounds = layout.bounds
        flyStart = .now
    }

    /// One physics tick: springs pull every universe home, overlapping universes push apart,
    /// the dragged one follows the pointer and shoves the rest around it.
    func step(_ now: Date) {
        let dt = min(1.0 / 30, max(0, now.timeIntervalSince(lastStep ?? now)))
        lastStep = now
        guard dt > 0 else { return }
        let ids = cosmos.universes.map(\.id)
        for id in ids where bodies[id] == nil { bodies[id] = Body(pos: layout.universeCenter[id] ?? .zero) }

        // Soft, slightly overdamped motion: nothing bounces, everything glides and settles.
        // Universes start feeling each other a little before they touch (the soft zone),
        // and the push grows smoothly the closer they get.
        let gap: CGFloat = 12, spring: CGFloat = 1.4, softZone: CGFloat = 90, push: CGFloat = 12, maxSpeed: CGFloat = 320
        var force: [String: CGVector] = [:]
        for id in ids where id != dragged {
            guard let body = bodies[id], let home = layout.universeCenter[id] else { continue }
            force[id] = CGVector(dx: (home.x - body.pos.x) * spring, dy: (home.y - body.pos.y) * spring)
        }
        if let d = dragged {
            // The dragged universe trails the pointer slightly instead of snapping to it.
            let cur = bodies[d]?.pos ?? dragTarget
            let k = CGFloat(1 - exp(-12 * dt))
            bodies[d] = Body(pos: CGPoint(x: cur.x + (dragTarget.x - cur.x) * k, y: cur.y + (dragTarget.y - cur.y) * k))
        }
        // Universes only push each other while one is being dragged. At rest every universe sits
        // exactly at home, so nothing drifts away from its orbit or its camera target.
        for i in 0..<(dragged == nil ? 0 : ids.count) {
            for j in (i + 1)..<ids.count {
                let a = ids[i], b = ids[j]
                guard let pa = bodies[a]?.pos, let pb = bodies[b]?.pos else { continue }
                let need = (layout.universeRadius[a] ?? 60) + (layout.universeRadius[b] ?? 60) + gap
                var dx = pb.x - pa.x, dy = pb.y - pa.y
                var dist = hypot(dx, dy)
                if dist < 0.001 { dx = 1; dy = 0.3; dist = hypot(dx, dy) }
                guard dist < need + softZone else { continue }
                let pen = (need + softZone - dist) / softZone          // 0 at the edge of the soft zone, 1 at contact
                let f = push * softZone * pen * pen
                let ux = dx / dist, uy = dy / dist
                // A shove from the dragged universe is felt fully by the other one.
                let shareA: CGFloat = a == dragged ? 0 : (b == dragged ? 1 : 0.5)
                let shareB: CGFloat = b == dragged ? 0 : (a == dragged ? 1 : 0.5)
                force[a, default: .zero].dx -= ux * f * shareA * 2
                force[a, default: .zero].dy -= uy * f * shareA * 2
                force[b, default: .zero].dx += ux * f * shareB * 2
                force[b, default: .zero].dy += uy * f * shareB * 2
            }
        }
        let damping = CGFloat(exp(-3.4 * dt))
        for id in ids where id != dragged {
            guard var body = bodies[id] else { continue }
            let f = force[id] ?? .zero
            body.vel.dx = (body.vel.dx + f.dx * dt) * damping
            body.vel.dy = (body.vel.dy + f.dy * dt) * damping
            let speed = hypot(body.vel.dx, body.vel.dy)
            if speed > maxSpeed { body.vel.dx *= maxSpeed / speed; body.vel.dy *= maxSpeed / speed }
            body.pos.x += body.vel.dx * dt
            body.pos.y += body.vel.dy * dt
            bodies[id] = body
        }
    }

    /// How far a universe currently is from its home: physics plus a slow drift on the overview.
    func universeDelta(_ id: String?, now: Date) -> CGVector {
        guard let id, let home = layout.universeCenter[id] else { return .zero }
        var d = CGVector.zero
        if let body = bodies[id] { d = CGVector(dx: body.pos.x - home.x, dy: body.pos.y - home.y) }
        let w = CGFloat(overviewWeight(now))
        guard w > 0, id != dragged else { return d }
        let seed = stableSeed(id)
        let t = now.timeIntervalSinceReferenceDate
        let ph = Double(seed % 628) / 100
        let fx = 0.028 + Double(seed % 7) * 0.003, fy = 0.024 + Double(seed % 5) * 0.004
        // About 12 pt on screen whatever the zoom, made of two slow waves so the path never looks mechanical.
        let amp = 12 / max(lastScale, 0.05) * w
        d.dx += amp * CGFloat(0.7 * sin(2 * .pi * fx * t + ph) + 0.3 * sin(2 * .pi * fx * 2.3 * t + ph * 1.7))
        d.dy += amp * CGFloat(0.7 * cos(2 * .pi * fy * t + ph * 0.6) + 0.3 * sin(2 * .pi * fy * 1.9 * t + ph * 2.1))
        return d
    }

    func universeCenter(_ id: String, now: Date) -> CGPoint? {
        guard let c = layout.universeCenter[id] else { return nil }
        let d = universeDelta(id, now: now)
        return CGPoint(x: c.x + d.dx, y: c.y + d.dy)
    }

    func constellationCenter(_ id: String, universe: String, now: Date) -> CGPoint? {
        guard let c = layout.constellationCenter[id] else { return nil }
        let d = universeDelta(universe, now: now)
        return CGPoint(x: c.x + d.dx, y: c.y + d.dy)
    }

    /// 1 on the overview, 0 elsewhere, blended during the fly-over so the drift never jumps.
    private func overviewWeight(_ now: Date) -> Double {
        let p = ease(progress(now, flyStart, Self.flyDuration))
        switch (previousFocus, focus) {
        case (_, .multiverse): return previousFocus == .multiverse ? 1 : p
        case (.multiverse, _): return 1 - p
        default: return 0
        }
    }

    private static let offsetsKey = "space.universeOffsets"

    private static func loadOffsets() -> [String: CGVector] {
        guard let raw = UserDefaults.standard.dictionary(forKey: offsetsKey) as? [String: [Double]] else { return [:] }
        return raw.compactMapValues { $0.count == 2 ? CGVector(dx: $0[0], dy: $0[1]) : nil }
    }

    private static func saveOffsets(_ offsets: [String: CGVector]) {
        UserDefaults.standard.set(offsets.mapValues { [Double($0.dx), Double($0.dy)] }, forKey: offsetsKey)
    }

    func fly(to id: String, cosmos: Cosmos) {
        go(to: .star(id), cosmos: cosmos, layout: layout)
    }

    func go(to newFocus: Focus, cosmos: Cosmos, layout: WorldLayout, now: Date = .now) {
        from = camera(at: now, layout: layout, size: lastSize)
        pan = .zero
        zoom = 1
        panAtGestureStart = .zero
        zoomAtGestureStart = 1
        var start = now
        if orbit != nil {
            oldOrbit = orbit
            oldOrbitStart = now
            start = now.addingTimeInterval(Self.collapseDuration * 0.8)   // fold orbits, then fly
        }
        orbit = nil
        flyStart = start
        if case .star(let id) = newFocus {
            orbit = OrbitLayout(center: id, cosmos: cosmos, layout: layout)
            orbitStart = start.addingTimeInterval(Self.flyDuration - 0.08)
            trail.removeAll { $0 == id }
            trail.append(id)
            if trail.count > 6 { trail.removeFirst() }
        }
        previousFocus = focus
        focus = newFocus
        setHoveredStar(nil, now: now)
        hoveredUniverse = nil
    }

    func up(cosmos: Cosmos, layout: WorldLayout) {
        switch focus {
        case .star(let id): go(to: .universe(cosmos.universeOf[id] ?? ""), cosmos: cosmos, layout: layout)
        case .universe: go(to: .multiverse, cosmos: cosmos, layout: layout)
        case .multiverse: recenter()
        }
    }

    func recenter() {
        withAnimation(.smooth) { pan = .zero; zoom = 1 }
    }

    // MARK: Camera

    func targetCamera(for focus: Focus, layout: WorldLayout, size: CGSize) -> Camera {
        let w = max(size.width, 1), h = max(size.height, 1)
        switch focus {
        case .multiverse:
            let b = frameBounds.insetBy(dx: -40, dy: -40)
            return Camera(center: CGPoint(x: b.midX, y: b.midY), scale: min(w / b.width, h / b.height))
        case .universe(let id):
            let r = layout.universeRadius[id] ?? 100
            return Camera(center: layout.universeCenter[id] ?? .zero, scale: min(w, h) / (2 * r) * 0.92)
        case .star(let id):
            let r = (orbit?.outerRadius ?? 40) + 22
            let c = orbitOrigin(now: .now) ?? layout.star[id] ?? .zero
            return Camera(center: c, scale: min(w, h) / (2 * r))
        }
    }

    func camera(at now: Date, layout: WorldLayout, size: CGSize) -> Camera {
        let to = targetCamera(for: focus, layout: layout, size: size)
        let e = CGFloat(ease(progress(now, flyStart, Self.flyDuration)))
        // Scale is interpolated geometrically, so zooming feels even at every distance.
        let ratio = Double(to.scale / max(from.scale, 0.0001))
        let scale = from.scale * CGFloat(pow(ratio, Double(e))) * zoom
        var center = CGPoint(x: from.center.x + (to.center.x - from.center.x) * e,
                             y: from.center.y + (to.center.y - from.center.y) * e)
        center.x -= pan.width / scale
        center.y -= pan.height / scale
        return Camera(center: center, scale: scale)
    }

    // MARK: Star positions

    /// Home position, pulled onto its orbit in focus mode, plus a gentle individual drift.
    func position(of id: String, layout: WorldLayout, now: Date) -> CGPoint {
        // Home moves with its own universe; an orbit slot moves with the universe of the orbit's centre,
        // so stars from other universes still line up exactly on the rings.
        let own = universeDelta(cosmos.universeOf[id], now: now)
        let base = layout.star[id] ?? .zero
        let home = CGPoint(x: base.x + own.dx, y: base.y + own.dy)
        var p = home
        if let o = orbit, let target = o.position[id] {
            let c = universeDelta(cosmos.universeOf[o.center], now: now)
            p = lerp(home, CGPoint(x: target.x + c.dx, y: target.y + c.dy), ease(progress(now, orbitStart, Self.arrangeDuration)))
        } else if let o = oldOrbit, let was = o.position[id] {
            let c = universeDelta(cosmos.universeOf[o.center], now: now)
            p = lerp(CGPoint(x: was.x + c.dx, y: was.y + c.dy), home, ease(progress(now, oldOrbitStart, Self.collapseDuration)))
        }
        let d = drift(of: id, now: now)
        return CGPoint(x: p.x + d.dx, y: p.y + d.dy)
    }

    /// Centre of the current orbit, following its universe.
    func orbitOrigin(now: Date) -> CGPoint? {
        guard let o = orbit else { return nil }
        let c = universeDelta(cosmos.universeOf[o.center], now: now)
        return CGPoint(x: o.origin.x + c.dx, y: o.origin.y + c.dy)
    }

    /// Each star has its own clock. The clock stops while the star is hovered, so it freezes in place
    /// and continues smoothly afterwards.
    private func drift(of id: String, now: Date) -> CGVector {
        // Amplitude is set in screen points, so stars visibly float at every zoom level.
        let px: CGFloat
        switch focus {
        case .universe: px = 7
        case .star: px = 2
        case .multiverse: px = 4
        }
        let amplitude = px / max(lastScale, 0.05)
        let seed = seeds[id] ?? { let s = stableSeed(id); seeds[id] = s; return s }()
        let clock = (id == hoveredStar ? hoverStart : now).timeIntervalSinceReferenceDate - (timeShift[id] ?? 0)
        let n = Double(seed % 997)
        let fx = 0.07 + Double(seed % 7) * 0.012, fy = 0.06 + Double(seed % 5) * 0.014
        let ax = amplitude * (0.8 + CGFloat(seed % 10) / 20), ay = amplitude * (0.8 + CGFloat(seed % 8) / 16)
        return CGVector(dx: ax * CGFloat(sin(2 * .pi * fx * clock + n)), dy: ay * CGFloat(cos(2 * .pi * fy * clock + n * 0.7)))
    }

    /// 0…1 progress of the orbit arrangement, used to fade orbit rings and labels in.
    func orbitProgress(_ now: Date) -> Double { orbit == nil ? 0 : ease(progress(now, orbitStart, Self.arrangeDuration)) }

    // MARK: Hover

    func setHoveredStar(_ id: String?, now: Date = .now) {
        guard id != hoveredStar else { return }
        if let old = hoveredStar { timeShift[old, default: 0] += now.timeIntervalSince(hoverStart) }
        hoveredStar = id
        hoverStart = now
    }

    func setHoveredUniverse(_ id: String?) {
        if id != hoveredUniverse { hoveredUniverse = id }
    }

    // MARK: Math

    private func progress(_ now: Date, _ start: Date, _ duration: Double) -> Double {
        min(1, max(0, now.timeIntervalSince(start) / duration))
    }
    private func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let k = CGFloat(t)
        return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }
}

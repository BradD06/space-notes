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
    /// True while the history of the vault is being played on the overview.
    private(set) var isPlayingHistory = false

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
    var lens: Lens?
    /// Set by the renderer each frame from the vault's hints, so drawing and hit tests share one copy.
    @ObservationIgnored var insights = Insights(Cosmos())

    // Gestures
    var pan: CGSize = .zero
    var zoom: CGFloat = 1
    @ObservationIgnored var panAtGestureStart: CGSize = .zero
    /// After a fling the map keeps gliding and slows down (kept outside `pan` so drawing never mutates observed state).
    @ObservationIgnored private var glide: CGSize = .zero
    @ObservationIgnored private var glideVelocity: CGSize = .zero
    @ObservationIgnored var zoomAtGestureStart: CGFloat = 1

    // Timing (not observed: the TimelineView redraws every frame anyway)
    @ObservationIgnored private var from = Camera(center: .zero, scale: 0.3)
    @ObservationIgnored private var flyStart: Date = .distantPast
    @ObservationIgnored private var orbitStart: Date = .distantPast
    @ObservationIgnored private var oldOrbit: OrbitLayout?
    @ObservationIgnored private var oldOrbitStart: Date = .distantPast
    /// Replay of the cascade: everything folds into the centre star, then grows back out orbit by orbit,
    /// each star leaving from the star it is linked through.
    @ObservationIgnored private var bloomFromParent = false
    @ObservationIgnored private var foldStart: Date = .distantPast
    /// "Большой взрыв": all universes fly out of one point, then their stars spread out inside them.
    @ObservationIgnored private var introStart: Date = .distantPast
    /// History: when each star is born on the playback timeline (seconds after `historyStart`), in creation order.
    @ObservationIgnored private var historyStart: Date = .distantFuture
    @ObservationIgnored private var historyDuration: Double = 10
    @ObservationIgnored private var historyBirth: [String: Double] = [:]
    @ObservationIgnored private var historyTimeline: [(at: Double, date: Date, id: String)] = []
    @ObservationIgnored private var historyToken = 0
    @ObservationIgnored private var timeShift: [String: Double] = [:]
    @ObservationIgnored private var hoverStart: Date = .now
    @ObservationIgnored private var seeds: [String: UInt64] = [:]
    @ObservationIgnored var lastSize = CGSize(width: 1000, height: 700)
    /// Camera scale of the last drawn frame; drift is measured in screen points through it.
    @ObservationIgnored var lastScale: CGFloat = 1

    static let flyDuration = 0.65
    static let arrangeDuration = 0.5
    static let collapseDuration = 0.28
    /// Delay between orbits in the cascade, and the extra sweep around one orbit.
    static let ringDelay = 0.3
    static let sweep = 0.18
    static let foldDuration = 0.4
    /// Total length of the opening animation of the overview.
    static let introLength = 3.6

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
        universeBond = [:]
        for e in cosmos.edges {
            guard let a = cosmos.universeOf[e.a], let b = cosmos.universeOf[e.b], a != b else { continue }
            universeBond[a, default: [:]][b, default: 0] += 1
            universeBond[b, default: [:]][a, default: 0] += 1
        }
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
        bloomFromParent = false
    }

    // MARK: Universes: floating, dragging, pushing each other

    /// A universe as a physical body. `pos` is its centre without the gentle drift.
    private struct Body { var pos: CGPoint; var vel: CGVector = .zero }
    @ObservationIgnored private var bodies: [String: Body] = [:]
    @ObservationIgnored private var lastStep: Date?
    @ObservationIgnored private var dragged: String?
    @ObservationIgnored private var dragTarget: CGPoint = .zero
    @ObservationIgnored private var dragRelative: [String: CGVector] = [:]
    /// Number of links between every pair of universes.
    @ObservationIgnored private var universeBond: [String: [String: CGFloat]] = [:]
    @ObservationIgnored private var previousFocus: Focus = .multiverse

    func offset(of universe: String) -> CGVector { universeOffsets[universe] ?? .zero }

    /// Called while a universe is dragged. Only the dragged body is moved; the others react in `step`.
    func move(universe: String, to offset: CGVector) {
        guard let base = baseLayout.universeCenter[universe] else { return }
        if dragged != universe, let p = bodies[universe]?.pos {
            // Remember where every linked universe sits relative to the grabbed one.
            dragRelative = [:]
            for (id, b) in bodies where id != universe { dragRelative[id] = CGVector(dx: b.pos.x - p.x, dy: b.pos.y - p.y) }
        }
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
        smoothK = 1 - exp(-14 * dt)
        if abs(glideVelocity.width) + abs(glideVelocity.height) > 2 {
            glide.width += glideVelocity.width * dt
            glide.height += glideVelocity.height * dt
            let k = exp(-4.5 * dt)
            glideVelocity.width *= k; glideVelocity.height *= k
        } else if settleAfterGlide {
            // The glide has stopped: decide which universe we are in (outside of drawing).
            settleAfterGlide = false
            Task { @MainActor [weak self] in self?.settle() }
        }
        stepElastic(dt)
        let ids = cosmos.universes.map(\.id)
        for id in ids where bodies[id] == nil { bodies[id] = Body(pos: layout.universeCenter[id] ?? .zero) }

        // Dragging works like pulling one blob of a soft, connected mass:
        // universes linked to the dragged one are tethered to it and follow (the more links, the closer),
        // and may slide into it and overlap; unlinked ones only drift softly out of the way.
        var force: [String: CGVector] = [:]
        let tether = dragged.flatMap { universeBond[$0] } ?? [:]
        let strongest = max(1, tether.values.max() ?? 1)
        for id in ids where id != dragged {
            guard let body = bodies[id], let home = layout.universeCenter[id] else { continue }
            var homeK: CGFloat = 4
            if let d = dragged, let w = tether[id], let dp = bodies[d]?.pos, let rel = dragRelative[id] {
                let s = 0.35 + 0.65 * w / strongest                       // 0.35…1 by number of links
                homeK *= 1 - 0.85 * s
                force[id, default: .zero].dx += (dp.x + rel.dx * (1 - 0.45 * s) - body.pos.x) * 5 * s
                force[id, default: .zero].dy += (dp.y + rel.dy * (1 - 0.45 * s) - body.pos.y) * 5 * s
            }
            force[id, default: .zero].dx += (home.x - body.pos.x) * homeK
            force[id, default: .zero].dy += (home.y - body.pos.y) * homeK
        }
        if let d = dragged {
            // The dragged universe trails the pointer slightly instead of snapping to it.
            let cur = bodies[d]?.pos ?? dragTarget
            let k = CGFloat(1 - exp(-14 * dt))
            bodies[d] = Body(pos: CGPoint(x: cur.x + (dragTarget.x - cur.x) * k, y: cur.y + (dragTarget.y - cur.y) * k))
        }
        // A soft cushion between universes, only while something is dragged (at rest everything sits at home).
        // Linked universes have a much smaller cushion, so they can sink into each other.
        for i in 0..<(dragged == nil ? 0 : ids.count) {
            for j in (i + 1)..<ids.count {
                let a = ids[i], b = ids[j]
                guard let pa = bodies[a]?.pos, let pb = bodies[b]?.pos else { continue }
                let linked = (universeBond[a]?[b] ?? 0) > 0
                let ra = layout.universeRadius[a] ?? 60, rb = layout.universeRadius[b] ?? 60
                let need = linked ? 0.45 * max(ra, rb) : ra + rb + 8
                var dx = pb.x - pa.x, dy = pb.y - pa.y
                var dist = hypot(dx, dy)
                if dist < 0.001 { dx = 1; dy = 0.3; dist = hypot(dx, dy) }
                let zone: CGFloat = linked ? 30 : 70
                guard dist < need + zone else { continue }
                let pen = min(1.6, (need + zone - dist) / zone)
                let f = (linked ? 140 : 420) * pen * pen
                let ux = dx / dist, uy = dy / dist
                let shareA: CGFloat = a == dragged ? 0 : (b == dragged ? 1 : 0.5)
                let shareB: CGFloat = b == dragged ? 0 : (a == dragged ? 1 : 0.5)
                force[a, default: .zero].dx -= ux * f * shareA
                force[a, default: .zero].dy -= uy * f * shareA
                force[b, default: .zero].dx += ux * f * shareB
                force[b, default: .zero].dy += uy * f * shareB
            }
        }
        // Heavy, honey-like damping: nothing bounces off anything, it all flows.
        let damping = CGFloat(exp(-4.5 * dt)), maxSpeed: CGFloat = 320
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

    /// Bumped when the packing of universes changes, so positions dragged in an older layout are dropped.
    private static let layoutVersion = 2

    private static func loadOffsets() -> [String: CGVector] {
        if UserDefaults.standard.integer(forKey: offsetsKey + ".version") < layoutVersion {
            UserDefaults.standard.removeObject(forKey: offsetsKey)
            UserDefaults.standard.set(layoutVersion, forKey: offsetsKey + ".version")
            return [:]
        }
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
        glide = .zero; glideVelocity = .zero
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
        bloomFromParent = false
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

    /// The "cascade" button: fold the orbits into the centre star and let them grow out again, 1 → 2 → 3 → 4 → …
    func replayCascade(now: Date = .now) {
        guard orbit != nil else { return }
        // Bring the camera home first, so the whole cascade is in view.
        from = camera(at: now, layout: layout, size: lastSize)
        pan = .zero; zoom = 1; panAtGestureStart = .zero; zoomAtGestureStart = 1
        previousFocus = focus
        flyStart = now
        foldStart = now
        bloomFromParent = true
        orbitStart = now.addingTimeInterval(Self.foldDuration + 0.05)
    }

    // MARK: Awakening (how the map appears when it opens)

    /// Plays the opening of the overview: the camera drifts in, nebulae breathe in one by one,
    /// stars light up at their own pace while swirling gently into place, and links draw themselves
    /// from star to star. Every element has its own random timing, so nothing moves in lockstep.
    func playIntro(now: Date = .now) {
        guard focus == .multiverse else { return }
        introStart = now
    }

    private func introActive(_ now: Date) -> Bool { now < introStart.addingTimeInterval(Self.introLength) }

    private func introRandom(_ id: String, _ salt: UInt64) -> Double {
        Double((stableSeed(id) &* 0x9E3779B97F4A7C15 &+ salt) % 10_000) / 10_000
    }

    private func introUniverseDelay(_ id: String) -> Double { 0.1 + 0.5 * introRandom(id, 11) }

    /// Camera dolly: starts a little farther away and slowly settles, like breathing in.
    func introZoom(now: Date) -> CGFloat {
        guard introActive(now) else { return 1 }
        let t = progress(now, introStart, 2.6)
        return CGFloat(0.8 + 0.2 * (1 - pow(1 - t, 4)))
    }

    /// 0…1: how far a universe nebula has faded in.
    func introUniverse(_ id: String?, now: Date) -> Double {
        guard let id, introActive(now) else { return 1 }
        let t = progress(now, introStart.addingTimeInterval(introUniverseDelay(id)), 1.4)
        return 1 - pow(1 - t, 3)
    }

    /// Linear 0…1 of a star's appearance; each star has its own moment.
    func introStar(_ id: String, now: Date) -> Double {
        guard introActive(now) else { return 1 }
        return progress(now, introStart.addingTimeInterval(introStarDelay(id)), 1.0)
    }

    private func introStarDelay(_ id: String) -> Double {
        let u = cosmos.universeOf[id] ?? ""
        return introUniverseDelay(u) + 0.3 + 1.1 * introRandom(id, 23)
    }

    /// 0…1: how much of a link is drawn; it grows from the star that lit up first once both are visible.
    func introEdge(_ a: String, _ b: String, now: Date) -> (progress: Double, fromA: Bool) {
        guard introActive(now) else { return (1, true) }
        let da = introStarDelay(a), db = introStarDelay(b)
        let t = progress(now, introStart.addingTimeInterval(max(da, db) + 0.45), 0.8)
        return (1 - pow(1 - t, 3), da <= db)
    }

    // MARK: Elastic stars (drag a star, its neighbours follow like on rubber bands)

    @ObservationIgnored private var elastic: [String: CGVector] = [:]      // offset from layout position
    @ObservationIgnored private var elasticVel: [String: CGVector] = [:]
    @ObservationIgnored private var draggedStar: String?
    @ObservationIgnored private var dragStarTarget: CGPoint = .zero

    /// Called while a star is dragged inside a universe; `point` is in world units.
    func dragStar(_ id: String, to point: CGPoint) {
        draggedStar = id
        dragStarTarget = point
        setHoveredStar(id)
    }

    /// Let go: the star and its neighbours glide back into the calm layout.
    func releaseStar() { draggedStar = nil }

    /// One tick of the rubber-band physics. Every link tries to keep its original shape, every star is
    /// gently pulled home; so a dragged star drags its neighbours, they drag theirs a bit less, and so on.
    private func stepElastic(_ dt: Double) {
        guard draggedStar != nil || !elastic.isEmpty else { return }
        let dt = CGFloat(dt)
        var ids = Set(elastic.keys)
        if let d = draggedStar {
            ids.insert(d)
            for n in cosmos.neighbors[d] ?? [] { ids.insert(n); for m in cosmos.neighbors[n] ?? [] { ids.insert(m) } }
        }
        var force: [String: CGVector] = [:]
        for id in ids {
            let o = elastic[id] ?? .zero
            force[id] = CGVector(dx: -o.dx * 9, dy: -o.dy * 9)            // home spring
            for n in cosmos.neighbors[id] ?? [] where cosmos.universeOf[n] == cosmos.universeOf[id] {
                let on = elastic[n] ?? .zero
                force[id]!.dx += (on.dx - o.dx) * 26                       // link keeps its shape
                force[id]!.dy += (on.dy - o.dy) * 26
            }
        }
        let damping = CGFloat(exp(-9 * Double(dt)))
        var next: [String: CGVector] = [:]
        var nextVel: [String: CGVector] = [:]
        for id in ids {
            if id == draggedStar, let base = layout.star[id] {
                // The dragged star follows the pointer with a tiny lag, which reads as weight.
                let o = elastic[id] ?? .zero
                let want = CGVector(dx: dragStarTarget.x - base.x, dy: dragStarTarget.y - base.y)
                let k = 1 - exp(-22 * dt)
                next[id] = CGVector(dx: o.dx + (want.dx - o.dx) * k, dy: o.dy + (want.dy - o.dy) * k)
                nextVel[id] = .zero
                continue
            }
            var v = elasticVel[id] ?? .zero
            let f = force[id] ?? .zero
            v.dx = (v.dx + f.dx * dt) * damping
            v.dy = (v.dy + f.dy * dt) * damping
            var o = elastic[id] ?? .zero
            o.dx += v.dx * dt; o.dy += v.dy * dt
            if abs(o.dx) + abs(o.dy) < 0.02, abs(v.dx) + abs(v.dy) < 0.05, draggedStar == nil { continue }
            next[id] = o; nextVel[id] = v
        }
        elastic = next
        elasticVel = nextVel
    }

    // MARK: Labels that don't blink

    /// Names that were on screen in the last frame: they keep their place first next frame.
    @ObservationIgnored var shownLabels: Set<String> = []
    @ObservationIgnored private var labelAlpha: [String: Double] = [:]

    /// Fades a name in or out over ~0.25 s instead of switching it in one frame.
    func labelFade(_ key: String, visible: Bool) -> Double {
        let k = 1 - pow(1 - smoothK, 0.55)          // a bit slower than other smoothing
        let old = labelAlpha[key] ?? 0
        let a = old + ((visible ? 1 : 0) - old) * k
        labelAlpha[key] = a < 0.01 && !visible ? nil : a
        return a
    }

    // MARK: Smoothing (hover and focus changes fade instead of switching)

    @ObservationIgnored private var smoothK: Double = 1
    @ObservationIgnored private var smoothStar: [String: (alpha: Double, size: CGFloat)] = [:]
    @ObservationIgnored private var smoothEdge: [Cosmos.Edge: (alpha: Double, width: CGFloat)] = [:]

    /// Moves a star's drawn alpha and size a little towards their targets every frame.
    func smoothed(star id: String, alpha: Double, size: CGFloat) -> (Double, CGFloat) {
        guard let old = smoothStar[id] else { smoothStar[id] = (alpha, size); return (alpha, size) }
        let a = old.alpha + (alpha - old.alpha) * smoothK
        let s = old.size + (size - old.size) * CGFloat(smoothK)
        smoothStar[id] = (a, s)
        return (a, s)
    }

    func smoothed(edge e: Cosmos.Edge, alpha: Double, width: CGFloat) -> (Double, CGFloat) {
        guard let old = smoothEdge[e] else { smoothEdge[e] = (alpha, width); return (alpha, width) }
        let a = old.alpha + (alpha - old.alpha) * smoothK
        let w = old.width + (width - old.width) * CGFloat(smoothK)
        smoothEdge[e] = (a, w)
        return (a, w)
    }

    // MARK: History

    static let historyAppear = 0.7

    /// Plays the life of the vault: stars light up in the order their files were created and glide into
    /// their universe; a universe appears together with its first star, links appear once both ends exist.
    func playHistory(now: Date = .now) {
        let notes = cosmos.notes.values.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
        guard !notes.isEmpty else { return }
        var start = now.addingTimeInterval(0.3)
        if focus != .multiverse {
            go(to: .multiverse, cosmos: cosmos, layout: layout, now: now)
            start = flyStart.addingTimeInterval(Self.flyDuration)
        } else {
            from = camera(at: now, layout: layout, size: lastSize)
            pan = .zero; zoom = 1; panAtGestureStart = .zero; zoomAtGestureStart = 1
            previousFocus = focus
            flyStart = now
        }
        introStart = .distantPast

        // Pace: mostly real time (so busy weeks look busy), partly evenly, so long quiet months
        // don't leave the screen empty for seconds.
        let n = notes.count
        historyDuration = min(24, max(6, 4 + Double(n) * 0.05))
        let known = notes.map(\.created).filter { $0 > .distantPast }
        let t0 = known.first ?? now, t1 = known.last ?? now
        let span = max(1, t1.timeIntervalSince(t0))
        historyBirth = [:]
        historyTimeline = []
        for (i, note) in notes.enumerated() {
            let rank = n == 1 ? 0 : Double(i) / Double(n - 1)
            let real = note.created > .distantPast ? note.created.timeIntervalSince(t0) / span : 0
            let at = (0.6 * real + 0.4 * rank) * historyDuration
            historyBirth[note.id] = at
            historyTimeline.append((at, note.created > .distantPast ? note.created : t0, note.id))
        }
        historyStart = start
        isPlayingHistory = true
        historyToken += 1
        let token = historyToken
        let total = start.timeIntervalSince(now) + historyDuration + Self.historyAppear + 0.2
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(total))
            guard let self, self.historyToken == token else { return }
            self.isPlayingHistory = false
            self.historyStart = .distantFuture
        }
    }

    func stopHistory() {
        historyToken += 1
        isPlayingHistory = false
        historyStart = .distantFuture
    }

    private func historyRunning(_ now: Date) -> Bool {
        isPlayingHistory && now < historyStart.addingTimeInterval(historyDuration + Self.historyAppear + 0.1)
    }

    /// 0…1: how far a star has appeared in the history playback (1 when no playback).
    func historyAppear(_ id: String, now: Date) -> Double {
        guard historyRunning(now) else { return 1 }
        guard let at = historyBirth[id] else { return 0 }
        return progress(now, historyStart.addingTimeInterval(at), Self.historyAppear)
    }

    /// 0…1: how much of a universe exists at this moment of the playback (share of its stars born, eased).
    func historyUniverse(_ id: String, now: Date) -> Double {
        guard historyRunning(now), let u = cosmos.universe(id) else { return 1 }
        let ids = u.constellations.flatMap(\.noteIDs)
        guard !ids.isEmpty else { return 1 }
        let born = ids.reduce(0.0) { $0 + historyAppear($1, now: now) }
        guard born > 0 else { return 0 }
        return 0.35 + 0.65 * sqrt(born / Double(ids.count))
    }

    /// The date shown during the playback and how many stars exist by then.
    func historyStatus(now: Date) -> (date: Date, count: Int, total: Int, progress: Double)? {
        guard isPlayingHistory, !historyTimeline.isEmpty else { return nil }
        let t = now.timeIntervalSince(historyStart)
        var count = 0
        var date = historyTimeline[0].date
        for item in historyTimeline where item.at <= t { count += 1; date = item.date }
        return (date, count, historyTimeline.count, min(1, max(0, t / historyDuration)))
    }

    /// Pan gesture ended with some speed (points per second): let the map coast.
    func fling(velocity: CGSize) {
        glideVelocity = CGSize(width: velocity.width * 0.35, height: velocity.height * 0.35)
    }

    // MARK: Moving between universes with swipes

    /// True while the pointer is over the map, so trackpad scrolling there pans the map.
    @ObservationIgnored var pointerOverMap = false
    @ObservationIgnored private var settleAfterGlide = false

    /// Trackpad two-finger scroll: move the map like a page.
    func scrollPan(dx: CGFloat, dy: CGFloat) {
        glideVelocity = .zero
        pan.width += dx; pan.height += dy
        panAtGestureStart = pan
    }

    /// Mouse wheel (no trackpad): zoom around the centre.
    func wheelZoom(_ dy: CGFloat) {
        zoom = min(4, max(0.4, zoom * exp(dy * 0.01)))
        zoomAtGestureStart = zoom
    }

    /// A quick swipe inside a universe jumps to the neighbouring universe in that direction
    /// (the content moves with the finger, so the camera goes the other way).
    /// Returns false when there is no universe that way — then the map just glides.
    @discardableResult
    func swipe(velocity: CGSize) -> Bool {
        guard case .universe(let current) = focus, let here = universeCenter(current, now: .now) else { return false }
        let speed = hypot(velocity.width, velocity.height)
        guard speed > 650 else { return false }
        let want = CGVector(dx: -velocity.width / speed, dy: -velocity.height / speed)
        var best: (String, CGFloat)?
        for u in cosmos.universes where u.id != current {
            guard let c = universeCenter(u.id, now: .now) else { continue }
            let v = CGVector(dx: c.x - here.x, dy: c.y - here.y)
            let d = max(1, hypot(v.dx, v.dy))
            let cosA = (v.dx * want.dx + v.dy * want.dy) / d
            guard cosA > 0.55 else { continue }                       // within ~56° of the swipe
            let score = d * (2 - cosA)                                // near and straight ahead wins
            if best == nil || score < best!.1 { best = (u.id, score) }
        }
        guard let target = best?.0 else { return false }
        go(to: .universe(target), cosmos: cosmos, layout: layout)
        return true
    }

    /// After panning stops inside a universe: if another universe is now in the middle of the screen,
    /// smoothly make it the current one.
    func settle(now: Date = .now) {
        guard case .universe(let current) = focus else { return }
        let mid = camera(at: now, layout: layout, size: lastSize).center
        var best: (String, CGFloat)?
        for u in cosmos.universes {
            guard let c = universeCenter(u.id, now: now), let r = layout.universeRadius[u.id] else { continue }
            let ratio = hypot(c.x - mid.x, c.y - mid.y) / max(r, 1)
            if best == nil || ratio < best!.1 { best = (u.id, ratio) }
        }
        if let best, best.0 != current, best.1 < 1.1 {
            go(to: .universe(best.0), cosmos: cosmos, layout: layout)
        }
    }

    /// Called when a drag ends: swipe to a neighbour, or glide and look where we stopped.
    func endPan(velocity: CGSize) {
        if swipe(velocity: velocity) { return }
        fling(velocity: velocity)
        settleAfterGlide = true
    }

    /// A new touch stops the glide where it is.
    func catchGlide() {
        settleAfterGlide = false
        pan.width += glide.width; pan.height += glide.height
        glide = .zero; glideVelocity = .zero
        panAtGestureStart = pan
    }

    func up(cosmos: Cosmos, layout: WorldLayout) {
        switch focus {
        case .star(let id): go(to: .universe(cosmos.universeOf[id] ?? ""), cosmos: cosmos, layout: layout)
        case .universe: go(to: .multiverse, cosmos: cosmos, layout: layout)
        case .multiverse: recenter()
        }
    }

    func recenter() {
        glide = .zero; glideVelocity = .zero
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
        let scale = from.scale * CGFloat(pow(ratio, Double(e))) * zoom * introZoom(now: now)
        var center = CGPoint(x: from.center.x + (to.center.x - from.center.x) * e,
                             y: from.center.y + (to.center.y - from.center.y) * e)
        center.x -= (pan.width + glide.width) / scale
        center.y -= (pan.height + glide.height) / scale
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
        if introActive(now), let u = cosmos.universeOf[id], let uc = layout.universeCenter[u] {
            // Stars swirl into place around the centre of their universe, like a galaxy settling.
            let t = introStar(id, now: now)
            let e = 1 - pow(1 - t, 3)
            let angle = -0.55 * (1 - e) * (0.6 + 0.8 * introRandom(id, 5))
            let scale = 0.86 + 0.14 * e
            let vx = (base.x - uc.x) * scale, vy = (base.y - uc.y) * scale
            p = CGPoint(x: uc.x + own.dx + vx * CGFloat(cos(angle)) - vy * CGFloat(sin(angle)),
                        y: uc.y + own.dy + vx * CGFloat(sin(angle)) + vy * CGFloat(cos(angle)))
        }
        if historyRunning(now), let u = cosmos.universeOf[id], let uc = layout.universeCenter[u] {
            let a = historyAppear(id, now: now)
            if a < 1 {
                let seed = stableSeed(id)
                let angle = Double(seed % 6283) / 1000
                let r = (layout.universeRadius[u] ?? 60) * 1.35
                let entry = CGPoint(x: uc.x + own.dx + r * CGFloat(cos(angle)), y: uc.y + own.dy + r * CGFloat(sin(angle)))
                p = lerp(entry, p, 1 - pow(1 - a, 3))
            }
        }
        if let o = orbit, o.position[id] != nil {
            p = orbitPosition(of: id, orbit: o, home: home, now: now)
        } else if let o = oldOrbit, let was = o.position[id] {
            let c = universeDelta(cosmos.universeOf[o.center], now: now)
            p = lerp(CGPoint(x: was.x + c.dx, y: was.y + c.dy), home, ease(progress(now, oldOrbitStart, Self.collapseDuration)))
        }
        let d = drift(of: id, now: now)
        let e = elastic[id] ?? .zero
        return CGPoint(x: p.x + d.dx + e.dx, y: p.y + d.dy + e.dy)
    }

    /// Where a star of the current orbit is right now during the cascade.
    private func orbitPosition(of id: String, orbit o: OrbitLayout, home: CGPoint, now: Date) -> CGPoint {
        let c = universeDelta(cosmos.universeOf[o.center], now: now)
        guard let t = o.position[id] else { return home }
        let target = CGPoint(x: t.x + c.dx, y: t.y + c.dy)
        let k = starProgress(id, now: now)
        guard bloomFromParent, id != o.center else { return lerp(home, target, k) }
        // Replay: first everything folds into the centre…
        if now < orbitStart {
            let centre = CGPoint(x: o.origin.x + c.dx, y: o.origin.y + c.dy)
            return lerp(target, centre, ease(progress(now, foldStart, Self.foldDuration)))
        }
        // …then each star leaves from the star it is linked through.
        let parentID = o.parent[id] ?? o.center
        let from = parentID == o.center
            ? CGPoint(x: o.origin.x + c.dx, y: o.origin.y + c.dy)
            : orbitPosition(of: parentID, orbit: o, home: home, now: now)
        return lerp(from, target, k)
    }

    /// 0…1: how far one star has moved onto its orbit. Orbit 1 goes first, then 2, 3, 4…,
    /// and inside an orbit the stars follow each other clockwise from the top.
    func starProgress(_ id: String, now: Date) -> Double {
        guard let o = orbit else { return 0 }
        guard let ring = o.ringOf[id] else { return id == o.center ? 1 : 0 }
        var delay = Double(ring - 1) * Self.ringDelay
        if let p = o.position[id] {
            var a = atan2(Double(p.y - o.origin.y), Double(p.x - o.origin.x)) + .pi / 2
            if a < 0 { a += 2 * .pi }
            delay += Self.sweep * a / (2 * .pi)
        }
        return ease(progress(now, orbitStart.addingTimeInterval(delay), Self.arrangeDuration))
    }

    /// 0…1: how far an orbit ring (its circle, title and lines) has appeared.
    func ringProgress(_ ring: Int, now: Date) -> Double {
        guard orbit != nil else { return 0 }
        return ease(progress(now, orbitStart.addingTimeInterval(Double(ring - 1) * Self.ringDelay), Self.arrangeDuration))
    }

    /// 0…1 while a replay folds everything into the centre; nil when no fold is going on.
    private func foldFade(_ now: Date) -> Double? {
        guard bloomFromParent, now < orbitStart else { return nil }
        return 1 - ease(progress(now, foldStart, Self.foldDuration))
    }

    /// How visible an orbit star (and the line to it) is during the cascade.
    func starVisibility(_ id: String, now: Date) -> Double {
        if let f = foldFade(now) { return f }
        let k = starProgress(id, now: now)
        return bloomFromParent ? k : 0.3 + 0.7 * k
    }

    /// How visible an orbit ring and its title are during the cascade.
    func ringVisibility(_ ring: Int, now: Date) -> Double {
        foldFade(now) ?? ringProgress(ring, now: now)
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
        case .star: px = 3.5
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
        peekStar = nil
        if let old = hoveredStar { timeShift[old, default: 0] += now.timeIntervalSince(hoverStart) }
        hoveredStar = id
        hoverStart = now
    }

    // MARK: Sticky hover
    // Pointing at a star pins it: its links stay lit while the mouse travels to the stars it is linked to.
    // A linked star under the mouse is "peeked" (lit on top of the pinned view). The pin moves to another
    // star only after resting on it for a moment, and is released after a while in empty space,
    // with a click on empty space, or with Esc.

    /// The linked star currently under the mouse while another star is pinned.
    private(set) var peekStar: String?
    @ObservationIgnored private var pendingPin: String??
    @ObservationIgnored private var pendingToken = 0

    func pointer(over id: String?) {
        guard let pinned = hoveredStar else {
            if let id { setHoveredStar(id) }
            return
        }
        if id == pinned { peekStar = nil; pendingPin = nil; return }
        if let id, isRelated(id, to: pinned) {
            if peekStar != id { peekStar = id }
            pendingPin = nil
            return
        }
        if peekStar != nil { peekStar = nil }
        // Unrelated star or empty space: keep the pin a little, then move or release it.
        if let p = pendingPin, p == id { return }
        pendingPin = .some(id)
        pendingToken += 1
        let token = pendingToken
        let delay = id == nil ? 1.2 : 0.45
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.pendingToken == token, let p = self.pendingPin else { return }
            self.pendingPin = nil
            self.setHoveredStar(p)
        }
    }

    /// Release the pin right away (click on empty space, Esc).
    func unpin() {
        pendingToken += 1
        pendingPin = nil
        peekStar = nil
        setHoveredStar(nil)
    }

    private func isRelated(_ id: String, to pinned: String) -> Bool {
        if cosmos.neighbors[pinned]?.contains(id) == true { return true }
        if let o = orbit, o.center != pinned, o.path(to: pinned).contains(id) || id == o.center { return true }
        return false
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

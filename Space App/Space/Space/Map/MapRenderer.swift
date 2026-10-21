import SwiftUI

/// Draws one frame of the map into a Canvas. Stateless: everything comes from the model and the time.
@MainActor
struct MapRenderer {
    let cosmos: Cosmos
    let model: MapModel
    let now: Date
    let size: CGSize

    private var layout: WorldLayout { model.layout }

    func draw(in ctx: inout GraphicsContext) {
        let cam = model.camera(at: now, layout: layout, size: size)
        model.lastScale = cam.scale
        let toScreen: (CGPoint) -> CGPoint = { p in
            CGPoint(x: (p.x - cam.center.x) * cam.scale + size.width / 2,
                    y: (p.y - cam.center.y) * cam.scale + size.height / 2)
        }
        let focus = model.focus
        let focusedStar = model.focusedStar
        let currentUniverse = model.focusedUniverse ?? focusedStar.flatMap { cosmos.universeOf[$0] }
        let orbit = model.orbit
        let arranged = model.orbitProgress(now)
        let hovered = model.hoveredStar
        let hoverNeighbors = hovered.flatMap { cosmos.neighbors[$0] } ?? []

        var screen: [String: CGPoint] = [:]
        screen.reserveCapacity(layout.star.count)
        for id in layout.star.keys {
            screen[id] = toScreen(model.position(of: id, layout: layout, now: now))
        }

        drawUniverses(&ctx, cam: cam, toScreen: toScreen, focus: focus, current: currentUniverse)
        if case .universe(let uid) = focus { drawConstellations(&ctx, universe: uid, cam: cam, toScreen: toScreen) }
        if let orbit { drawOrbitRings(&ctx, orbit: orbit, cam: cam, toScreen: toScreen, alpha: arranged) }
        drawEdges(&ctx, screen: screen, focus: focus, orbit: orbit, arranged: arranged, hovered: hovered)
        let starLabels = drawStars(&ctx, screen: screen, focus: focus, orbit: orbit, arranged: arranged,
                                   hovered: hovered, hoverNeighbors: hoverNeighbors, cam: cam)

        // Labels go last and never overlap: constellation names first, then star names by importance.
        // A star name that would collide with something already placed is simply skipped.
        var placer = LabelPlacer()
        if case .multiverse = focus { drawUniverseLabels(&ctx, cam: cam, toScreen: toScreen, placer: &placer) }
        if case .universe(let uid) = focus { drawNeighbourNames(&ctx, current: uid, cam: cam, toScreen: toScreen, placer: &placer) }
        if case .universe(let uid) = focus { drawConstellationLabels(&ctx, universe: uid, cam: cam, toScreen: toScreen, placer: &placer) }
        if let orbit {
            drawRingTitles(&ctx, orbit: orbit, cam: cam, toScreen: toScreen, alpha: arranged, placer: &placer)
            drawGroupLabels(&ctx, orbit: orbit, cam: cam, toScreen: toScreen, alpha: arranged, placer: &placer)
        }
        drawStarLabels(&ctx, starLabels, placer: &placer)
    }

    // MARK: Layers

    private func drawUniverses(_ ctx: inout GraphicsContext, cam: Camera, toScreen: (CGPoint) -> CGPoint, focus: MapModel.Focus, current: String?) {
        for u in cosmos.universes {
            guard let c = model.universeCenter(u.id, now: now), let r0 = layout.universeRadius[u.id] else { continue }
            let grown = model.historyUniverse(u.id, now: now)
            let reveal = model.introUniverse(u.id, now: now)
            let born = reveal * min(1, grown * 1.5)
            guard born > 0.01 else { continue }
            // A nebula breathes in: it fades up while swelling slightly past its size and settling back.
            let swell = 0.78 + 0.22 * reveal + 0.06 * sin(.pi * reveal)
            let p = toScreen(c), r = r0 * cam.scale * CGFloat(swell) * CGFloat(grown)
            let color = Theme.color(forUniverse: u.id)
            var alpha: Double
            switch focus {
            case .multiverse: alpha = (model.hoveredUniverse == nil || model.hoveredUniverse == u.id) ? 1 : 0.4
            case .universe(let id): alpha = id == u.id ? 0.6 : 0.4
            case .star: alpha = u.id == current ? 0.16 : 0.1
            }
            alpha *= born
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            // The glow reaches the real edge of the universe, so its visible size matches its size on the map.
            ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(stops: [.init(color: color.opacity(0.22 * alpha), location: 0),
                                 .init(color: color.opacity(0.12 * alpha), location: 0.6),
                                 .init(color: color.opacity(0.04 * alpha), location: 0.88),
                                 .init(color: .clear, location: 1)]),
                center: p, startRadius: 0, endRadius: r))
            if model.hoveredUniverse == u.id {
                // Hover: a soft haze that swells a little beyond the edge, no outline.
                let hr = r * 1.18
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - hr, y: p.y - hr, width: 2 * hr, height: 2 * hr)), with: .radialGradient(
                    Gradient(stops: [.init(color: color.opacity(0.16), location: 0),
                                     .init(color: color.opacity(0.10), location: 0.65),
                                     .init(color: .clear, location: 1)]),
                    center: p, startRadius: 0, endRadius: hr))
            }
        }
    }

    private func drawConstellations(_ ctx: inout GraphicsContext, universe uid: String, cam: Camera, toScreen: (CGPoint) -> CGPoint) {
        guard let u = cosmos.universe(uid) else { return }
        let color = Theme.color(forUniverse: u.id)
        // No outlines: every constellation is a soft haze around its own stars, so overlapping groups
        // simply blend into each other like real nebulae.
        let r = max(14, 15 * cam.scale)
        for c in u.constellations {
            for id in c.noteIDs {
                let p = toScreen(model.position(of: id, layout: layout, now: now))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.07), color.opacity(0.025), .clear]),
                                               center: p, startRadius: 0, endRadius: r))
            }
        }
    }

    /// Universe names on the overview. Each tries a few spots — inside near the bottom, under the edge,
    /// above the edge, to the right, to the left — and takes the first one that is free.
    private func drawUniverseLabels(_ ctx: inout GraphicsContext, cam: Camera, toScreen: (CGPoint) -> CGPoint, placer: inout LabelPlacer) {
        let order = cosmos.universes.sorted { $0.starCount > $1.starCount }
        for u in order {
            guard let c = model.universeCenter(u.id, now: now), let r0 = layout.universeRadius[u.id] else { continue }
            let shown = model.introUniverse(u.id, now: now) * model.historyUniverse(u.id, now: now)
            guard shown > 0.6 else { continue }
            let p = toScreen(c), r = r0 * cam.scale
            let color = Theme.color(forUniverse: u.id)
            let dim = model.hoveredUniverse != nil && model.hoveredUniverse != u.id
            let name = ctx.resolve(Text(u.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(color.opacity(dim ? 0.5 : 1)))
            let count = ctx.resolve(Text("\(u.starCount) \(plural(u.starCount, "звезда", "звезды", "звёзд"))")
                .font(Theme.mono(10)).foregroundStyle(Theme.muted.opacity(dim ? 0.5 : 1)))
            let ns = name.measure(in: CGSize(width: 600, height: 40)), cs = count.measure(in: CGSize(width: 600, height: 40))
            let w = max(ns.width, cs.width), h = ns.height + 2 + cs.height
            let candidates = [
                CGRect(x: p.x - w / 2, y: p.y + r * 0.74 - h / 2, width: w, height: h),
                CGRect(x: p.x - w / 2, y: p.y + r + 6, width: w, height: h),
                CGRect(x: p.x - w / 2, y: p.y - r - 6 - h, width: w, height: h),
                CGRect(x: p.x + r + 10, y: p.y - h / 2, width: w, height: h),
                CGRect(x: p.x - r - 10 - w, y: p.y - h / 2, width: w, height: h)
            ]
            var rect = candidates[0]
            if let free = candidates.first(where: { placer.tryPlace($0) }) { rect = free } else { placer.force(rect) }
            let pill = rect.insetBy(dx: -8, dy: -4)
            ctx.fill(Path(roundedRect: pill, cornerRadius: 10), with: .color(Theme.ground.opacity(0.55)))
            ctx.draw(name, at: CGPoint(x: rect.midX, y: rect.minY), anchor: .top)
            ctx.draw(count, at: CGPoint(x: rect.midX, y: rect.minY + ns.height + 2), anchor: .top)
        }
    }

    /// Inside a universe: the names of the neighbouring universes, quiet, so you know what's around.
    private func drawNeighbourNames(_ ctx: inout GraphicsContext, current: String, cam: Camera,
                                    toScreen: (CGPoint) -> CGPoint, placer: inout LabelPlacer) {
        for u in cosmos.universes where u.id != current {
            guard let c = model.universeCenter(u.id, now: now), let r0 = layout.universeRadius[u.id] else { continue }
            let p = toScreen(c), r = r0 * cam.scale
            guard p.x > -r, p.y > -r, p.x < size.width + r, p.y < size.height + r else { continue }
            let text = ctx.resolve(Text(u.name).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(universeColor(u.id).opacity(0.55)))
            let s = text.measure(in: CGSize(width: 600, height: 40))
            let at = CGPoint(x: p.x, y: p.y - r - 10)
            let rect = CGRect(x: at.x - s.width / 2, y: at.y - s.height, width: s.width, height: s.height)
            guard placer.tryPlace(rect) else { continue }
            ctx.draw(text, at: at, anchor: .bottom)
        }
    }

    /// Constellation names: above the circle, or below it if that spot is taken. Always shown.
    private func drawConstellationLabels(_ ctx: inout GraphicsContext, universe uid: String, cam: Camera,
                                         toScreen: (CGPoint) -> CGPoint, placer: inout LabelPlacer) {
        guard let u = cosmos.universe(uid) else { return }
        let color = Theme.color(forUniverse: u.id)
        for c in u.constellations.sorted(by: { $0.noteIDs.count > $1.noteIDs.count }) {
            guard let wc = model.constellationCenter(c.id, universe: u.id, now: now), let r0 = layout.constellationRadius[c.id] else { continue }
            let p = toScreen(wc), r = r0 * cam.scale
            let quiet = model.hoveredStar != nil
            let text = ctx.resolve(Text(c.name.uppercased()).font(Theme.mono(9.5)).kerning(1)
                .foregroundStyle(color.opacity(quiet ? 0.25 : 0.7)))
            let s = text.measure(in: CGSize(width: 600, height: 40))
            let above = CGRect(x: p.x - s.width / 2, y: p.y - r - 8 - s.height, width: s.width, height: s.height)
            let below = CGRect(x: p.x - s.width / 2, y: p.y + r + 8, width: s.width, height: s.height)
            var rect = above
            if !placer.tryPlace(above) {
                if placer.tryPlace(below) { rect = below } else { placer.force(above) }
            }
            let pill = rect.insetBy(dx: -8, dy: -3)
            ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(Theme.ground.opacity(quiet ? 0.2 : 0.45)))
            ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        }
    }

    private func drawOrbitRings(_ ctx: inout GraphicsContext, orbit: OrbitLayout, cam: Camera, toScreen: (CGPoint) -> CGPoint, alpha: Double) {
        guard alpha > 0.01, let origin = model.orbitOrigin(now: now) else { return }
        let o = toScreen(origin)
        for ring in orbit.rings {
            let appear = model.ringVisibility(ring.kind, now: now)
            guard appear > 0.01 else { continue }
            let fade = appear * (model.hoveredStar == nil ? 1 : 0.35)
            let r = ring.radius * cam.scale * (0.6 + 0.4 * appear)
            let circle = Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r))
            // Each orbit is a universe, drawn in that universe's colour.
            let tone = universeColor(ring.universeID).opacity((ring.kind == 1 ? 0.4 : 0.22) * fade)
            ctx.stroke(circle, with: .color(tone), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    /// Ring titles sit on the left side of each ring, stacked so they never touch each other.
    private func drawRingTitles(_ ctx: inout GraphicsContext, orbit: OrbitLayout, cam: Camera, toScreen: (CGPoint) -> CGPoint,
                                alpha: Double, placer: inout LabelPlacer) {
        guard alpha > 0.05, let origin = model.orbitOrigin(now: now) else { return }
        let o = toScreen(origin)
        let angle = -CGFloat.pi * 0.78            // upper-left, away from the usual crowd at the top
        for ring in orbit.visibleRings {
            // Ring titles hide while a star is looked at, so the route's names are the only text.
            let alpha = model.ringVisibility(ring.kind, now: now) * (model.hoveredStar == nil ? 1 : 0)
            guard alpha > 0.05 else { continue }
            let r = ring.radius * cam.scale * (0.6 + 0.4 * alpha)
            let label = ctx.resolve(Text("\(ring.kind) · \(ring.title)").font(Theme.mono(10))
                .foregroundStyle(universeColor(ring.universeID).opacity(0.9 * alpha)))
            let s = label.measure(in: CGSize(width: 400, height: 40))
            let at = CGPoint(x: o.x + r * cos(angle), y: o.y + r * sin(angle))
            let rect = CGRect(x: at.x - s.width / 2, y: at.y - s.height / 2, width: s.width, height: s.height)
            placer.force(rect)
            let pill = rect.insetBy(dx: -6, dy: -2)
            ctx.fill(Path(roundedRect: pill, cornerRadius: 6), with: .color(Theme.ground.opacity(0.85 * alpha)))
            ctx.draw(label, at: at, anchor: .center)
        }
    }

    private func drawEdges(_ ctx: inout GraphicsContext, screen: [String: CGPoint], focus: MapModel.Focus, orbit: OrbitLayout?, arranged: Double, hovered: String?) {
        for e in cosmos.edges {
            guard let pa = screen[e.a], let pb = screen[e.b] else { continue }
            let ua = cosmos.universeOf[e.a], ub = cosmos.universeOf[e.b]
            var alpha = 0.0, width: CGFloat = 1, dashed = false
            var color = ua == ub ? universeColor(ua) : Theme.ink

            switch focus {
            case .multiverse:
                if let h = model.hoveredUniverse { alpha = (ua == h || ub == h) ? 0.6 : 0.03 }
                else { alpha = ua == ub ? 0.26 : 0.12 }
            case .universe(let uid):
                if let h = hovered {
                    let incident = e.a == h || e.b == h
                    alpha = incident ? 0.95 : 0.025
                    if incident { width = 1.6; color = universeColor(cosmos.universeOf[e.a == h ? e.b : e.a]) }
                } else {
                    let ia = ua == uid, ib = ub == uid
                    alpha = ia && ib ? 0.45 : (ia || ib) ? 0.13 : (ua == ub ? 0.14 : 0.04)
                }
            case .star(let sid):
                // The cascade: lines from each star to the one it was reached through.
                let ra = e.a == sid ? 0 : orbit?.ringOf[e.a], rb = e.b == sid ? 0 : orbit?.ringOf[e.b]
                if let ra, let rb {
                    let isTree = orbit?.parent[e.a] == e.b || orbit?.parent[e.b] == e.a
                    // The "child" is the end further from the centre in link steps.
                    let da = e.a == sid ? 0 : orbit?.depth[e.a] ?? 9, db = e.b == sid ? 0 : orbit?.depth[e.b] ?? 9
                    let child = da > db ? e.a : e.b
                    let outer = max(1, max(da, db))
                    _ = (ra, rb)
                    color = universeColor(cosmos.universeOf[child])
                    if let h = hovered {
                        // Looking at one star: its route from the centre and its own links light up,
                        // everything else fades almost to nothing.
                        let chain = h == sid ? [] : (orbit?.path(to: h) ?? [])
                        let onRoute = isTree && chain.contains(child)
                        // The route is the brightest; the star's own links are lit a little softer.
                        let own = e.a == h || e.b == h
                        if onRoute { alpha = 1; width = 2.2 }
                        else if own { alpha = 0.55; width = 1.2; color = universeColor(cosmos.universeOf[e.a == h ? e.b : e.a]) }
                        else { alpha = 0.02 }
                    } else if isTree {
                        alpha = [0.85, 0.6, 0.42, 0.3][min(outer, 4) - 1] * OrbitLayout.fade(outer)
                        width = outer == 1 ? 1.4 : 1
                    } else {
                        // Extra links between already placed stars: barely there, so the cascade stays readable.
                        alpha = 0.06 * arranged * OrbitLayout.fade(outer); dashed = true
                    }
                } else {
                    alpha = 0.03 * (1 - arranged)
                }
            }
            if case .star = focus, let o = orbit {
                // A line appears together with the star at its outer end.
                let ra = o.ringOf[e.a] ?? 0, rb = o.ringOf[e.b] ?? 0
                if ra > 0 || rb > 0 { alpha *= model.starVisibility(ra >= rb ? e.a : e.b, now: now) }
            }
            if let h = hovered, let pk = model.peekStar, (e.a == h && e.b == pk) || (e.b == h && e.a == pk) {
                // The link between the pinned star and the one the mouse is on now.
                alpha = 1; width = 2.6; dashed = false
                color = universeColor(cosmos.universeOf[pk])
            }
            (alpha, width) = model.smoothed(edge: e, alpha: alpha, width: width)
            // On opening, a link draws itself from the star that lit up first.
            let grow = model.introEdge(e.a, e.b, now: now)
            guard grow.progress > 0.01 else { continue }
            // During the history playback a link appears once both of its stars exist.
            alpha *= min(model.historyAppear(e.a, now: now), model.historyAppear(e.b, now: now))
            guard alpha > 0.02 else { continue }
            var path = Path()
            let start = grow.fromA ? pa : pb, end = grow.fromA ? pb : pa
            let k = CGFloat(grow.progress)
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x + (end.x - start.x) * k, y: start.y + (end.y - start.y) * k))
            ctx.stroke(path, with: .color(color.opacity(alpha)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dashed ? [4, 3] : []))
        }
    }

    /// Draws the dots and returns the names that may be shown; `drawStarLabels` decides which fit.
    private func drawStars(_ ctx: inout GraphicsContext, screen: [String: CGPoint], focus: MapModel.Focus, orbit: OrbitLayout?,
                           arranged: Double, hovered: String?, hoverNeighbors: Set<String>, cam: Camera) -> [StarLabel] {
        var labels: [StarLabel] = []
        // Inside a universe star names appear only once the camera is close enough
        // for neighbouring stars to be a comfortable distance apart on screen.
        let zoomedIn = cam.scale * WorldLayout.starSpacing >= 26

        // Hovered star is drawn last so it sits on top.
        let ids = screen.keys.sorted { a, b in (a == hovered ? 1 : 0, a) < (b == hovered ? 1 : 0, b) }
        for id in ids {
            guard let p = screen[id] else { continue }
            let uid = cosmos.universeOf[id]
            let color = universeColor(uid)
            // Size grows with the logarithm of the number of links: every doubling of links adds the same step,
            // so hubs stand out while a note with 200 links doesn't swallow the map.
            // 0 links → 0.6, 1 → 1.0, 3 → 1.4, 7 → 1.8, 15 → 2.2, 31 → 2.6, 127+ → 3.4.
            let weight = 0.6 + 0.4 * min(log2(1 + CGFloat(cosmos.degree(id))), 7)
            var d: CGFloat = 4, alpha = 1.0, showLabel = false, bold = false, labelBoost = 0

            switch focus {
            case .multiverse:
                d = 2.2 * weight
                alpha = model.hoveredUniverse.map { $0 == uid ? 1 : 0.25 } ?? 0.85
            case .universe(let current):
                // Neighbouring universes stay visible (dimmer), so you can see where a swipe will take you.
                if uid != current { d = 3.2 * weight; alpha = 0.42 }
                else if let h = hovered {
                    let related = id == h || hoverNeighbors.contains(id)
                    d = (id == h ? 6.5 : 4.5) * weight; alpha = related ? 1 : 0.12
                    showLabel = id == h
                } else {
                    d = 4.5 * weight; showLabel = zoomedIn
                }
            case .star(let sid):
                if id == sid { d = 11 + 3 * weight; showLabel = true; bold = true }
                else if let ring = orbit?.ringOf[id] {
                    let onRoute = hovered.flatMap { h in h == sid ? nil : orbit?.path(to: h).contains(id) } ?? false
                    d = (id == hovered ? 10 : ([10, 8, 6.5, 5.5, 5, 4.5, 4, 3.5] as [CGFloat])[min(ring, 8) - 1]) * (0.7 + 0.3 * weight)
                    // Orbits 5–8 fade towards nothing; a star on the hovered route still shows up enough to read.
                    let steps = orbit?.depth[id] ?? 1
                    let base = [1, 0.85, 0.72, 0.6][min(steps, 4) - 1] * OrbitLayout.fade(steps)
                    alpha = onRoute ? max(0.6, base) : base
                    // In the cascade a star brightens as it reaches its orbit; on a replay it is hidden until it leaves.
                    let k = model.starVisibility(id, now: now)
                    alpha *= k
                    if hovered != nil {
                        // While a star is looked at: the route keeps its names, the star's own links stay lit
                        // without names, everything else dims and goes quiet.
                        let linked = hoverNeighbors.contains(id)
                        if onRoute { labelBoost = 100_000 }          // route names win over neighbours' names
                        if onRoute || id == hovered { alpha = max(alpha, 0.9) }
                        else if linked { alpha = max(alpha, 0.75) }
                        else { alpha *= 0.14 }
                        // Names: the route and everything the hovered star links to (those that fit without overlapping).
                        showLabel = onRoute || id == hovered || linked
                    } else {
                        // Names on the first orbit; on the second only while it is small enough to stay readable.
                        let secondCount = orbit?.rings.first(where: { $0.kind == 2 })?.count ?? 0
                        showLabel = (ring == 1 || (ring == 2 && secondCount <= 14)) && k > 0.6
                    }
                } else { d = 4; alpha = (0.3 - 0.24 * arranged) * (hovered == nil ? 1 : 0.4) }
            }
            // Hover and focus changes fade over a fraction of a second instead of snapping.
            if id == model.peekStar { alpha = 1; d = max(d, 10); showLabel = true; labelBoost = 200_000 }
            (alpha, d) = model.smoothed(star: id, alpha: alpha, size: d)
            let lit = model.introStar(id, now: now)
            if lit < 1 {
                // Each star kindles on its own: a quick swell of light that settles into a calm dot.
                alpha *= min(1, lit * 1.8)
                let flare = sin(.pi * lit)
                d *= 1 + 0.8 * CGFloat(flare)
                if lit > 0 {
                    let fr = d * 3.2
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - fr, y: p.y - fr, width: 2 * fr, height: 2 * fr)),
                             with: .radialGradient(Gradient(colors: [Color.white.opacity(0.35 * flare), color.opacity(0.18 * flare), .clear]),
                                                   center: p, startRadius: 0, endRadius: fr))
                }
            }
            let birth = model.historyAppear(id, now: now)
            alpha *= min(1, birth * 2)
            guard alpha > 0.01 else { continue }
            if birth < 1 {
                // A newborn star: a ring of light spreads from it as it joins its universe.
                let rr = d / 2 + 4 + 26 * CGFloat(birth)
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr)),
                           with: .color(color.opacity(0.7 * (1 - birth))), lineWidth: 1.2)
                showLabel = showLabel || birth > 0.15
            }

            let isHot = id == hovered || id == model.peekStar
            if isHot {
                for (k, a) in [(2.6, 0.16), (1.9, 0.26)] {
                    let rr = d * CGFloat(k) / 2 + 2
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(color.opacity(a)))
                }
            }
            let glow = d * 1.7
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: 2 * glow, height: 2 * glow)),
                     with: .radialGradient(Gradient(colors: [color.opacity(alpha * 0.35), .clear]), center: p, startRadius: 0, endRadius: glow))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)), with: .color(color.opacity(alpha)))
            if showLabel {
                labels.append(StarLabel(text: cosmos.title(id), point: CGPoint(x: p.x, y: p.y + d / 2 + 5),
                                        bold: bold, alpha: alpha, color: color, boxed: isHot, priority: cosmos.degree(id) + labelBoost))
            }
        }
        return labels
    }

    private func drawStarLabels(_ ctx: inout GraphicsContext, _ labels: [StarLabel], placer: inout LabelPlacer) {
        // Hovered and centre stars are always named. Then names that were already on screen keep their place
        // (with a little tolerance), so drifting stars don't make names swap and blink; then the rest by links.
        let rank: (StarLabel) -> Int = { $0.boxed ? 0 : $0.bold ? 1 : 2 }
        let shown = model.shownLabels
        let ordered = labels.sorted {
            (rank($0), shown.contains($0.text) ? 0 : 1, -$0.priority, $0.text)
                < (rank($1), shown.contains($1.text) ? 0 : 1, -$1.priority, $1.text)
        }
        var placed = Set<String>()
        var visible: [(label: StarLabel, text: GraphicsContext.ResolvedText, alpha: Double)] = []
        for l in ordered {
            let text = ctx.resolve(Text(l.text)
                .font(.system(size: l.bold ? 14 : 11.5, weight: l.bold ? .semibold : .regular))
                .foregroundStyle(Theme.ink.opacity(l.bold || l.boxed ? 1 : 0.8 * l.alpha)))
            let s = text.measure(in: CGSize(width: 400, height: 40))
            let rect = CGRect(x: l.point.x - s.width / 2, y: l.point.y, width: s.width, height: s.height)
            let ok: Bool
            if l.boxed || l.bold { placer.force(rect); ok = true }
            else if shown.contains(l.text) { ok = placer.tryPlace(rect.insetBy(dx: 8, dy: 3)) }
            else { ok = placer.tryPlace(rect) }
            if ok { placed.insert(l.text) }
            let a = (l.boxed || l.bold) ? 1 : model.labelFade(l.text, visible: ok)
            if a > 0.02 { visible.append((l, text, a)) }
        }
        model.shownLabels = placed
        // Draw the important ones last so they sit on top.
        for (l, text, a) in visible.reversed() {
            var c = ctx
            c.opacity = a
            if l.boxed {
                let s = text.measure(in: CGSize(width: 400, height: 40))
                let box = CGRect(x: l.point.x - s.width / 2 - 8, y: l.point.y - 2, width: s.width + 16, height: s.height + 6)
                let shape = Path(roundedRect: box, cornerRadius: box.height / 2)
                c.fill(shape, with: .color(Theme.ground.opacity(0.9)))
                c.stroke(shape, with: .color(l.color.opacity(0.8)), lineWidth: 1)
                c.draw(text, at: CGPoint(x: l.point.x, y: l.point.y + 1), anchor: .top)
            } else {
                c.draw(text, at: l.point, anchor: .top)
            }
        }
    }

    /// Constellation names on rings 3 and 4: outside the ring first, inside if that is taken.
    private func drawGroupLabels(_ ctx: inout GraphicsContext, orbit: OrbitLayout, cam: Camera, toScreen: (CGPoint) -> CGPoint,
                                 alpha: Double, placer: inout LabelPlacer) {
        guard alpha > 0.05, let origin = model.orbitOrigin(now: now) else { return }
        for g in orbit.groups {
            let c = cos(g.midAngle), s = sin(g.midAngle)
            let text = ctx.resolve(Text(g.title.uppercased()).font(Theme.mono(9.5)).kerning(0.8)
                .foregroundStyle(universeColor(g.universeID).opacity(0.9 * alpha)))
            let sz = text.measure(in: CGSize(width: 600, height: 40))
            func rect(atRadius r: CGFloat, outward: Bool) -> (CGRect, CGPoint, UnitPoint) {
                let p = toScreen(CGPoint(x: origin.x + r * c, y: origin.y + r * s))
                let anchor: UnitPoint
                if c > 0.35 { anchor = outward ? .leading : .trailing }
                else if c < -0.35 { anchor = outward ? .trailing : .leading }
                else { anchor = outward ? (s > 0 ? .top : .bottom) : (s > 0 ? .bottom : .top) }
                return (CGRect(x: p.x - sz.width * anchor.x, y: p.y - sz.height * anchor.y, width: sz.width, height: sz.height), p, anchor)
            }
            let options = [rect(atRadius: g.radius + 9, outward: true), rect(atRadius: g.radius - 9, outward: false),
                           rect(atRadius: g.radius + 20, outward: true)]
            guard let chosen = options.first(where: { placer.tryPlace($0.0) }) else { continue }
            ctx.draw(text, at: chosen.1, anchor: chosen.2)
        }
    }

    private func universeColor(_ id: String?) -> Color {
        Theme.color(forUniverse: id)
    }
}


/// A star name waiting to be placed.
struct StarLabel {
    let text: String
    let point: CGPoint
    let bold: Bool
    let alpha: Double
    let color: Color
    let boxed: Bool
    let priority: Int
}

/// Greedy label placement: a label is shown only if it does not touch one already placed.
struct LabelPlacer {
    private(set) var rects: [CGRect] = []

    mutating func tryPlace(_ rect: CGRect) -> Bool {
        let padded = rect.insetBy(dx: -4, dy: -2)
        if rects.contains(where: { $0.intersects(padded) }) { return false }
        rects.append(rect)
        return true
    }

    mutating func force(_ rect: CGRect) { rects.append(rect) }
}

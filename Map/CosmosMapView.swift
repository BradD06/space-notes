import SwiftUI

/// The map of the vault: multiverse → universe → a star with its orbits, all in one zoomable space.
struct CosmosMapView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model
    @State private var dragMode: DragMode?

    private enum DragMode {
        case pan
        case universe(String, start: CGVector)
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 760
            ZStack {
                TimelineView(.animation) { timeline in
                    Canvas { ctx, size in
                        model.lastSize = size
                        model.step(timeline.date)
                        MapRenderer(cosmos: vault.cosmos, model: model, now: timeline.date, size: size).draw(in: &ctx)
                    }
                }
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)
                .onTapGesture(coordinateSpace: .local) { handleTap(at: $0) }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point): handleHover(at: point)
                    case .ended: model.setHoveredStar(nil); model.setHoveredUniverse(nil)
                    }
                }
                .accessibilityLabel("Карта космоса")
            }
            .overlay(alignment: .top) { MapTopBar().padding(12) }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if compact, model.focusedStar != nil { FocusCard() }
                    TrailBar()
                }
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if !compact, model.focusedStar != nil {
                    if model.showFocusPanel {
                        // Ends above the trail bar so the two never overlap.
                        FocusPanel()
                            .frame(width: 310)
                            .padding(.top, 76)
                            .padding(.trailing, 12)
                            .padding(.bottom, 80)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        Button { model.showFocusPanel = true } label: {
                            Label("Связи", systemImage: "list.bullet.circle")
                        }
                        .buttonStyle(.glass)
                        .padding(.top, 76)
                        .padding(.trailing, 12)
                        .transition(.opacity)
                    }
                }
            }
            .animation(.smooth(duration: 0.35), value: model.focusedStar)
            .animation(.smooth(duration: 0.35), value: model.showFocusPanel)
        }
        .background(SpaceBackground())
        .task(id: vault.generation) {
            model.sync(with: vault.cosmos, generation: vault.generation)
            if let id = model.pendingStar {
                model.pendingStar = nil
                model.fly(to: id, cosmos: vault.cosmos)
            }
        }
        .onAppear {
            if let id = model.pendingStar {
                model.pendingStar = nil
                model.fly(to: id, cosmos: vault.cosmos)
            }
        }
    }

    // MARK: Gestures

    /// On the overview, dragging a universe moves it; dragging empty space (or any other level) pans the map.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragMode == nil {
                    if model.focus == .multiverse, case .universe(let id) = hit(at: value.startLocation) {
                        dragMode = .universe(id, start: model.offset(of: id))
                    } else {
                        dragMode = .pan
                    }
                }
                switch dragMode {
                case .universe(let id, let start):
                    let scale = model.camera(at: Date(), layout: model.layout, size: model.lastSize).scale
                    model.move(universe: id, to: CGVector(dx: start.dx + value.translation.width / scale,
                                                          dy: start.dy + value.translation.height / scale))
                    model.setHoveredUniverse(id)
                default:
                    model.pan = CGSize(width: model.panAtGestureStart.width + value.translation.width,
                                       height: model.panAtGestureStart.height + value.translation.height)
                }
            }
            .onEnded { _ in
                if case .universe = dragMode { model.finishMovingUniverse() } else { model.panAtGestureStart = model.pan }
                dragMode = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in model.zoom = min(4, max(0.4, model.zoomAtGestureStart * value.magnification)) }
            .onEnded { _ in model.zoomAtGestureStart = model.zoom }
    }

    // MARK: Hit testing

    private enum Hit {
        case star(String)
        case universe(String)
        case nothing
    }

    private func hit(at point: CGPoint) -> Hit {
        let cosmos = vault.cosmos
        let layout = model.layout
        let size = model.lastSize
        let now = Date()
        let cam = model.camera(at: now, layout: layout, size: size)
        let toScreen: (CGPoint) -> CGPoint = { p in
            CGPoint(x: (p.x - cam.center.x) * cam.scale + size.width / 2, y: (p.y - cam.center.y) * cam.scale + size.height / 2)
        }
        func nearestStar(in ids: [String], within limit: CGFloat) -> String? {
            var best: (String, CGFloat)?
            for id in ids {
                let p = toScreen(model.position(of: id, layout: layout, now: now))
                let d = hypot(p.x - point.x, p.y - point.y)
                if d < limit, d < (best?.1 ?? .infinity) { best = (id, d) }
            }
            return best?.0
        }
        func universe(at point: CGPoint) -> String? {
            cosmos.universes.first { u in
                guard let c = model.universeCenter(u.id, now: now), let r = layout.universeRadius[u.id] else { return false }
                let p = toScreen(c)
                return hypot(p.x - point.x, p.y - point.y) < r * cam.scale
            }?.id
        }

        switch model.focus {
        case .multiverse:
            return universe(at: point).map(Hit.universe) ?? .nothing
        case .universe(let uid):
            let ids = cosmos.universe(uid)?.constellations.flatMap(\.noteIDs) ?? []
            if let id = nearestStar(in: ids, within: 18) { return .star(id) }
            // A tap on an empty spot of a constellation focuses its brightest star.
            for c in cosmos.universe(uid)?.constellations ?? [] {
                guard let wc = model.constellationCenter(c.id, universe: uid, now: now), let r = layout.constellationRadius[c.id], let first = c.noteIDs.first else { continue }
                let p = toScreen(wc)
                if hypot(p.x - point.x, p.y - point.y) < r * cam.scale { return .star(first) }
            }
            if let other = universe(at: point), other != uid { return .universe(other) }
            return .nothing
        case .star:
            let orbitIDs = model.orbit.map { Array($0.position.keys) } ?? []
            if let id = nearestStar(in: orbitIDs, within: 20) { return .star(id) }
            return nearestStar(in: Array(layout.star.keys), within: 10).map(Hit.star) ?? .nothing
        }
    }

    private func handleTap(at point: CGPoint) {
        switch hit(at: point) {
        case .star(let id):
            if id == model.focusedStar { vault.selection = .note(id) }   // tapping the centre opens the note
            else { model.fly(to: id, cosmos: vault.cosmos) }
        case .universe(let id):
            model.go(to: .universe(id), cosmos: vault.cosmos, layout: model.layout)
        case .nothing:
            break
        }
    }

    private func handleHover(at point: CGPoint) {
        switch hit(at: point) {
        case .star(let id):
            model.setHoveredStar(id)
            model.setHoveredUniverse(nil)
        case .universe(let id):
            model.setHoveredStar(nil)
            model.setHoveredUniverse(model.focus == .multiverse ? id : nil)
        case .nothing:
            model.setHoveredStar(nil)
            model.setHoveredUniverse(nil)
        }
    }
}

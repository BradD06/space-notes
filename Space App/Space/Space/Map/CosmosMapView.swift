import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The map of the vault: multiverse → universe → a star with its orbits, all in one zoomable space.
struct CosmosMapView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model
    @State private var dragMode: DragMode?
    #if os(macOS)
    @State private var scrollMonitor: Any?
    @State private var scrollSpeed: CGSize = .zero
    @State private var ignoreMomentum = false
    #endif
    /// Set each time the map appears; the opening animation plays once the vault is loaded.
    @State private var introPending = true

    private enum DragMode {
        case pan
        case universe(String, start: CGVector)
        case star(String)
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 760
            ZStack {
                TimelineView(.animation) { timeline in
                    Canvas { ctx, size in
                        model.lastSize = size
                        model.step(timeline.date)
                        model.insights = InsightsCache.insights(vault)
                        MapRenderer(cosmos: vault.cosmos, model: model, now: timeline.date, size: size).draw(in: &ctx)
                    }
                }
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)
                .onTapGesture(coordinateSpace: .local) { handleTap(at: $0) }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point): model.pointerOverMap = true; handleHover(at: point)
                    case .ended: model.pointerOverMap = false; model.pointer(over: nil); model.setHoveredUniverse(nil)
                    }
                }
                .accessibilityLabel("Карта космоса")
            }
            .overlay(alignment: .top) { MapTopBar().padding(12) }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if compact, model.focusedStar != nil { FocusCard() }
                    if model.isPlayingHistory { HistoryBar().transition(.move(edge: .bottom).combined(with: .opacity)) }
                    TrailBar()
                }
                .padding(12)
            }
            .overlay(alignment: .topLeading) {
                if model.lens != nil {
                    HintsPanel()
                        .frame(width: compact ? nil : 300)
                        .padding(.top, 76).padding(.horizontal, 12).padding(.bottom, 80)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
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
            .animation(.smooth(duration: 0.35), value: model.isPlayingHistory)
            .animation(.smooth(duration: 0.35), value: model.lens)
        }
        .background(SpaceBackground())
        .task(id: vault.generation) {
            model.sync(with: vault.cosmos, generation: vault.generation)
            if let id = model.pendingStar {
                model.pendingStar = nil
                introPending = false
                model.fly(to: id, cosmos: vault.cosmos)
            } else if introPending, model.focus == .multiverse, !vault.cosmos.universes.isEmpty {
                introPending = false
                model.playIntro()
            }
        }
        #if os(macOS)
        .onAppear { startScrollMonitor() }
        .onDisappear { stopScrollMonitor() }
        #endif
        .onAppear {
            introPending = true
            if let id = model.pendingStar {
                model.pendingStar = nil
                model.fly(to: id, cosmos: vault.cosmos)
            }
        }
    }

    // MARK: Trackpad

    #if os(macOS)
    /// Two-finger scrolling on the trackpad moves the map (and a swipe flips to the next universe);
    /// a classic mouse wheel zooms.
    private func startScrollMonitor() {
        stopScrollMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard model.pointerOverMap else { return event }
            if event.hasPreciseScrollingDeltas {
                if event.phase == .began { model.catchGlide(); scrollSpeed = .zero; ignoreMomentum = false }
                // After a swipe has flipped to another universe, the trailing momentum must not drag the camera.
                if ignoreMomentum, event.momentumPhase != [] {
                    if event.momentumPhase == .ended { ignoreMomentum = false }
                    return nil
                }
                model.scrollPan(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
                // Remember the speed of the fingers to recognise a swipe when they lift.
                if event.phase == .changed {
                    scrollSpeed = CGSize(width: event.scrollingDeltaX * 60, height: event.scrollingDeltaY * 60)
                }
                if event.phase == .ended, model.swipe(velocity: scrollSpeed) {
                    ignoreMomentum = true
                    return nil
                }
                if event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase == []) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(60))
                        model.settle()
                    }
                }
            } else {
                model.wheelZoom(event.scrollingDeltaY)
            }
            return nil
        }
    }

    private func stopScrollMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }
    #endif

    // MARK: Gestures

    /// On the overview, dragging a universe moves it; dragging empty space (or any other level) pans the map.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragMode == nil {
                    model.catchGlide()
                    if model.focus == .multiverse, case .universe(let id) = hit(at: value.startLocation) {
                        dragMode = .universe(id, start: model.offset(of: id))
                    } else if case .universe = model.focus, case .star(let id) = hit(at: value.startLocation) {
                        dragMode = .star(id)
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
                case .star(let id):
                    let cam = model.camera(at: Date(), layout: model.layout, size: model.lastSize)
                    let world = CGPoint(x: (value.location.x - model.lastSize.width / 2) / cam.scale + cam.center.x,
                                        y: (value.location.y - model.lastSize.height / 2) / cam.scale + cam.center.y)
                    model.dragStar(id, to: world)
                default:
                    model.pan = CGSize(width: model.panAtGestureStart.width + value.translation.width,
                                       height: model.panAtGestureStart.height + value.translation.height)
                }
            }
            .onEnded { value in
                switch dragMode {
                case .universe: model.finishMovingUniverse()
                case .star: model.releaseStar()
                default:
                    model.panAtGestureStart = model.pan
                    model.endPan(velocity: value.velocity)
                }
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
            model.unpin()                     // a click on empty space releases the pinned star
        }
    }

    private func handleHover(at point: CGPoint) {
        switch hit(at: point) {
        case .star(let id):
            model.pointer(over: id)
            model.setHoveredUniverse(nil)
        case .universe(let id):
            model.pointer(over: nil)
            model.setHoveredUniverse(model.focus == .multiverse ? id : nil)
        case .nothing:
            model.pointer(over: nil)
            model.setHoveredUniverse(nil)
        }
    }
}

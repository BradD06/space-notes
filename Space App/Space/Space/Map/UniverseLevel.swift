import SwiftUI

/// Level 2, one universe: its constellations in reading order, sized by notes, with bands between them
/// that carry the number of links. Other universes wait at the edges as portals.
/// Named here: constellations, their main notes and their two most linked stars; any star on hover.
struct UniverseLevel: View {
    let group: Atlas.Group
    let atlas: Atlas
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model
    @State private var hovered: String?

    /// Constellations as they read: by name, the loose stars last.
    private var ordered: [Atlas.Constellation] {
        group.constellations.sorted { a, b in
            if (a.name == Cosmos.looseName) != (b.name == Cosmos.looseName) { return b.name == Cosmos.looseName }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let compact = size.width < 620
            let rect = CGRect(x: 24, y: 64, width: size.width - 48, height: size.height - 64 - (compact ? 44 : 64))
            let zones = AtlasLayout.zones(ordered, in: rect)
            let stars = Self.stars(zones, atlas: atlas)
            let insights = InsightsCache.insights(vault)
            let color = MapStyle.color(group.id, atlas: atlas)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(&ctx, zones: zones, stars: stars, color: color, insights: insights) }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { tap($0, zones: zones, stars: stars) }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let p): hovered = nearest(p, stars, within: 14)
                        case .ended: hovered = nil
                        }
                    }
                ForEach(zones, id: \.id) { zone in zoneTitle(zone, color: color) }
                bands(zones)
                labels(zones: zones, stars: stars, insights: insights)
                portals(compact: compact)
                if !compact {
                    MiniAtlas(atlas: atlas, current: group.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(4)
                }
            }
        }
    }

    // MARK: Geometry

    /// Every drawn star's place: spiralling out from the constellation's main note.
    static func stars(_ zones: [AtlasLayout.Zone], atlas: Atlas) -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        for z in zones {
            guard let c = atlas.constellation(z.id) else { continue }
            let pts = AtlasLayout.sunflower(count: c.shown.count, center: z.center, rx: z.radius * 0.84, ry: z.radius * 0.84, hasHead: c.head != nil)
            for (id, p) in zip(c.shown, pts) { out[id] = p }
        }
        return out
    }

    private func nearest(_ p: CGPoint, _ stars: [String: CGPoint], within limit: CGFloat) -> String? {
        var best: (String, CGFloat)?
        for (id, q) in stars {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < limit, d < (best?.1 ?? .infinity) { best = (id, d) }
        }
        return best?.0
    }

    private func tap(_ p: CGPoint, zones: [AtlasLayout.Zone], stars: [String: CGPoint]) {
        if let id = nearest(p, stars, within: 16) { model.go(to: .star(id)); return }
        if let z = zones.first(where: { hypot($0.center.x - p.x, $0.center.y - p.y) < $0.radius }) {
            withAnimation(.smooth(duration: 0.25)) { model.selectedConstellation = z.id }
        }
    }

    private var selected: String? { model.selectedConstellation ?? group.constellations.first?.id }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, zones: [AtlasLayout.Zone], stars: [String: CGPoint], color: Color, insights: Insights) {
        let cosmos = vault.cosmos
        for z in zones {
            let circle = Path(ellipseIn: CGRect(x: z.center.x - z.radius, y: z.center.y - z.radius, width: 2 * z.radius, height: 2 * z.radius))
            let on = z.id == selected
            ctx.fill(circle, with: .color(color.opacity(on ? 0.09 : 0.045)))
            ctx.stroke(circle, with: .color(color.opacity(on ? 0.55 : 0.28)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        // Bands between constellations: one line per pair, thicker with more links.
        for (b, p, q) in AtlasLayout.bands(atlas.innerBridges[group.id] ?? [], zones: zones) {
            var path = Path(); path.move(to: p); path.addLine(to: q)
            ctx.stroke(path, with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: min(7, 1 + CGFloat(b.count) * 0.5), lineCap: .round))
        }
        // Links inside a constellation only: what crosses over is already counted on the bands.
        var inner = Path()
        let focus = hovered
        var lit = Path()
        for (id, p) in stars {
            for n in cosmos.neighbors[id] ?? [] {
                guard let q = stars[n] else { continue }
                if focus == id || focus == n { lit.move(to: p); lit.addLine(to: q); continue }
                guard n > id, atlas.constellationOf[n] == atlas.constellationOf[id] else { continue }
                inner.move(to: p); inner.addLine(to: q)
            }
        }
        ctx.stroke(inner, with: .color(color.opacity(model.lens == nil && focus == nil ? 0.2 : 0.07)), lineWidth: 0.8)
        ctx.stroke(lit, with: .color(color.opacity(0.75)), lineWidth: 1.2)
        let neighbours = focus.flatMap { cosmos.neighbors[$0] } ?? []
        for z in zones {
            guard let c = atlas.constellation(z.id) else { continue }
            for id in c.shown {
                guard let p = stars[id] else { continue }
                var lens = model.lensMatches(id, insights)
                if focus != nil, lens == nil { lens = id == focus || neighbours.contains(id) }
                MapStars.draw(&ctx, id: id, at: p, color: color, cosmos: cosmos, lens: lens,
                              lensColor: model.lens.map(MapStyle.lensColor), head: id == c.head, selected: id == model.lastStar,
                              scale: 1.15)
            }
        }
    }

    // MARK: Names

    private func zoneTitle(_ z: AtlasLayout.Zone, color: Color) -> some View {
        let c = atlas.constellation(z.id)
        return VStack(spacing: 2) {
            Text(c?.name.isEmpty == false ? c!.name : group.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            Text(c.map { meta($0) } ?? "").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .lineLimit(1)
        .frame(width: max(140, z.radius * 2.4))
        .position(x: z.center.x, y: z.center.y - z.radius - 24)
        .onTapGesture { withAnimation(.smooth(duration: 0.25)) { model.selectedConstellation = z.id } }
    }

    private func meta(_ c: Atlas.Constellation) -> String {
        var parts = [c.shown.count < c.count ? "\(MapStyle.notes(c.count)) · видно \(c.shown.count)" : MapStyle.notes(c.count)]
        let forgotten = InsightsCache.insights(vault).forgotten.filter { atlas.constellationOf[$0] == c.id }.count
        if forgotten > 0 { parts.append("\(forgotten) \(plural(forgotten, "забытая", "забытые", "забытых"))") }
        return parts.joined(separator: " · ")
    }

    private func bands(_ zones: [AtlasLayout.Zone]) -> some View {
        let list = AtlasLayout.bands(atlas.innerBridges[group.id] ?? [], zones: zones).map { b, p, q in
            (b, CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2))
        }
        return ZStack(alignment: .topLeading) {
            ForEach(list, id: \.0) { b, at in
                CountPill(text: "\(b.count)", tint: MapStyle.color(group.id, atlas: atlas), mono: true).position(at)
            }
        }
        .allowsHitTesting(false)
    }

    /// Main notes always; the two most linked stars of each constellation when there is room; the star under the pointer.
    private func labels(zones: [AtlasLayout.Zone], stars: [String: CGPoint], insights: Insights) -> some View {
        let cosmos = vault.cosmos
        var placer = LabelPlacer()
        var out: [(id: String, at: CGPoint, bold: Bool)] = []
        func place(_ id: String, bold: Bool = false, force: Bool = false) {
            guard let p = stars[id], !out.contains(where: { $0.id == id }) else { return }
            let w = min(220, CGFloat(cosmos.title(id).count) * 6.3 + 16)
            let below = CGRect(x: p.x - w / 2, y: p.y + 9, width: w, height: 18)
            let above = below.offsetBy(dx: 0, dy: -36)
            for r in [below, above] where force || placer.tryPlace(r) {
                if force { placer.force(r) }
                out.append((id, CGPoint(x: r.midX, y: r.midY), bold))
                return
            }
        }
        if let h = hovered { place(h, bold: true, force: true) }
        if let s = model.lastStar, atlas.groupOf[s] == group.id { place(s, bold: true, force: true) }
        for z in zones { if let head = atlas.constellation(z.id)?.head { place(head) } }
        for z in zones {
            guard let c = atlas.constellation(z.id), z.radius > 50 else { continue }
            for id in c.shown.filter({ $0 != c.head && cosmos.degree($0) >= 3 }).prefix(2) { place(id) }
        }
        if model.lens != nil {
            for id in stars.keys.sorted() where model.lensMatches(id, insights) == true { place(id) }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(out, id: \.id) { l in
                StarName(text: cosmos.title(l.id), color: l.bold ? Theme.ink : Theme.ink.opacity(0.86), bold: l.bold).position(l.at)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Portals to other universes

    private func portals(compact: Bool) -> some View {
        let slots = Self.portalSlots(for: group.id, atlas: atlas, skipBottomLeading: !compact)
        return ZStack {
            ForEach(slots, id: \.groupID) { slot in
                if let g = atlas.group(slot.groupID) {
                    Button { model.go(to: .universe(g.id)) } label: {
                        HStack(spacing: 7) {
                            Text(slot.arrow).fontWeight(.semibold)
                            Text(g.name).lineLimit(1)
                            Text(MapStyle.links(slot.count)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 13).frame(height: 32)
                        .background(Capsule().fill(Color(hex: 0x17171A).opacity(0.9)))
                        .overlay(Capsule().strokeBorder(MapStyle.color(g.id, atlas: atlas).opacity(0.55), lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .tip("Перейти во вселенную «\(g.name)»")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slot.alignment)
                }
            }
        }
        .padding(.vertical, 2)
    }

    struct Portal {
        let groupID: String
        let count: Int
        let alignment: Alignment
        let arrow: String
    }

    /// Up to six linked universes, each at the edge that faces where it lies on the atlas.
    static func portalSlots(for gid: String, atlas: Atlas, skipBottomLeading: Bool) -> [Portal] {
        let regions = AtlasLayout.regions(atlas, in: CGRect(x: 0, y: 0, width: 1000, height: 700))
        let center = Dictionary(uniqueKeysWithValues: regions.map { ($0.groupID, CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
        guard let here = center[gid] else { return [] }
        // Clockwise from the right.
        let slots: [(Alignment, String)] = [(.trailing, "→"), (.bottomTrailing, "↘"), (.bottom, "↓"), (.bottomLeading, "↙"),
                                            (.leading, "←"), (.topLeading, "↖"), (.top, "↑"), (.topTrailing, "↗")]
        var taken = Set<Int>()
        if skipBottomLeading { taken.insert(3) }
        // The right edge is next to the side panel's content; keep it for when the others are full.
        var out: [Portal] = []
        for b in atlas.bridges(of: gid).prefix(6) {
            let other = b.other(than: gid)
            guard let there = center[other] else { continue }
            let angle = atan2(Double(there.y - here.y), Double(there.x - here.x))
            var slot = Int(((angle < 0 ? angle + 2 * .pi : angle) / (2 * .pi) * 8).rounded()) % 8
            var tries = 0
            while taken.contains(slot), tries < 8 { slot = (slot + 1) % 8; tries += 1 }
            guard !taken.contains(slot) else { break }
            taken.insert(slot)
            out.append(Portal(groupID: other, count: b.count, alignment: slots[slot].0, arrow: slots[slot].1))
        }
        return out
    }
}

/// Keeps names from landing on each other: a name is placed only where nothing is yet.
struct LabelPlacer {
    private var rects: [CGRect] = []

    mutating func tryPlace(_ rect: CGRect) -> Bool {
        guard !rects.contains(where: { $0.insetBy(dx: -3, dy: -1).intersects(rect) }) else { return false }
        rects.append(rect)
        return true
    }

    mutating func force(_ rect: CGRect) { rects.append(rect) }
}

/// The atlas in miniature, with the current universe lit: a tap goes back to it.
struct MiniAtlas: View {
    let atlas: Atlas
    let current: String
    @Environment(MapModel.self) private var model

    var body: some View {
        let size = CGSize(width: 168, height: 96)
        let regions = AtlasLayout.regions(atlas, in: CGRect(origin: .zero, size: size))
        Button { model.go(to: .multiverse) } label: {
            ZStack(alignment: .topLeading) {
                ForEach(regions, id: \.groupID) { r in
                    let color = MapStyle.color(r.groupID, atlas: atlas)
                    let on = r.groupID == current
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.opacity(on ? 0.55 : 0.22))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? color : .clear, lineWidth: 2))
                        .frame(width: max(2, r.frame.width - 2), height: max(2, r.frame.height - 2))
                        .offset(x: r.frame.minX + 1, y: r.frame.minY + 1)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x17171A).opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .tip("Все вселенные")
    }
}

// MARK: - The universe side panel: one constellation and its notes

struct UniversePanel: View {
    let group: Atlas.Group
    let atlas: Atlas
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model
    @State private var showAll = false

    var body: some View {
        let c = (model.selectedConstellation.flatMap { atlas.constellation($0) }).flatMap { $0.groupID == group.id ? $0 : nil }
            ?? group.constellations.first
        let color = MapStyle.color(group.id, atlas: atlas)
        VStack(alignment: .leading, spacing: 14) {
            if let c {
                VStack(alignment: .leading, spacing: 5) {
                    PanelHeading(text: c.name.isEmpty ? "Звёзды" : "Созвездие")
                    Text(c.name.isEmpty ? group.name : c.name).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                    Text(meta(c)).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                if group.constellations.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(group.constellations) { other in
                                Button { withAnimation(.smooth(duration: 0.25)) { model.selectedConstellation = other.id; showAll = false } } label: {
                                    Text(other.name.isEmpty ? "все" : other.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        .padding(.horizontal, 10).frame(height: 26)
                                        .background(Capsule().fill(other.id == c.id ? color.opacity(0.22) : Color.white.opacity(0.05)))
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let list = showAll ? c.noteIDs : Array(c.noteIDs.prefix(10))
                        let top = c.noteIDs.first.map { vault.cosmos.degree($0) } ?? 1
                        ForEach(list, id: \.self) { id in
                            NoteBarRow(id: id, maxDegree: top, color: color, selected: id == model.lastStar)
                        }
                        if c.noteIDs.count > list.count {
                            Button("ещё \(MapStyle.notes(c.noteIDs.count - list.count))") { showAll = true }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                    }
                }
                .scrollIndicators(.never)
                if let target = model.lastStar.flatMap({ atlas.constellationOf[$0] == c.id ? $0 : nil }) ?? c.head ?? c.noteIDs.first {
                    Button { model.go(to: .star(target)) } label: {
                        Text("Орбита: \(vault.cosmos.title(target))").lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(20)
        .onChange(of: model.selectedConstellation) { showAll = false }
    }

    private func meta(_ c: Atlas.Constellation) -> String {
        var parts = [MapStyle.notes(c.count)]
        for b in (atlas.innerBridges[group.id] ?? []).filter({ $0.a == c.id || $0.b == c.id }).prefix(2) {
            let name = atlas.constellation(b.other(than: c.id))?.name ?? ""
            parts.append("\(MapStyle.links(b.count)) с «\(name)»")
        }
        return parts.joined(separator: " · ")
    }
}

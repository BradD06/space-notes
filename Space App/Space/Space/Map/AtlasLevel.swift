import SwiftUI

/// Level 1, the atlas: every universe is a region sized by its notes, with its constellations inside.
/// Only universes, constellations and the note each constellation turns around are named.
/// Links between universes are one band with a number, not hundreds of lines.
struct AtlasLevel: View {
    let atlas: Atlas
    @Environment(MapModel.self) private var model

    /// The picked universe grows and the others give way, so it reads at a glance.
    var body: some View {
        let focus = atlas.groups.count > 1 ? model.pickedGroup : nil
        AtlasBoard(atlas: atlas, boost: Boost(values: AtlasLayout.focusBoost(atlas, focused: focus)))
            .animation(.smooth(duration: 0.4), value: focus)
    }
}

/// How much each universe is grown, as something SwiftUI can animate frame by frame:
/// regions, stars and labels are all laid out again from the in-between value, so they move together.
struct Boost: VectorArithmetic {
    var values: [Double]

    static var zero: Boost { Boost(values: []) }

    static func + (a: Boost, b: Boost) -> Boost { combine(a, b, +) }
    static func - (a: Boost, b: Boost) -> Boost { combine(a, b, -) }

    /// Vectors of different lengths (zero is empty) are padded with zeros.
    private static func combine(_ a: Boost, _ b: Boost, _ op: (Double, Double) -> Double) -> Boost {
        let n = max(a.values.count, b.values.count)
        return Boost(values: (0..<n).map { op($0 < a.values.count ? a.values[$0] : 0, $0 < b.values.count ? b.values[$0] : 0) })
    }

    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

struct AtlasBoard: View, Animatable {
    let atlas: Atlas
    var boost: Boost
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model

    var animatableData: Boost {
        get { boost }
        set { boost = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let regions = AtlasLayout.regions(atlas, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 2, dy: 2),
                                              boost: boost.values.count == atlas.groups.count ? boost.values : nil)
            let frames = Dictionary(uniqueKeysWithValues: regions.map { ($0.groupID, $0.frame) })
            let insights = InsightsCache.insights(vault)
            ZStack(alignment: .topLeading) {
                // A click on empty space lets go of the picked universe.
                Color.clear.contentShape(Rectangle()).onTapGesture { model.pickedGroup = nil }
                ForEach(regions, id: \.groupID) { region in
                    if let g = atlas.group(region.groupID) { regionBox(g, region) }
                }
                Canvas { ctx, _ in
                    for region in regions {
                        // Stars stay inside their region, however small it is.
                        ctx.drawLayer { layer in
                            if dimmed(region.groupID) { layer.opacity = 0.25 }
                            layer.clip(to: Path(roundedRect: region.frame, cornerRadius: 22))
                            drawStars(&layer, region, insights)
                        }
                    }
                    drawHoverLinks(&ctx, frames)
                }
                .allowsHitTesting(false)
                ForEach(regions, id: \.groupID) { region in headLabels(region).opacity(dimmed(region.groupID) ? 0.3 : 1) }
                bridges(frames)
            }
        }
    }

    // MARK: Regions

    private func regionBox(_ g: Atlas.Group, _ region: AtlasLayout.Region) -> some View {
        let color = MapStyle.color(g.id, atlas: atlas)
        let hovered = model.hoveredGroup == g.id || model.pickedGroup == g.id
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(color.opacity(hovered ? 0.10 : 0.05))
            shape.strokeBorder(color.opacity(hovered ? 0.6 : 0.3), style: StrokeStyle(lineWidth: 1, dash: g.isOthers ? [5, 4] : []))
            VStack(alignment: .leading, spacing: 3) {
                Text(g.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(color).lineLimit(1)
                Text(meta(g)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.top, 13)
            ForEach(region.constellations, id: \.id) { box in
                if let c = atlas.constellation(box.id) { constellationBox(c, box.frame, origin: region.frame.origin, others: g.isOthers) }
            }
        }
        .frame(width: region.frame.width, height: region.frame.height)
        .contentShape(shape)
        // One click picks the universe, two open it.
        .onTapGesture(count: 2) { open(g) }
        .onTapGesture { pick(g) }
        .onHover { inside in model.hoveredGroup = inside ? g.id : (model.hoveredGroup == g.id ? nil : model.hoveredGroup) }
        .opacity(dimmed(g.id) ? 0.35 : 1)
        .offset(x: region.frame.minX, y: region.frame.minY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(g.name), \(meta(g))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(g) }
    }

    /// A constellation is a dashed box with its name and size; a double click opens the universe on it.
    @ViewBuilder
    private func constellationBox(_ c: Atlas.Constellation, _ frame: CGRect, origin: CGPoint, others: Bool) -> some View {
        let named = !c.name.isEmpty && frame.width > 70 && frame.height > 40
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(named ? 0.11 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if named {
                HStack(spacing: 5) {
                    Text(c.name).lineLimit(1)
                    Text(countText(c)).font(Theme.mono(10)).foregroundStyle(Theme.faint.opacity(1.6))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10).padding(.top, 8)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !others else { withAnimation(.smooth) { model.expandOthers = true }; return }
            model.go(to: .universe(c.groupID))
            model.selectedConstellation = c.id
        }
        .onTapGesture { if let g = atlas.group(c.groupID) { pick(g) } }
        .offset(x: frame.minX - origin.x, y: frame.minY - origin.y)
    }

    private func countText(_ c: Atlas.Constellation) -> String {
        c.shown.count < c.count ? "\(c.count.formatted()) · видно \(c.shown.count)" : "\(c.count)"
    }

    private func meta(_ g: Atlas.Group) -> String {
        if g.isOthers { return "\(MapStyle.notes(g.count)) · дважды нажмите, чтобы раскрыть" }
        var parts = [MapStyle.notes(g.count)]
        let named = g.constellations.filter { $0.name != Cosmos.looseName && !$0.name.isEmpty }.count
        if named > 0 { parts.append("\(named) \(plural(named, "созвездие", "созвездия", "созвездий"))") }
        if g.modified > .distantPast { parts.append("изменено " + RuDate.relative(g.modified)) }
        return parts.joined(separator: " · ")
    }

    private func pick(_ g: Atlas.Group) {
        model.pickedGroup = model.pickedGroup == g.id ? nil : g.id
    }

    /// While a universe is picked, the ones it has no links with step back.
    private func dimmed(_ id: String) -> Bool {
        guard let p = model.pickedGroup, p != id, atlas.group(p) != nil else { return false }
        return atlas.links(between: p, and: id) == 0
    }

    private func open(_ g: Atlas.Group) {
        if g.isOthers { withAnimation(.smooth) { model.expandOthers = true } }
        else { model.go(to: .universe(g.id)) }
    }

    // MARK: Stars

    /// Where the stars of a constellation box sit: below its title, spiralling out from its main note.
    static func starPoints(_ c: Atlas.Constellation, in frame: CGRect) -> [CGPoint] {
        let top: CGFloat = c.name.isEmpty ? 8 : 30
        let area = CGRect(x: frame.minX + 14, y: frame.minY + top, width: frame.width - 28, height: frame.height - top - 12)
        guard area.width > 16, area.height > 16 else { return [] }
        return AtlasLayout.sunflower(count: c.shown.count, center: CGPoint(x: area.midX, y: area.midY),
                                     rx: area.width / 2, ry: area.height / 2, hasHead: c.head != nil)
    }

    private func drawStars(_ ctx: inout GraphicsContext, _ region: AtlasLayout.Region, _ insights: Insights) {
        let cosmos = vault.cosmos
        let color = MapStyle.color(region.groupID, atlas: atlas)
        for box in region.constellations {
            guard let c = atlas.constellation(box.id) else { continue }
            let points = Self.starPoints(c, in: box.frame)
            var at: [String: CGPoint] = [:]
            for (id, p) in zip(c.shown, points) { at[id] = p }
            // Links inside the constellation, faint: they show how tight it is, not who is who.
            var path = Path()
            var drawn = 0
            for id in c.shown where drawn < 160 {
                guard let p = at[id] else { continue }
                for n in cosmos.neighbors[id] ?? [] where n > id {
                    guard let q = at[n] else { continue }
                    path.move(to: p); path.addLine(to: q); drawn += 1
                }
            }
            ctx.stroke(path, with: .color(color.opacity(model.lens == nil ? 0.16 : 0.06)), lineWidth: 0.8)
            for (id, p) in zip(c.shown, points) {
                MapStars.draw(&ctx, id: id, at: p, color: color, cosmos: cosmos, lens: model.lensMatches(id, insights),
                              lensColor: model.lens.map(MapStyle.lensColor), head: id == c.head)
            }
        }
    }

    /// Hovering a universe shows where its links go, with the number on each band.
    private func drawHoverLinks(_ ctx: inout GraphicsContext, _ frames: [String: CGRect]) {
        guard let g = model.pickedGroup, let from = frames[g] else { return }
        let color = MapStyle.color(g, atlas: atlas)
        for b in atlas.bridges(of: g).prefix(8) {
            guard let to = frames[b.other(than: g)], AtlasLayout.sharedBorder(from, to) == nil else { continue }
            var path = Path()
            path.move(to: CGPoint(x: from.midX, y: from.midY))
            path.addLine(to: CGPoint(x: to.midX, y: to.midY))
            ctx.stroke(path, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 1 + min(4, log2(CGFloat(b.count))), lineCap: .round, dash: [6, 5]))
        }
    }

    // MARK: Labels

    private func headLabels(_ region: AtlasLayout.Region) -> some View {
        ForEach(region.constellations, id: \.id) { box in
            if let c = atlas.constellation(box.id), let head = c.head, box.frame.width > 90, box.frame.height > 70,
               let p = Self.starPoints(c, in: box.frame).first {
                StarName(text: vault.cosmos.title(head), maxWidth: box.frame.width - 16)
                    .position(x: p.x, y: p.y + 18)
                    .allowsHitTesting(false)
            }
        }
    }

    /// One pill per pair of neighbouring universes, sitting on the border between them.
    private func bridges(_ frames: [String: CGRect]) -> some View {
        let picked = model.pickedGroup
        let shown: [(Atlas.Bridge, CGPoint, CGPoint)] = atlas.bridges.compactMap { b in
            // With a universe picked, only its own links are counted on the borders.
            if let picked, b.a != picked, b.b != picked { return nil }
            guard let fa = frames[b.a], let fb = frames[b.b], let edge = AtlasLayout.sharedBorder(fa, fb) else { return nil }
            return (b, edge.0, edge.1)
        }
        let hovered = model.pickedGroup.map { g in atlas.bridges(of: g).prefix(8).filter { b in
            guard let fa = frames[b.a], let fb = frames[b.b] else { return false }
            return AtlasLayout.sharedBorder(fa, fb) == nil
        } } ?? []
        return ZStack(alignment: .topLeading) {
            ForEach(shown, id: \.0) { b, p, q in
                CountPill(text: MapStyle.links(b.count))
                    .position(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
            }
            ForEach(hovered, id: \.self) { b in
                if let fa = frames[b.a], let fb = frames[b.b] {
                    CountPill(text: MapStyle.links(b.count)).position(x: (fa.midX + fb.midX) / 2, y: (fa.midY + fb.midY) / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Drawing stars, shared by the atlas and the universe

enum MapStars {
    /// A star: size from its links, brightness from how recently it was touched, a dashed ring when it has no links.
    @MainActor
    static func draw(_ ctx: inout GraphicsContext, id: String, at p: CGPoint, color: Color, cosmos: Cosmos,
                     lens: Bool?, lensColor: Color?, head: Bool = false, selected: Bool = false, scale: CGFloat = 1) {
        let degree = cosmos.degree(id)
        var r = (head ? 6 : MapStyle.radius(degree)) * scale
        if selected { r = max(r, 7) }
        var alpha = MapStyle.freshness(cosmos.notes[id]?.modified)
        if lens == false { alpha *= 0.22 }
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        if degree == 0 && !head {
            let ring = CGRect(x: p.x - 3.5 * scale, y: p.y - 3.5 * scale, width: 7 * scale, height: 7 * scale)
            ctx.stroke(Path(ellipseIn: ring), with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: 1, dash: [2, 1.6]))
        } else {
            if head || selected || r > 3.5 {
                let glow = rect.insetBy(dx: -r * 1.6, dy: -r * 1.6)
                ctx.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [color.opacity(0.35 * alpha), .clear]),
                                                                       center: p, startRadius: 0, endRadius: r * 2.6))
            }
            ctx.fill(Path(ellipseIn: rect), with: .color((selected ? Color.white : color).opacity(alpha)))
            if head || selected {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.3)), lineWidth: 3)
            }
        }
        if lens == true, let lensColor {
            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(lensColor.opacity(0.9)), lineWidth: 1.5)
        }
    }
}

/// A star's name on the map: always horizontal, on a dark plate so it reads over anything.
struct StarName: View {
    let text: String
    var maxWidth: CGFloat = 220
    var color: Color = Theme.ink.opacity(0.88)
    var bold = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: bold ? .semibold : .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
            .frame(maxWidth: maxWidth)
    }
}

/// The number of links on a band between two places.
struct CountPill: View {
    let text: String
    var tint: Color = .white
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? Theme.mono(11) : .system(size: 11, weight: .medium))
            .foregroundStyle(Theme.ink.opacity(0.9))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(Color(hex: 0x17171A)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
            .fixedSize()
    }
}

// MARK: - The atlas side panel

struct AtlasPanel: View {
    let atlas: Atlas
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model

    var body: some View {
        let hints = InsightsCache.insights(vault)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !atlas.isTiny { groupingPicker }
                if !atlas.isTiny {
                    VStack(alignment: .leading, spacing: 12) {
                        PanelHeading(text: groupsTitle)
                        let biggest = atlas.groups.map(\.count).max() ?? 1
                        ForEach(atlas.groups) { g in summaryRow(g, biggest: biggest, hints: hints) }
                    }
                }
                if let lens = model.lens { lensList(lens, hints) } else { attention(hints) }
                legend
            }
            .padding(20)
        }
        .scrollIndicators(.never)
    }

    private var groupingPicker: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            PanelHeading(text: "Группировать по")
            Picker("Группировать по", selection: Binding(
                get: { atlas.grouping },
                set: { g in withAnimation(.smooth) { model.grouping = g; model.expandOthers = false } })) {
                ForEach(Atlas.Grouping.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(groupingNote).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if model.grouping != nil, model.grouping != atlas.automatic {
                Button("Как предлагает Space: \(atlas.automatic.title.lowercased())") { withAnimation(.smooth) { model.grouping = nil } }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
            }
        }
    }

    private var groupsTitle: String {
        switch atlas.grouping {
        case .folders: "Вселенные"
        case .tags: "Теги"
        case .clusters: "Кластеры"
        }
    }

    private var groupingNote: String {
        var text: String = switch atlas.grouping {
        case .folders: "Вселенные — папки верхнего уровня, созвездия — папки внутри."
        case .tags: "Каждая заметка — под своим самым частым тегом, созвездия — вложенные теги."
        case .clusters: "Группы найдены по ссылкам: заметки, которые чаще ссылаются друг на друга. Названы по главной заметке."
        }
        if atlas.foldedCount > 0 { text += " Мелкие группы (меньше 2% заметок) собраны в «\(atlas.grouping.more(atlas.foldedCount))»." }
        if atlas.groups.contains(where: { $0.constellations.contains { $0.shown.count < $0.count } }) {
            text += " В больших группах нарисованы самые связанные звёзды, остальные — числом."
        }
        return text
    }

    private func summaryRow(_ g: Atlas.Group, biggest: Int, hints: Insights) -> some View {
        let color = MapStyle.color(g.id, atlas: atlas)
        return Button {
            model.pickedGroup = model.pickedGroup == g.id ? nil : g.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(g.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(g.count.formatted()).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
                .font(.system(size: 13))
                Capsule().fill(Color.white.opacity(0.07)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(color).frame(width: max(3, geo.size.width * CGFloat(g.count) / CGFloat(max(biggest, 1))), height: 3)
                        }
                    }
                Text(note(g, hints)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if g.isOthers { withAnimation(.smooth) { model.expandOthers = true } } else { model.go(to: .universe(g.id)) }
        })
        .contextMenu {
            if atlas.colorsFollowUniverses, !g.isOthers {
                Menu("Цвет") {
                    ForEach(UniverseColors.swatches) { s in
                        Button { UniverseColors.shared.set(s.hex, for: g.id) } label: {
                            Label { Text(s.name) } icon: { swatchImage(s.hex) }
                        }
                    }
                }
            }
        }
    }

    private func note(_ g: Atlas.Group, _ hints: Insights) -> String {
        if g.isOthers { return "мелкие группы" }
        var parts: [String] = []
        if g.modified > .distantPast { parts.append(RuDate.relative(g.modified)) }
        let ids = Set(g.noteIDs)
        let orphans = hints.orphans.filter(ids.contains).count
        let forgotten = hints.forgotten.filter(ids.contains).count
        let pairs = hints.suggestions.filter { ids.contains($0.a) && ids.contains($0.b) }.count
        let reach = atlas.bridges(of: g.id).count
        if pairs > 0 { parts.append("\(pairs) можно связать") }
        if forgotten > 0 { parts.append("\(forgotten) \(plural(forgotten, "забытая", "забытые", "забытых"))") }
        if orphans > 0 { parts.append("\(orphans) \(plural(orphans, "сирота", "сироты", "сирот"))") }
        if reach > 0, parts.count < 3 { parts.append("ведёт в \(reach)") }
        return parts.joined(separator: " · ")
    }

    /// What needs a look, in plain words, each line one click from the place it talks about.
    @ViewBuilder
    private func attention(_ hints: Insights) -> some View {
        let items = attentionItems(hints)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                PanelHeading(text: "Требует внимания")
                ForEach(items, id: \.text) { item in
                    Button(action: item.action) {
                        Text(item.text).font(.system(size: 13)).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private struct Item { let text: String; let action: () -> Void }

    private func attentionItems(_ hints: Insights) -> [Item] {
        var items: [Item] = []
        // The universe with most pairs to link, the one with most orphans, the one with most forgotten notes.
        func top(_ count: (Set<String>) -> Int) -> (Atlas.Group, Int)? {
            atlas.groups.filter { !$0.isOthers }.map { ($0, count(Set($0.noteIDs))) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
        }
        if let (g, n) = top({ ids in hints.suggestions.filter { ids.contains($0.a) && ids.contains($0.b) }.count }) {
            items.append(Item(text: "\(n) \(plural(n, "пару", "пары", "пар")) заметок в «\(g.name)» стоит связать") {
                model.lens = .suggestions; model.go(to: .universe(g.id))
            })
        }
        if let (g, n) = top({ ids in hints.orphans.filter(ids.contains).count }) {
            items.append(Item(text: "\(n) \(plural(n, "заметка", "заметки", "заметок")) в «\(g.name)» без единой связи") {
                model.lens = .orphans; model.go(to: .universe(g.id))
            })
        }
        if let (g, n) = top({ ids in hints.forgotten.filter(ids.contains).count }) {
            items.append(Item(text: "\(n) \(plural(n, "заметка", "заметки", "заметок")) в «\(g.name)» давно не открывались") {
                model.lens = .forgotten; model.go(to: .universe(g.id))
            })
        }
        return items
    }

    private func lensList(_ lens: MapModel.Lens, _ hints: Insights) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeading(text: lens.title)
            Text(HintsText.explain(lens)).font(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
            switch lens {
            case .suggestions:
                if hints.suggestions.isEmpty { quiet("Пока нечего предложить: подсказки появятся, когда у заметок будут общие связи или теги.") }
                ForEach(hints.suggestions.prefix(30), id: \.self) { SuggestionRow(suggestion: $0) }
            case .orphans:
                if hints.orphans.isEmpty { quiet("Сирот нет: у каждой звезды есть хотя бы одна связь.") }
                ForEach(hints.orphans.prefix(40), id: \.self) { StarRow(id: $0, detail: place($0)) }
            case .forgotten:
                if hints.forgotten.isEmpty { quiet("Забытых нет: все связанные звёзды правились за последние два месяца.") }
                ForEach(hints.forgotten.prefix(40), id: \.self) { id in
                    StarRow(id: id, detail: vault.cosmos.notes[id].map { RuDate.relative($0.modified) } ?? "")
                }
            }
        }
    }

    private func place(_ id: String) -> String { atlas.groupOf[id].flatMap { atlas.group($0)?.name } ?? "" }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Theme.muted).padding(.vertical, 6)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 9) {
            PanelHeading(text: "Как читать")
            legendRow(Circle().fill(Theme.ink).frame(width: 10, height: 10), "размер звезды — число связей")
            legendRow(Circle().fill(Theme.ink.opacity(0.4)).frame(width: 8, height: 8), "тусклая — давно не открывали")
            legendRow(Circle().strokeBorder(Theme.muted, style: StrokeStyle(lineWidth: 1, dash: [2, 1.6])).frame(width: 8, height: 8),
                      "пунктир — нет ни одной связи")
            legendRow(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: 18, height: 12), atlas.grouping == .folders ? "рамка — созвездие (подпапка)" : "рамка — созвездие (подгруппа)")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.ink.opacity(0.75))
    }

    private func legendRow(_ mark: some View, _ text: String) -> some View {
        HStack(spacing: 10) { mark.frame(width: 22); Text(text) }
    }
}

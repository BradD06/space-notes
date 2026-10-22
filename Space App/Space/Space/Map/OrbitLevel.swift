import SwiftUI

/// Level 3, the orbit of one note, by meaning instead of rings:
/// on the left who links here, on the right where it leads, on top its neighbours in the constellation,
/// at the bottom what is worth linking. Every name is horizontal, in a column, and nothing overlaps:
/// each group shows five notes and "ещё N", and links to hubs fold into one chip.
struct OrbitLevel: View {
    let id: String
    let atlas: Atlas
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let orbit = NoteOrbit(center: id, cosmos: vault.cosmos, atlas: atlas, expanded: model.expandedSections, showHubs: model.showHubLinks)
        let suggestions = Array((InsightsCache.insights(vault).suggestionsFor[id] ?? [])
            .filter { !model.dismissed.contains(Cosmos.Edge($0.a, $0.b)) }.prefix(3))
        GeometryReader { geo in
            if geo.size.width >= 760 && geo.size.height >= 460 {
                wide(orbit, suggestions, size: geo.size)
            } else {
                narrow(orbit, suggestions)
            }
        }
    }

    // MARK: Wide: the four sides around the note

    private enum Line {
        case heading(String)
        case note(NoteOrbit.Row, groupID: String)
        case more(String, Int)
        case rest(Int)
    }

    private static func height(_ line: Line) -> CGFloat {
        switch line {
        case .heading: 28
        case .note: 25
        case .more, .rest: 24
        }
    }

    /// The column as lines, cut to the height there is; what doesn't fit is counted at the end.
    private func lines(_ sections: [NoteOrbit.Section], fit: CGFloat) -> [Line] {
        var out: [Line] = []
        var used: CGFloat = 0
        var left = sections.reduce(0) { $0 + $1.total }
        for s in sections {
            var block: [Line] = [.heading(s.total > s.rows.count ? "\(s.title) · \(s.total)" : s.title)]
            block += s.rows.map { .note($0, groupID: s.groupID) }
            if s.hidden > 0 { block.append(.more(s.id, s.hidden)) }
            let h = block.reduce(0) { $0 + Self.height($1) } + 6
            guard used + h <= fit - 24 || out.isEmpty else { break }
            out += block
            used += h
            left -= s.total
        }
        if left > 0 { out.append(.rest(left)) }
        return out
    }

    private func wide(_ orbit: NoteOrbit, _ suggestions: [Insights.Suggestion], size: CGSize) -> some View {
        let topH: CGFloat = orbit.hasSiblings || !orbit.hubLinks.isEmpty || orbit.isHub ? 112 : 24
        let bottomH: CGFloat = suggestions.isEmpty ? 16 : 156
        let area = CGRect(x: 0, y: topH + 34, width: size.width, height: size.height - topH - 34 - bottomH)
        let card = CGRect(x: size.width / 2 - 135, y: area.midY - 66, width: 270, height: 132)
        let dotL = card.minX - 90, dotR = card.maxX + 90
        let left = lines(orbit.incoming, fit: area.height), right = lines(orbit.outgoing, fit: area.height)
        let placed = { (list: [Line]) -> [(Line, CGFloat)] in
            let total = list.reduce(0) { $0 + Self.height($1) }
            var y = max(area.minY, area.midY - total / 2)
            return list.map { line in
                defer { y += Self.height(line) }
                return (line, y + Self.height(line) / 2)
            }
        }
        let pl = placed(left), pr = placed(right)
        let ownColor = MapStyle.color(ofNote: id, atlas: atlas)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for (line, y) in pl { if case .note(let row, let g) = line { connector(&ctx, dot: CGPoint(x: dotL, y: y), to: CGPoint(x: card.minX, y: card.midY), id: row.id, group: g) } }
                for (line, y) in pr { if case .note(let row, let g) = line { connector(&ctx, dot: CGPoint(x: dotR, y: y), to: CGPoint(x: card.maxX, y: card.midY), id: row.id, group: g) } }
                if topH > 30 {
                    var up = Path(); up.move(to: CGPoint(x: card.midX, y: card.minY)); up.addLine(to: CGPoint(x: card.midX, y: topH))
                    ctx.stroke(up, with: .color(ownColor.opacity(0.45)), lineWidth: 1)
                }
                for i in suggestions.indices {
                    let x = size.width / 2 + (CGFloat(i) - CGFloat(suggestions.count - 1) / 2) * 252
                    var down = Path(); down.move(to: CGPoint(x: card.midX, y: card.maxY)); down.addLine(to: CGPoint(x: x, y: size.height - bottomH + 30))
                    ctx.stroke(down, with: .color(MapStyle.lensColor(.suggestions).opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                }
            }
            .allowsHitTesting(false)

            // Each column's title sits right above its first line.
            columnTitle("Ссылаются сюда · \(orbit.incomingCount)", width: dotL - 24, alignment: .trailing)
                .position(x: (dotL - 24) / 2 + 8, y: (pl.first.map { $0.1 - Self.height($0.0) / 2 } ?? area.midY - 20) - 14)
            columnTitle("Ведёт отсюда · \(orbit.outgoingCount)", width: size.width - dotR - 24, alignment: .leading)
                .position(x: dotR + 14 + (size.width - dotR - 24) / 2, y: (pr.first.map { $0.1 - Self.height($0.0) / 2 } ?? area.midY - 20) - 14)
            if orbit.incoming.isEmpty { emptyColumn("Сюда пока никто не ссылается").position(x: (dotL - 24) / 2 + 8, y: area.midY) }
            if orbit.outgoing.isEmpty { emptyColumn("Ссылок отсюда нет").position(x: dotR + 14 + (size.width - dotR - 24) / 2, y: area.midY) }

            ForEach(Array(pl.enumerated()), id: \.offset) { _, item in
                lineView(item.0, alignment: .trailing).frame(width: dotL - 24, alignment: .trailing).position(x: (dotL - 24) / 2 + 8, y: item.1)
            }
            ForEach(Array(pr.enumerated()), id: \.offset) { _, item in
                lineView(item.0, alignment: .leading).frame(width: size.width - dotR - 24, alignment: .leading)
                    .position(x: dotR + 14 + (size.width - dotR - 24) / 2, y: item.1)
            }

            centerCard(orbit).frame(width: card.width, height: card.height).position(x: card.midX, y: card.midY)
            if topH > 30 { siblings(orbit).frame(width: min(size.width - 40, 640)).position(x: size.width / 2, y: topH / 2 + 4) }
            if !suggestions.isEmpty {
                suggestionsRow(suggestions).position(x: size.width / 2, y: size.height - bottomH / 2 + 8)
            }
        }
    }

    private func connector(_ ctx: inout GraphicsContext, dot: CGPoint, to: CGPoint, id other: String, group: String) {
        let color = MapStyle.color(group, atlas: atlas)
        var path = Path()
        path.move(to: dot)
        path.addCurve(to: to, control1: CGPoint(x: (dot.x + to.x) / 2, y: dot.y), control2: CGPoint(x: (dot.x + to.x) / 2, y: to.y))
        ctx.stroke(path, with: .color(color.opacity(0.28)), lineWidth: 1)
        let r: CGFloat = 4
        let rect = CGRect(x: dot.x - r, y: dot.y - r, width: 2 * r, height: 2 * r)
        ctx.fill(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .radialGradient(Gradient(colors: [color.opacity(0.45), .clear]), center: dot, startRadius: 0, endRadius: 9))
        ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(MapStyle.freshness(vault.cosmos.notes[other]?.modified))))
        if let m = vault.cosmos.notes[other]?.modified, Date.now.timeIntervalSince(m) < 2 * 86_400 {
            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.5)), lineWidth: 1.5)
        }
    }

    private func columnTitle(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.muted)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(width: max(0, width), alignment: alignment)
    }

    private func emptyColumn(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted)
    }

    @ViewBuilder
    private func lineView(_ line: Line, alignment: HorizontalAlignment) -> some View {
        switch line {
        case .heading(let title):
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 6)
        case .note(let row, let group):
            let other = group != atlas.groupOf[id]
            Button { model.go(to: .star(row.id)) } label: {
                HStack(spacing: 6) {
                    if row.mutual && alignment == .trailing { mutualMark }
                    Text(vault.cosmos.title(row.id)).lineLimit(1)
                    if row.mutual && alignment == .leading { mutualMark }
                }
                .font(.system(size: 13))
                .foregroundStyle(other ? MapStyle.color(group, atlas: atlas) : Theme.ink.opacity(0.9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { Button("Открыть заметку", systemImage: "doc.text") { vault.selection = .note(row.id) } }
        case .more(let section, let n):
            Button("ещё \(n) →") { withAnimation(.smooth(duration: 0.25)) { _ = model.expandedSections.insert(section) } }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent.opacity(0.9))
        case .rest(let n):
            Text("и ещё \(MapStyle.notes(n)) в других группах").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    private var mutualMark: some View {
        Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            .tip("Ссылаются друг на друга")
    }

    // MARK: The note itself

    private func centerCard(_ orbit: NoteOrbit) -> some View {
        let c = vault.cosmos
        let color = MapStyle.color(ofNote: id, atlas: atlas)
        let place = [atlas.groupOf[id].flatMap { atlas.group($0)?.name }, orbit.constellationTitle.isEmpty || orbit.constellationTitle == Cosmos.looseName ? nil : orbit.constellationTitle]
            .compactMap { $0 }.joined(separator: " · ")
        return Button { vault.selection = .note(id) } label: {
            VStack(spacing: 6) {
                Text(place).font(.system(size: 11)).foregroundStyle(color).lineLimit(1)
                Text(c.title(id)).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink).multilineTextAlignment(.center).lineLimit(2)
                HStack(spacing: 12) {
                    Text("\(orbit.incomingCount) входящих")
                    Text("\(orbit.outgoingCount) исходящих")
                    if let m = c.notes[id]?.modified { Text(RuDate.relative(m)) }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(color.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(color.opacity(0.55), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .tip("Открыть заметку")
    }

    // MARK: Top: neighbours in the constellation, hubs folded

    private func siblings(_ orbit: NoteOrbit) -> some View {
        let c = vault.cosmos
        return VStack(spacing: 8) {
            if orbit.hasSiblings {
                Text("В том же созвездии" + (orbit.constellationTitle.isEmpty ? "" : " · \(orbit.constellationTitle)"))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    if let p = orbit.previous { chip("← " + c.title(p)) { model.go(to: .star(p)) } }
                    if let h = orbit.head { chip(c.title(h), strong: true) { model.go(to: .star(h)) } }
                    if let n = orbit.next { chip(c.title(n) + " →") { model.go(to: .star(n)) } }
                }
            }
            if orbit.isHub {
                hubNote("Это хаб: в каждой группе показаны \(NoteOrbit.sectionLimit) самых свежих", action: "список целиком") {
                    withAnimation(.smooth(duration: 0.25)) {
                        model.expandedSections.formUnion((orbit.incoming + orbit.outgoing).map(\.id))
                    }
                }
            } else if !orbit.hubLinks.isEmpty {
                let names = orbit.hubLinks.prefix(2).map { "«\(c.title($0))»" }.joined(separator: " и ")
                hubNote("Через \(names) ещё \(MapStyle.notes(orbit.hubReach)) · свёрнуто", action: "показать") {
                    withAnimation(.smooth(duration: 0.25)) { model.showHubLinks = true }
                }
            }
        }
    }

    private func chip(_ text: String, strong: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: strong ? .semibold : .regular)).foregroundStyle(Theme.ink).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(Color.white.opacity(strong ? 0.10 : 0.05)))
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func hubNote(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.hexagongrid").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text(text).lineLimit(1).foregroundStyle(Theme.ink.opacity(0.8))
            Button(action, action: perform).buttonStyle(.plain).foregroundStyle(Theme.accent.opacity(0.9))
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.ink.opacity(0.8))
        .padding(.horizontal, 12).frame(height: 30)
        .background(Capsule().fill(Color.white.opacity(0.04)))
    }

    // MARK: Bottom: worth linking

    private func suggestionsRow(_ list: [Insights.Suggestion]) -> some View {
        VStack(spacing: 10) {
            Text("СТОИТ СВЯЗАТЬ · \(list.count)").font(.system(size: 11, weight: .semibold)).kerning(0.6)
                .foregroundStyle(MapStyle.lensColor(.suggestions))
            HStack(alignment: .top, spacing: 12) {
                ForEach(list, id: \.self) { s in suggestionCard(s).frame(width: 240) }
            }
        }
    }

    private func suggestionCard(_ s: Insights.Suggestion) -> some View {
        let other = s.other(than: id)
        return VStack(alignment: .leading, spacing: 6) {
            Button { model.go(to: .star(other)) } label: {
                Text(vault.cosmos.title(other)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            }
            .buttonStyle(.plain)
            Text(s.reason(vault.cosmos)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { vault.link(s, workspace: workspace) } label: { Label("Связать", systemImage: "link").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.glassProminent)
                    .tint(MapStyle.lensColor(.suggestions).opacity(0.7))
                Button("Не сейчас") { withAnimation(.smooth(duration: 0.25)) { _ = model.dismissed.insert(Cosmos.Edge(s.a, s.b)) } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(MapStyle.lensColor(.suggestions).opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    // MARK: Narrow: the same parts, one under another

    private func narrow(_ orbit: NoteOrbit, _ suggestions: [Insights.Suggestion]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                centerCard(orbit).frame(height: 128)
                if orbit.hasSiblings || orbit.isHub || !orbit.hubLinks.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { siblings(orbit) }
                }
                narrowColumn("Ссылаются сюда · \(orbit.incomingCount)", orbit.incoming)
                narrowColumn("Ведёт отсюда · \(orbit.outgoingCount)", orbit.outgoing)
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        PanelHeading(text: "Стоит связать · \(suggestions.count)")
                        ForEach(suggestions, id: \.self) { suggestionCard($0) }
                    }
                }
            }
            .padding(4)
        }
        .scrollIndicators(.never)
    }

    private func narrowColumn(_ title: String, _ sections: [NoteOrbit.Section]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeading(text: title)
            if sections.isEmpty { Text("Пока нет").font(.callout).foregroundStyle(Theme.muted) }
            ForEach(sections) { s in
                lineView(.heading(s.title), alignment: .leading)
                ForEach(s.rows, id: \.self) { row in
                    HStack(spacing: 8) {
                        Circle().fill(MapStyle.color(s.groupID, atlas: atlas)).frame(width: 7, height: 7)
                        lineView(.note(row, groupID: s.groupID), alignment: .leading)
                    }
                    .padding(.vertical, 3)
                }
                if s.hidden > 0 { lineView(.more(s.id, s.hidden), alignment: .leading) }
            }
        }
    }
}

// MARK: - The orbit side panel: preview, tags, how you got here

struct OrbitPanel: View {
    let id: String
    let atlas: Atlas
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model

    var body: some View {
        let c = vault.cosmos
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    PanelHeading(text: "Превью")
                    Text(c.title(id)).font(.system(size: 15, weight: .semibold))
                    let excerpt = NoteExcerpt.make(vault.text(of: id))
                    if !excerpt.isEmpty {
                        Text(excerpt).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.72)).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let tags = c.notes[id]?.tags, !tags.isEmpty {
                    FlowTags(tags: Array(tags.prefix(12)))
                }
                if atlas.hubs.contains(id) {
                    let orbit = NoteOrbit(center: id, cosmos: c, atlas: atlas)
                    VStack(alignment: .leading, spacing: 8) {
                        PanelHeading(text: "Кто ссылается, по группам")
                        ForEach(orbit.incoming.prefix(8)) { s in
                            HStack {
                                Text(s.title).lineLimit(1)
                                Spacer()
                                Text("\(s.total)").font(Theme.mono(12)).foregroundStyle(Theme.muted)
                            }
                            .font(.system(size: 13))
                        }
                    }
                }
                if model.trail.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        PanelHeading(text: "Как вы сюда пришли")
                        ForEach(Array(model.trail.enumerated()), id: \.element) { i, step in
                            Button { model.go(to: .star(step)) } label: {
                                HStack(spacing: 8) {
                                    Text("\(i + 1).").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    Text(c.title(step)).lineLimit(1)
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(step == id ? Theme.ink : Theme.ink.opacity(0.7))
                                .fontWeight(step == id ? .semibold : .regular)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                VStack(spacing: 8) {
                    Button { vault.selection = .note(id) } label: {
                        Label("Открыть заметку", systemImage: "doc.text").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    if let g = atlas.groupOf[id], !atlas.isTiny {
                        Button {
                            model.go(to: .universe(g))
                            model.selectedConstellation = atlas.constellationOf[id]
                        } label: {
                            Text(atlas.grouping == .folders ? "Показать во вселенной" : "Показать в группе").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.never)
    }
}

/// Tags as small chips that wrap onto the next line.
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { t in
                Text("#" + t).font(.system(size: 11)).padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
        }
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// The first lines of a note as plain text: no front matter, no markup.
enum NoteExcerpt {
    static func make(_ text: String, limit: Int = 280) -> String {
        var body = text
        if body.hasPrefix("---"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
            body = String(body[end.upperBound...])
        }
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("![[") && !$0.hasPrefix("|") }
            .map { line -> String in
                var s = line
                while s.hasPrefix("#") || s.hasPrefix(">") || s.hasPrefix("- ") || s.hasPrefix("* ") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
                for mark in ["[[", "]]", "**", "__", "`"] { s = s.replacingOccurrences(of: mark, with: "") }
                return s
            }
        let joined = lines.joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }
}

import SwiftUI

/// A vault of a few notes has no atlas: every star is on one screen with its name and how it is doing,
/// links are drawn, links worth making are dashed with the reason on them,
/// and a card says how the map will grow.
struct TinyMapView: View {
    let atlas: Atlas
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let cosmos = vault.cosmos
        let ids = cosmos.notes.keys.sorted()
        let hints = InsightsCache.insights(vault)
        let pairs = Array(hints.suggestions.filter { !model.dismissed.contains(Cosmos.Edge($0.a, $0.b)) }.prefix(6))
        GeometryReader { geo in
            let rect = CGRect(x: 110, y: 60, width: max(40, geo.size.width - 220), height: max(40, geo.size.height - 60 - 210))
            let at = AtlasLayout.spread(ids, cosmos: cosmos, in: rect)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for e in cosmos.edges {
                        guard let p = at[e.a], let q = at[e.b] else { continue }
                        var path = Path(); path.move(to: p); path.addLine(to: q)
                        ctx.stroke(path, with: .color(MapStyle.color(ofNote: e.a, atlas: atlas).opacity(0.6)), lineWidth: 1.6)
                    }
                    for s in pairs {
                        guard let p = at[s.a], let q = at[s.b] else { continue }
                        var path = Path(); path.move(to: p); path.addLine(to: q)
                        ctx.stroke(path, with: .color(MapStyle.lensColor(.suggestions).opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    }
                    for id in ids {
                        guard let p = at[id] else { continue }
                        MapStars.draw(&ctx, id: id, at: p, color: MapStyle.color(ofNote: id, atlas: atlas), cosmos: cosmos,
                                      lens: model.lensMatches(id, hints), lensColor: model.lens.map(MapStyle.lensColor),
                                      head: cosmos.degree(id) > 0, scale: 1.4)
                    }
                }
                .allowsHitTesting(false)
                ForEach(pairs, id: \.self) { s in
                    if let p = at[s.a], let q = at[s.b] {
                        CountPill(text: s.reason(cosmos), tint: MapStyle.lensColor(.suggestions))
                            .position(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                            .allowsHitTesting(false)
                    }
                }
                ForEach(ids, id: \.self) { id in
                    if let p = at[id] { star(id, cosmos: cosmos).position(x: p.x, y: p.y + 22) }
                }
                if ids.isEmpty {
                    Text("Здесь появятся звёзды, когда в хранилище будут заметки.")
                        .font(.callout).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                growCard(pairs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// The name under the star, and how it is doing: links and when it was touched. A tap opens its orbit.
    private func star(_ id: String, cosmos: Cosmos) -> some View {
        let d = cosmos.degree(id)
        let when = cosmos.notes[id].map { RuDate.relative($0.modified) } ?? ""
        return Button { model.go(to: .star(id)) } label: {
            VStack(spacing: 2) {
                Text(cosmos.title(id)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text((d == 0 ? "без связей" : MapStyle.links(d)) + " · " + when).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: 190)
            .padding(.top, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: 4)
    }

    private func growCard(_ pairs: [Insights.Suggestion]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Карта растёт вместе с заметками").font(.system(size: 16, weight: .semibold))
            Text("Наберите [[ в заметке, чтобы связать её с другой. Когда заметок станет больше \(Atlas.tinyLimit), звёзды соберутся в группы по папкам, тегам или ссылкам.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if !pairs.isEmpty {
                Button {
                    for s in pairs { vault.link(s, workspace: workspace) }
                } label: {
                    Label("Связать предложенные · \(pairs.count)", systemImage: "link")
                }
                .buttonStyle(.glassProminent)
                .tint(MapStyle.lensColor(.suggestions).opacity(0.7))
            }
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.bottom, 8)
    }
}

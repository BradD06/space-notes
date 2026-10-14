import SwiftUI

// MARK: - Top bar: where am I, search, back

struct MapTopBar: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        let cosmos = vault.cosmos
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    // Esc first clears an active search, then climbs: star → universe → multiverse.
                    if !model.searchText.isEmpty { model.searchText = ""; searchFocused = false }
                    else { model.up(cosmos: cosmos, layout: model.layout) }
                } label: {
                    Image(systemName: "chevron.up").frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .help("Уровнем выше (Esc)")
                .keyboardShortcut(.cancelAction)
                .disabled(model.focus == .multiverse && model.searchText.isEmpty)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                            if index > 0 { Text("/").foregroundStyle(Theme.faint) }
                            Button(crumb.title, action: crumb.action)
                                .buttonStyle(.plain)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .foregroundStyle(index == crumbs.count - 1 ? Theme.ink : Theme.muted)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 40)
                .glassEffect(.regular, in: .capsule)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Найти звезду…", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = results.first { fly(first) } }
                }
                .padding(.horizontal, 14)
                .frame(width: 240, height: 40)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results, id: \.self) { id in
                        Button { fly(id) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(color(of: id)).frame(width: 8, height: 8)
                                Text(cosmos.title(id)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(where_(id)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .frame(width: 320)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .offset(y: 48)
            }
        }
    }

    private struct Crumb { let title: String; let action: () -> Void }

    private var crumbs: [Crumb] {
        let cosmos = vault.cosmos
        var list = [Crumb(title: "Мультивселенная") { model.go(to: .multiverse, cosmos: cosmos, layout: model.layout) }]
        let universeID: String? = model.focusedUniverse ?? model.focusedStar.flatMap { cosmos.universeOf[$0] }
        if let uid = universeID, let u = cosmos.universe(uid) {
            list.append(Crumb(title: u.name) { model.go(to: .universe(uid), cosmos: cosmos, layout: model.layout) })
        }
        if let sid = model.focusedStar, let cid = cosmos.constellationOf[sid] {
            list.append(Crumb(title: cosmos.constellationName[cid] ?? "") {})
            list.append(Crumb(title: cosmos.title(sid)) { vault.selection = .note(sid) })
        }
        return list
    }

    private var results: [String] {
        let q = model.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return vault.cosmos.notes.values
            .filter { $0.title.lowercased().contains(q) }
            .sorted { ($0.title.lowercased().hasPrefix(q) ? 0 : 1, $0.title) < ($1.title.lowercased().hasPrefix(q) ? 0 : 1, $1.title) }
            .prefix(8).map(\.id)
    }

    private func fly(_ id: String) {
        model.searchText = ""
        searchFocused = false
        model.fly(to: id, cosmos: vault.cosmos)
    }

    private func color(of id: String) -> Color {
        Theme.color(forUniverseIndex: vault.cosmos.universeOf[id].flatMap { vault.cosmos.universeIndex[$0] } ?? 0)
    }

    private func where_(_ id: String) -> String {
        let c = vault.cosmos
        let u = c.universeOf[id].flatMap { c.universe($0)?.name } ?? ""
        let k = c.constellationOf[id].flatMap { c.constellationName[$0] } ?? ""
        return "\(u) › \(k)"
    }
}

// MARK: - Trail: last visited stars, one tap to go back

struct TrailBar: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text("ПУТЬ").font(Theme.mono(10)).kerning(1.4).foregroundStyle(Theme.muted)
            if model.trail.isEmpty {
                Text("здесь появятся звёзды, где ты побывал").font(.callout).foregroundStyle(Theme.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.trail.enumerated()), id: \.element) { index, id in
                        if index > 0 { Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.faint) }
                        Button { model.fly(to: id, cosmos: vault.cosmos) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(color(of: id)).frame(width: 7, height: 7)
                                Text(vault.cosmos.title(id)).lineLimit(1)
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.glass)
                        .tint(id == model.focusedStar ? color(of: id) : nil)
                    }
                }
            }
        }
        .padding(.leading, 18).padding(.trailing, 8)
        .frame(height: 52)
        .glassEffect(.regular, in: .capsule)
    }

    private func color(of id: String) -> Color {
        Theme.color(forUniverseIndex: vault.cosmos.universeOf[id].flatMap { vault.cosmos.universeIndex[$0] } ?? 0)
    }
}

// MARK: - Focus panel: the same orbits as a list

struct FocusPanel: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model

    var body: some View {
        let cosmos = vault.cosmos
        if let id = model.focusedStar, let orbit = model.orbit {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Spacer()
                        Button { model.showFocusPanel = false } label: {
                            Image(systemName: "sidebar.trailing").frame(width: 18, height: 18)
                        }
                        .buttonStyle(.glass)
                        .help("Скрыть панель")
                        .accessibilityLabel("Скрыть панель связей")
                    }
                    .padding(.bottom, -14)
                    FocusHeader(id: id)
                    ForEach(orbit.rings, id: \.kind) { ring in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("\(ring.kind)")
                                    .font(Theme.mono(11))
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(ring.kind == 1 ? Theme.accent : Theme.faint,
                                                                   style: StrokeStyle(lineWidth: 1, dash: ring.kind == 4 ? [3, 2] : [])))
                                    .foregroundStyle(ring.kind == 1 ? Theme.accent : Theme.ink)
                                Text("\(ring.title.uppercased()) · \(ring.count)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                            }
                            .padding(.bottom, 4)
                            ForEach(ids(in: ring.kind, orbit: orbit), id: \.self) { other in
                                Button { model.fly(to: other, cosmos: cosmos) } label: {
                                    HStack(spacing: 10) {
                                        Circle().fill(color(of: other)).frame(width: 8, height: 8)
                                        Text(cosmos.title(other)).lineLimit(1)
                                        Spacer(minLength: 6)
                                        if ring.kind >= 3 {
                                            Text(cosmos.constellationOf[other].flatMap { cosmos.constellationName[$0] } ?? "")
                                                .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 7).padding(.horizontal, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
    }

    private func ids(in kind: Int, orbit: OrbitLayout) -> [String] {
        if kind <= 2 { return orbit.ringOf.filter { $0.value == kind }.map(\.key).sorted { vault.cosmos.title($0) < vault.cosmos.title($1) } }
        return orbit.groups.filter { $0.kind == kind }.flatMap(\.noteIDs)
    }

    private func color(of id: String) -> Color {
        Theme.color(forUniverseIndex: vault.cosmos.universeOf[id].flatMap { vault.cosmos.universeIndex[$0] } ?? 0)
    }
}

/// Compact version for phones: title + open button above the trail.
struct FocusCard: View {
    @Environment(MapModel.self) private var model

    var body: some View {
        if let id = model.focusedStar {
            FocusHeader(id: id)
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }
}

struct FocusHeader: View {
    let id: String
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model

    var body: some View {
        let c = vault.cosmos
        VStack(alignment: .leading, spacing: 6) {
            Text(locationLine.uppercased()).font(Theme.mono(10)).kerning(1).foregroundStyle(Theme.muted)
            Text(c.title(id)).font(.system(size: 24, weight: .semibold, design: .serif))
            Text("\(c.degree(id)) \(plural(c.degree(id), "связь", "связи", "связей")) · \(model.orbit?.rings.count ?? 0) \(plural(model.orbit?.rings.count ?? 0, "орбита", "орбиты", "орбит"))")
                .font(.callout).foregroundStyle(Theme.muted)
            Button { vault.selection = .note(id) } label: {
                Label("Открыть заметку", systemImage: "doc.text").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.top, 6)
        }
    }

    private var locationLine: String {
        let c = vault.cosmos
        let u = c.universeOf[id].flatMap { c.universe($0)?.name } ?? ""
        let k = c.constellationOf[id].flatMap { c.constellationName[$0] } ?? ""
        return "\(u) › \(k)"
    }
}

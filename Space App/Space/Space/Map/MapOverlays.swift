import SwiftUI

// MARK: - Top bar: where am I, which level, what to light up, search

struct MapTopBar: View {
    let atlas: Atlas
    let compact: Bool
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            if compact {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        backButton
                        crumbsView
                        Button { model.showPanel.toggle() } label: {
                            Image(systemName: model.showPanel ? "info.circle.fill" : "info.circle").frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(model.showPanel ? "Скрыть подробности" : "Подробности")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { levels; lenses }
                    }
                    search(width: nil)
                }
            } else {
                // One row when it all fits; otherwise the lenses move to a second row instead of being squeezed empty.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        backButton
                        crumbsView.frame(minWidth: 160)
                        levels.fixedSize()
                        lenses.fixedSize()
                        search(width: 200)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            backButton
                            crumbsView.frame(minWidth: 120)
                            levels.fixedSize()
                            search(width: 200)
                        }
                        lenses.fixedSize()
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results, id: \.self) { id in
                        Button { fly(id) } label: {
                            HStack(spacing: 10) {
                                Circle().fill(MapStyle.color(ofNote: id, atlas: atlas)).frame(width: 8, height: 8)
                                Text(vault.cosmos.title(id)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(place(of: id)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
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
                .offset(y: compact ? 140 : 48)
            }
        }
    }

    private var backButton: some View {
        Button {
            // Esc first clears an active search, then climbs: note → universe → atlas.
            if !model.searchText.isEmpty { model.searchText = ""; searchFocused = false }
            else { model.up(atlas: atlas) }
        } label: {
            Image(systemName: "chevron.up").frame(width: 20, height: 20)
        }
        .buttonStyle(.glass)
        .tip("Уровнем выше (Esc)")
        .keyboardShortcut(.cancelAction)
        .disabled(model.focus == .multiverse && model.searchText.isEmpty)
    }

    private var crumbsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 { Text("/").foregroundStyle(Theme.faint) }
                    Button(crumb.title, action: crumb.action)
                        .buttonStyle(.plain)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 6)
                        .foregroundStyle(index == crumbs.count - 1 ? Theme.ink : Theme.muted)
                        .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 40)
        .glassEffect(.regular, in: .capsule)
    }

    /// Атлас / Вселенная / Орбита. A level you haven't been to yet is greyed out.
    @ViewBuilder
    private var levels: some View {
        if !atlas.isTiny {
            let universe = model.currentUniverse(atlas)
            let star = model.focusedStar ?? model.lastStar
            HStack(spacing: 2) {
                levelButton("Атлас", selected: model.focus == .multiverse, enabled: true) { model.go(to: .multiverse) }
                levelButton(atlas.grouping == .folders ? "Вселенная" : "Группа", selected: model.focusedUniverse != nil,
                            enabled: universe != nil) { if let universe { model.go(to: .universe(universe)) } }
                levelButton("Орбита", selected: model.focusedStar != nil, enabled: star != nil) { if let star { model.go(to: .star(star)) } }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func levelButton(_ title: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : 0)))
                .foregroundStyle(selected ? Theme.ink : Theme.muted)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    /// "Подсветить": the hint lenses, with how many stars each one lights up where you are.
    private var lenses: some View {
        let hints = InsightsCache.insights(vault)
        let scope: Set<String>? = model.focusedUniverse.flatMap { atlas.group($0) }.map { Set($0.noteIDs) }
        return HStack(spacing: 6) {
            Text("Подсветить:").font(.system(size: 12)).foregroundStyle(Theme.muted)
            ForEach(MapModel.Lens.allCases) { lens in
                let n = count(lens, hints, in: scope)
                let on = model.lens == lens
                Button { withAnimation(.smooth(duration: 0.25)) { model.lens = on ? nil : lens } } label: {
                    Text("\(lens.title) · \(n)")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11).frame(height: 30)
                        .foregroundStyle(on ? Theme.ink : Theme.muted)
                        .background(Capsule().fill(MapStyle.lensColor(lens).opacity(on ? 0.22 : 0)))
                        .overlay(Capsule().strokeBorder(on ? MapStyle.lensColor(lens).opacity(0.7) : Theme.line, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .tip(HintsText.explain(lens))
            }
        }
    }

    private func count(_ lens: MapModel.Lens, _ hints: Insights, in scope: Set<String>?) -> Int {
        let ids: [String] = switch lens {
        case .suggestions: Array(hints.suggestedSet)
        case .orphans: hints.orphans
        case .forgotten: hints.forgotten
        }
        guard let scope else { return lens == .suggestions ? hints.suggestions.count : ids.count }
        if lens == .suggestions { return hints.suggestions.filter { scope.contains($0.a) || scope.contains($0.b) }.count }
        return ids.filter(scope.contains).count
    }

    private func search(width: CGFloat?) -> some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField(searchPrompt, text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { if let first = results.first { fly(first) } }
        }
        .padding(.horizontal, 14)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(height: 40)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var searchPrompt: String {
        if let u = model.focusedUniverse, let g = atlas.group(u) { return "Найти в «\(g.name)»" }
        return model.focusedStar != nil ? "Перейти к звезде" : "Найти звезду"
    }

    private struct Crumb { let title: String; let action: () -> Void }

    private var crumbs: [Crumb] {
        let cosmos = vault.cosmos
        var list = [Crumb(title: atlas.isTiny ? vault.vaultName : "Все вселенные") { model.go(to: .multiverse) }]
        let gid: String? = model.focusedUniverse ?? model.focusedStar.flatMap { atlas.groupOf[$0] }
        if !atlas.isTiny, let gid, let g = atlas.group(gid) {
            list.append(Crumb(title: g.name) { model.go(to: .universe(gid)) })
        }
        if let sid = model.focusedStar {
            list.append(Crumb(title: cosmos.title(sid)) { vault.selection = .note(sid) })
        }
        return list
    }

    /// Search covers the universe you are in, or the whole vault.
    private var results: [String] {
        let q = model.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let scope = model.focusedUniverse.flatMap { atlas.group($0) }.map { Set($0.noteIDs) }
        return vault.cosmos.notes.values
            .filter { $0.title.lowercased().contains(q) && (scope?.contains($0.id) ?? true) }
            .sorted { ($0.title.lowercased().hasPrefix(q) ? 0 : 1, $0.title) < ($1.title.lowercased().hasPrefix(q) ? 0 : 1, $1.title) }
            .prefix(8).map(\.id)
    }

    private func fly(_ id: String) {
        model.searchText = ""
        searchFocused = false
        model.go(to: .star(id))
    }

    private func place(of id: String) -> String {
        let g = atlas.groupOf[id].flatMap { atlas.group($0)?.name } ?? ""
        let c = atlas.constellationOf[id].flatMap { atlas.constellation($0)?.name } ?? ""
        return c.isEmpty ? g : "\(g) › \(c)"
    }
}

// MARK: - Bits shared by the side panels

/// A small caps heading over a part of a side panel.
struct PanelHeading: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.muted)
    }
}

/// A note in a list of a side panel: its name, a bar of its links, the number.
struct NoteBarRow: View {
    let id: String
    let maxDegree: Int
    let color: Color
    var selected = false
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model

    var body: some View {
        let d = vault.cosmos.degree(id)
        Button { model.go(to: .star(id)) } label: {
            HStack(spacing: 10) {
                Text(vault.cosmos.title(id)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Capsule().fill(Color.white.opacity(0.08)).frame(width: 44, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: 44 * CGFloat(d) / CGFloat(max(maxDegree, 1)), height: 4)
                    }
                Text("\(d)").font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 24, alignment: .trailing)
            }
            .font(.system(size: 12))
            .foregroundStyle(selected ? Theme.ink : Theme.ink.opacity(0.85))
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? color.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Открыть заметку", systemImage: "doc.text") { vault.selection = .note(id) }
        }
    }
}

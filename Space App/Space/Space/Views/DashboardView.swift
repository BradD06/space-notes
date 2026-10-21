import SwiftUI
import UniformTypeIdentifiers

/// The vault's dashboard, where the app opens: its cover with the name and numbers on top, then an overview
/// of what needs attention (recent stars, hubs, links to make, orphans, forgotten stars), and below it
/// the dashboard page (".space/Dashboard.md") with whatever you put there — columns, blocks, links, tasks, quotes.
struct DashboardView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var map
    @AppStorage("space.dashboardOverview") private var showOverview = true
    @State private var pickingCover = false
    @State private var title = ""
    @FocusState private var editingTitle: Bool
    private let profile = VaultProfile.shared

    var body: some View {
        let cosmos = vault.cosmos
        VStack(spacing: 0) {
            VaultCover(name: vault.vaultName, stats: "", height: 190, big: true, showText: false)
                .overlay(alignment: .bottomLeading) { banner(cosmos) }
                .overlay(alignment: .topTrailing) { tools }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            overview
            if let url = profile.dashboardURL {
                NoteView(noteID: "dashboard", file: url).id(url)
            }
        }
        .background(SpaceBackground())
        .onAppear { title = profile.title }
        .onChange(of: profile.title) { _, t in if !editingTitle { title = t } }
        .fileImporter(isPresented: $pickingCover, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            do { try profile.setCover(from: url) } catch { vault.errorMessage = "Не удалось поставить обложку: \(error.localizedDescription)" }
        }
    }

    /// The dashboard's own name, right on the banner: click it and type to rename.
    private func banner(_ cosmos: Cosmos) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 3) {
                TextField(VaultProfile.defaultTitle, text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .focused($editingTitle)
                    .onSubmit { profile.setTitle(title); editingTitle = false }
                    .onChange(of: editingTitle) { _, on in if !on { profile.setTitle(title); title = profile.title } }
                    .tip("Нажми, чтобы переименовать дашборд")
                Text("\(vault.vaultName) · \(Self.stats(cosmos))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.5), radius: 6)
            .padding(22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    static func stats(_ c: Cosmos) -> String {
        let books = c.notes.keys.filter(Books.isBook).count
        let notes = c.notes.count - books
        var parts = ["\(notes) \(plural(notes, "звезда", "звезды", "звёзд"))",
                     "\(c.universes.count) \(plural(c.universes.count, "вселенная", "вселенные", "вселенных"))"]
        if books > 0 { parts.append("\(books) \(plural(books, "книга", "книги", "книг"))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Overview

    private var overview: some View {
        let hints = InsightsCache.insights(vault)
        let c = vault.cosmos
        return VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.smooth(duration: 0.3)) { showOverview.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showOverview ? 90 : 0))
                    Text("ОБЗОР").font(Theme.mono(10)).kerning(1.4)
                    if !showOverview { Text(summary(hints)).font(.caption) }
                }
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
            if showOverview {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        card("Недавние", "clock", Theme.accent, count: nil, lens: nil) {
                            ForEach(hints.recent.prefix(5), id: \.self) { id in
                                StarRow(id: id, detail: c.notes[id].map { RuDate.relative($0.modified) } ?? "", openNote: true)
                            }
                        }
                        card("Центры", "sun.max", Theme.ink, count: nil, lens: nil) {
                            if hints.hubs.isEmpty { quiet("Появятся, когда заметки свяжутся ссылками [[…]].") }
                            ForEach(hints.hubs.prefix(5), id: \.self) { id in
                                StarRow(id: id, detail: "\(c.degree(id)) \(plural(c.degree(id), "связь", "связи", "связей"))", openNote: true)
                            }
                        }
                        card("Связать", MapModel.Lens.suggestions.icon, MapRenderer.lensColor(.suggestions),
                             count: hints.suggestions.count, lens: .suggestions, width: 330) {
                            if hints.suggestions.isEmpty { quiet("Пока нечего предложить.") }
                            ForEach(hints.suggestions.prefix(4), id: \.self) { s in SuggestionRow(suggestion: s, openNote: true) }
                        }
                        card("Сироты", MapModel.Lens.orphans.icon, MapRenderer.lensColor(.orphans),
                             count: hints.orphans.count, lens: .orphans) {
                            if hints.orphans.isEmpty { quiet("Нет: у каждой звезды есть связь.") }
                            ForEach(hints.orphans.prefix(5), id: \.self) { id in
                                StarRow(id: id, detail: c.constellationOf[id].flatMap { c.constellationName[$0] } ?? "", openNote: true)
                            }
                        }
                        card("Забытые", MapModel.Lens.forgotten.icon, MapRenderer.lensColor(.forgotten),
                             count: hints.forgotten.count, lens: .forgotten) {
                            if hints.forgotten.isEmpty { quiet("Нет: всё связанное правилось недавно.") }
                            ForEach(hints.forgotten.prefix(5), id: \.self) { id in
                                StarRow(id: id, detail: c.notes[id].map { RuDate.relative($0.modified) } ?? "", openNote: true)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8).padding(.bottom, 4)
    }

    /// One overview card. The ones that are a lens of the map can open the map with that lens on.
    private func card<Content: View>(_ title: String, _ icon: String, _ color: Color, count: Int?, lens: MapModel.Lens?,
                                     width: CGFloat = 260, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.system(size: 14, weight: .semibold))
                if let count { Text("\(count)").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                Spacer(minLength: 4)
                if let lens {
                    Button {
                        map.lens = lens
                        vault.selection = .map
                    } label: {
                        Label("На карте", systemImage: "sparkles").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .tip("Открыть карту с этой подсказкой")
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 2)
            content()
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .frame(width: width, height: 196, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.muted).padding(.horizontal, 6).padding(.top, 4)
    }

    private func summary(_ h: Insights) -> String {
        var parts: [String] = []
        if !h.suggestions.isEmpty { parts.append("связать \(h.suggestions.count)") }
        if !h.orphans.isEmpty { parts.append("сирот \(h.orphans.count)") }
        if !h.forgotten.isEmpty { parts.append("забытых \(h.forgotten.count)") }
        return parts.joined(separator: " · ")
    }

    private var tools: some View {
        Button { pickingCover = true } label: {
            Label("Обложка", systemImage: "photo").font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 28)
                .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .tip("Выбрать картинку для обложки. Правый клик — убрать")
        .contextMenu {
            if profile.coverFile != nil { Button("Убрать обложку", systemImage: "trash", role: .destructive) { profile.removeCover() } }
        }
        .foregroundStyle(.white)
        .padding(14)
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// The vault's dashboard: its cover with the name and numbers on top, and below it a note of the vault
/// (by default "Dashboard.md") with whatever you put there — columns, blocks, links, tasks, quotes.
struct DashboardView: View {
    @Environment(VaultStore.self) private var vault
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

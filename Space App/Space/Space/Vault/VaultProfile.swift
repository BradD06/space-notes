import SwiftUI
import Observation
#if os(macOS)
import AppKit
#endif

/// The vault's profile: a cover picture and the vault's dashboard with its own name.
/// Kept inside the vault in ".space/" — vault.json, the picture and the dashboard page "Dashboard.md" —
/// so it travels with the vault but stays out of the universes and folders.
@MainActor
@Observable
final class VaultProfile {
    static let shared = VaultProfile()

    /// The dashboard's name, shown on its banner. Editable.
    private(set) var title = VaultProfile.defaultTitle
    private(set) var coverFile: String?
    /// Bumped when the cover changes, so views reload the picture.
    private(set) var coverVersion = 0
    @ObservationIgnored private var root: URL?

    static let defaultTitle = "Дашборд"

    private struct Stored: Codable {
        var cover: String?
        var dashboard: String?      // older versions: a note of the vault used as the dashboard
        var title: String?
    }

    private var folder: URL? { root?.appending(path: ".space", directoryHint: .isDirectory) }
    private var configURL: URL? { folder?.appending(path: "vault.json") }
    var coverURL: URL? { coverFile.flatMap { folder?.appending(path: $0) } }
    /// The dashboard page itself — a Markdown file, but not a note of any universe.
    var dashboardURL: URL? { folder?.appending(path: "Dashboard.md") }

    func load(root: URL?) {
        self.root = root
        title = Self.defaultTitle
        coverFile = nil
        var stored: Stored?
        if let url = configURL, let data = try? Data(contentsOf: url) { stored = try? JSONDecoder().decode(Stored.self, from: data) }
        coverFile = stored?.cover
        if let t = stored?.title, !t.trimmingCharacters(in: .whitespaces).isEmpty { title = t }
        // Earlier the dashboard was created as "Dashboard.md" among the notes: move it into ".space".
        if stored?.dashboard == "Dashboard.md", let root, let dest = dashboardURL {
            let old = root.appending(path: "Dashboard.md")
            let fm = FileManager.default
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: dest.path) {
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: old, to: dest)
            }
            save()
        }
        coverVersion += 1
    }

    func setTitle(_ new: String) {
        let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
        title = t.isEmpty ? Self.defaultTitle : t
        save()
    }

    /// Copies the picture into the vault and makes it the cover.
    func setCover(from source: URL) throws {
        guard let folder else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let old = coverURL { try? fm.removeItem(at: old) }
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        let name = "cover-\(Int(Date().timeIntervalSince1970)).\(ext)"
        try fm.copyItem(at: source, to: folder.appending(path: name))
        coverFile = name
        coverVersion += 1
        save()
    }

    func removeCover() {
        if let old = coverURL { try? FileManager.default.removeItem(at: old) }
        coverFile = nil
        coverVersion += 1
        save()
    }

    private func save() {
        guard let folder, let url = configURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try? JSONEncoder().encode(Stored(cover: coverFile, dashboard: nil, title: title))
        try? data?.write(to: url, options: .atomic)
    }

    #if os(macOS)
    var coverImage: NSImage? {
        _ = coverVersion
        return coverURL.flatMap { NSImage(contentsOf: $0) }
    }
    #endif
}

/// The vault's cover with its name and a few numbers on it. Used in the sidebar and on top of the dashboard.
struct VaultCover: View {
    let name: String
    let stats: String
    var height: CGFloat = 92
    var big = false
    var showText = true
    var selected = false
    private let profile = VaultProfile.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: big ? 22 : 14, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            picture
            if showText {
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: big ? 30 : 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(stats)
                        .font(.system(size: big ? 13 : 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .shadow(color: .black.opacity(0.5), radius: 6)
                .padding(big ? 22 : 12)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? Theme.accent : Color.white.opacity(0.14), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .contentShape(shape)
    }

    @ViewBuilder
    private var picture: some View {
        #if os(macOS)
        if let image = profile.coverImage {
            Color.clear.overlay(Image(nsImage: image).resizable().scaledToFill())
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    /// No cover yet: a soft nebula in the theme's colours.
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x3A1D1C), Color(hex: 0x1E1E22), Color(hex: 0x24304A)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Theme.accent.opacity(0.55), .clear], center: .init(x: 0.25, y: 0.3), startRadius: 2, endRadius: 160)
            RadialGradient(colors: [Color(hex: 0x8FB3FF, opacity: 0.35), .clear], center: .init(x: 0.85, y: 0.8), startRadius: 2, endRadius: 140)
        }
    }
}

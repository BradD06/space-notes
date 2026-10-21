import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// Pictures embedded in notes (`![[photo.png]]`, `![](images/photo.png)`): finding them in the vault,
/// loading them once, and saving new ones next to the note, the way Obsidian does.
@MainActor
enum EditorImages {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg", "avif"]

    static func isImage(_ name: String) -> Bool { extensions.contains((name as NSString).pathExtension.lowercased()) }

    private static var cache: [URL: PlatformImage] = [:]
    private static var missing: Set<URL> = []
    /// File name (lowercased) → relative path, for `![[name.png]]` that lives anywhere in the vault.
    private static var index: [String: String] = [:]
    private static var indexRoot: URL?
    private static var indexBuilt = Date.distantPast

    /// Where an embed points: next to the note, from the vault root, or by file name anywhere in the vault.
    static func resolve(_ ref: String, note: URL?, root: URL?) -> URL? {
        var ref = ref.trimmingCharacters(in: .whitespaces)
        if ref.hasPrefix("<"), ref.hasSuffix(">") { ref = String(ref.dropFirst().dropLast()) }
        ref = ref.removingPercentEncoding ?? ref
        guard !ref.isEmpty, !ref.contains("://") else { return nil }
        let fm = FileManager.default
        if ref.hasPrefix("/"), fm.fileExists(atPath: ref) { return URL(fileURLWithPath: ref) }
        var candidates: [URL] = []
        if let dir = note?.deletingLastPathComponent() { candidates.append(dir.appending(path: ref)) }
        if let root { candidates.append(root.appending(path: ref)) }
        if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return found }
        guard let root else { return nil }
        let name = (ref as NSString).lastPathComponent.lowercased()
        if indexRoot != root || (index[name] == nil && Date().timeIntervalSince(indexBuilt) > 5) { rebuildIndex(root) }
        return index[name].map { root.appending(path: $0) }
    }

    /// Every picture of the vault by its file name, for `![[` suggestions.
    static func names(root: URL?) -> [String] {
        guard let root else { return [] }
        if indexRoot != root || Date().timeIntervalSince(indexBuilt) > 30 { rebuildIndex(root) }
        return index.values.map { ($0 as NSString).lastPathComponent }.sorted()
    }

    private static func rebuildIndex(_ root: URL) {
        indexRoot = root
        indexBuilt = Date()
        var map: [String: String] = [:]
        let base = root.standardizedFileURL.path
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in e where isImage(url.lastPathComponent) {
                let path = url.standardizedFileURL.path
                let rel = path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
                let key = url.lastPathComponent.lowercased()
                if map[key] == nil || rel.count < map[key]!.count { map[key] = rel }   // shortest path wins, like Obsidian
            }
        }
        index = map
    }

    /// The picture, scaled down for the screen and kept for the next restyle.
    static func image(at url: URL) -> PlatformImage? {
        if let img = cache[url] { return img }
        if missing.contains(url) { return nil }
        let img = load(url)
        if let img { cache[url] = img } else { missing.insert(url) }
        return img
    }

    /// A file that changed or was just added gets read again.
    static func forget(_ url: URL) {
        cache[url] = nil
        missing.remove(url)
    }

    private static func load(_ url: URL) -> PlatformImage? {
        #if os(macOS)
        if url.pathExtension.lowercased() == "svg" { return NSImage(contentsOf: url) }
        #endif
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2000,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        // Points, not pixels: a Retina screenshot shows at the size it was taken.
        let scale: CGFloat = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            .flatMap { ($0[kCGImagePropertyDPIWidth] as? CGFloat) }.map { max(1, $0 / 72) } ?? 1
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        #else
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
        #endif
    }

    // MARK: Saving new pictures

    enum SaveError: LocalizedError {
        case noFolder
        var errorDescription: String? { "Сначала сохрани заметку в хранилище: картинке некуда лечь." }
    }

    /// Saves pasted or dropped image data next to the note as "Pasted image 20261021061203.png" (Obsidian's name)
    /// and returns the embed name.
    static func save(_ data: Data, ext: String, nextTo note: URL?) throws -> String {
        guard let dir = note?.deletingLastPathComponent() else { throw SaveError.noFolder }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        let target = unique(dir, "Pasted image \(f.string(from: .now))", ext)
        try data.write(to: target, options: .atomic)
        forget(target)
        return target.lastPathComponent
    }

    /// A picture file from outside the vault is copied next to the note; one already inside is linked where it is.
    static func importFile(_ source: URL, nextTo note: URL?, root: URL?) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if let root, source.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") {
            return source.lastPathComponent
        }
        guard let dir = note?.deletingLastPathComponent() else { throw SaveError.noFolder }
        let base = source.deletingPathExtension().lastPathComponent
        let target = unique(dir, base, source.pathExtension)
        try FileManager.default.copyItem(at: source, to: target)
        forget(target)
        return target.lastPathComponent
    }

    private static func unique(_ dir: URL, _ base: String, _ ext: String) -> URL {
        var url = dir.appending(path: "\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appending(path: "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// The embed for a saved picture. Names with brackets can't go into `![[ ]]`, so they become `![](…)`.
    static func embed(_ name: String) -> String {
        if name.contains("[") || name.contains("]") || name.contains("|") || name.contains("#") {
            return "![](\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))"
        }
        return "![[\(name)]]"
    }
}

/// Opens the file picker for "Картинка…" in the note's tools and shows what went wrong, if anything.
struct EditorMediaModifier: ViewModifier {
    @Bindable var state: EditorState

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $state.pickingImage, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { state.insertImages?(urls) }
            }
            .alert("Не удалось вставить картинку", isPresented: Binding(get: { state.mediaError != nil }, set: { if !$0 { state.mediaError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.mediaError ?? "")
            }
    }
}

extension View {
    /// The image picker and its errors for a `MarkdownEditor` with this state.
    func editorMedia(_ state: EditorState) -> some View { modifier(EditorMediaModifier(state: state)) }
}

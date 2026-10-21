import SwiftUI
import Observation

/// Notion's gallery view on top of plain Markdown: a fenced block
///
///     ```gallery
///     source: books
///     sort: recent
///     size: medium
///     ```
///
/// shows the vault's notes or books as a grid of cards. In Obsidian it stays a harmless code block.
nonisolated struct GallerySpec: Equatable, Sendable {
    static let language = "gallery"

    nonisolated enum Source: String, CaseIterable, Sendable {
        case notes, books, universe, folder, tag
    }
    nonisolated enum Sort: String, CaseIterable, Sendable {
        case recent, created, title, progress
        var title: String {
            switch self {
            case .recent: "Сначала изменённые"
            case .created: "Сначала новые"
            case .title: "По названию"
            case .progress: "По прогрессу чтения"
            }
        }
    }
    nonisolated enum Size: String, CaseIterable, Sendable {
        case small, medium, large
        var title: String {
            switch self {
            case .small: "Маленькие карточки"
            case .medium: "Средние карточки"
            case .large: "Большие карточки"
            }
        }
        var minWidth: CGFloat {
            switch self {
            case .small: 140
            case .medium: 190
            case .large: 260
            }
        }
    }

    var source: Source = .notes
    /// The universe's name, the folder's path or the tag, for those sources.
    var value = ""
    var sort: Sort = .recent
    var size: Size = .medium
    /// Shown above the cards instead of the source's name.
    var title = ""

    /// Reads the block's lines ("key: value"); unknown keys are ignored.
    static func parse(_ block: String) -> GallerySpec {
        var spec = GallerySpec()
        for raw in block.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("```"), !line.hasPrefix("~~~"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "source": spec.source = Source(rawValue: value.lowercased()) ?? .notes
            case "value", "universe", "folder", "tag": spec.value = value
            case "sort": spec.sort = Sort(rawValue: value.lowercased()) ?? .recent
            case "size": spec.size = Size(rawValue: value.lowercased()) ?? .medium
            case "title": spec.title = value
            default: break
            }
        }
        return spec
    }

    var markdown: String {
        var lines = ["```" + Self.language, "source: \(source.rawValue)"]
        if !value.isEmpty, source != .notes, source != .books { lines.append("value: \(value)") }
        lines.append("sort: \(sort.rawValue)")
        lines.append("size: \(size.rawValue)")
        if !title.isEmpty { lines.append("title: \(title)") }
        lines.append("```")
        return lines.joined(separator: "\n")
    }
}

#if os(macOS)
import AppKit
import PDFKit
import ImageIO

/// What a gallery shows and where its changes go.
@MainActor
@Observable
final class GalleryModel {
    var spec = GallerySpec()
    var width: CGFloat = 600
    @ObservationIgnored var index = 0
    @ObservationIgnored var onChange: ((GallerySpec) -> Void)?
    @ObservationIgnored var onOpen: ((String) -> Void)?
    @ObservationIgnored var onHeight: ((CGFloat) -> Void)?

    func change(_ edit: (inout GallerySpec) -> Void) {
        var s = spec
        edit(&s)
        guard s != spec else { return }
        spec = s
        onChange?(s)
    }
}

/// A card's picture and preview text, read from the file in the background and kept until the file changes.
@MainActor
@Observable
final class GalleryCache {
    static let shared = GalleryCache()

    struct Info {
        var snippet = ""
        var image: NSImage?
    }

    private(set) var infos: [String: Info] = [:]
    @ObservationIgnored private var stamps: [String: Date] = [:]
    @ObservationIgnored private var imageIndex: [String: String]?
    @ObservationIgnored private var indexRoot: URL?

    func info(_ id: String, root: URL?, modified: Date) -> Info? {
        if stamps[id] != modified, let root {
            stamps[id] = modified
            load(id, root: root)
        }
        return infos[id]
    }

    private func load(_ id: String, root: URL) {
        if indexRoot != root { indexRoot = root; imageIndex = nil }
        let index = imageIndex
        Task.detached(priority: .utility) {
            let result = Self.read(id, root: root, index: index)
            await MainActor.run {
                if self.imageIndex == nil, let built = result.index { self.imageIndex = built }
                self.infos[id] = Info(snippet: result.snippet, image: result.image)
            }
        }
    }

    nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    nonisolated private static func read(_ id: String, root: URL, index: [String: String]?) -> (snippet: String, image: NSImage?, index: [String: String]?) {
        let url = root.appending(path: id)
        if Books.isBook(id) {
            let thumb = PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 320, height: 460), for: .cropBox)
            return ("", thumb, nil)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ("", nil, nil) }
        var built: [String: String]?
        var image: NSImage?
        if let ref = coverReference(in: text) {
            if ref.hasPrefix("http://") || ref.hasPrefix("https://") {
                image = nil                                   // no network images in cards
            } else {
                let noteDir = url.deletingLastPathComponent()
                var candidates = [root.appending(path: ref), noteDir.appending(path: ref)]
                if !FileManager.default.fileExists(atPath: candidates[0].path), !FileManager.default.fileExists(atPath: candidates[1].path) {
                    let names = index ?? buildIndex(root)
                    if index == nil { built = names }
                    if let rel = names[(ref as NSString).lastPathComponent.lowercased()] { candidates.append(root.appending(path: rel)) }
                }
                if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { image = thumbnail(found) }
            }
        }
        return (snippet(of: text), image, built)
    }

    /// `cover:` / `image:` / `banner:` in the properties, else the first embedded picture.
    nonisolated private static func coverReference(in text: String) -> String? {
        if text.hasPrefix("---"), let fm = Properties.frontmatter(in: text as NSString), let props = Properties.parse(fm.yaml) {
            for p in props where ["cover", "image", "banner", "обложка"].contains(p.key.lowercased()) {
                var v: String?
                switch p.value {
                case .text(let s): v = s
                case .list(let l): v = l.first
                case .bool: v = nil
                }
                if let v = v.map(clean), !v.isEmpty { return v }
            }
        }
        if let r = text.range(of: #"!\[\[([^\]|#]+)"#, options: .regularExpression) {
            let inner = String(text[r]).dropFirst(3)
            let s = String(inner)
            if imageExtensions.contains((s as NSString).pathExtension.lowercased()) { return s }
        }
        if let r = text.range(of: #"!\[[^\]]*\]\(([^)\s]+)\)"#, options: .regularExpression) {
            let m = String(text[r])
            if let open = m.lastIndex(of: "(") { return String(m[m.index(after: open)...].dropLast()).removingPercentEncoding }
        }
        return nil
    }

    nonisolated private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[[") && t.hasSuffix("]]") { t = String(t.dropFirst(2).dropLast(2)) }
        if let bar = t.firstIndex(of: "|") { t = String(t[..<bar]) }
        return t
    }

    nonisolated private static func buildIndex(_ root: URL) -> [String: String] {
        var map: [String: String] = [:]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return map }
        let base = root.standardizedFileURL.path
        for case let url as URL in e where imageExtensions.contains(url.pathExtension.lowercased()) {
            let path = url.standardizedFileURL.path
            let rel = path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
            map[url.lastPathComponent.lowercased()] = map[url.lastPathComponent.lowercased()] ?? rel
        }
        return map
    }

    nonisolated private static func thumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// The note's first lines as plain text, the way Notion previews a page on its card.
    nonisolated private static func snippet(of text: String) -> String {
        let body = MarkdownParser.stripFrontmatter(text)
        var out: [String] = []
        var inCode = false
        for raw in body.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inCode.toggle(); continue }
            if inCode || line.isEmpty || line.hasPrefix("![") || line.hasPrefix("|") || line.hasPrefix("---") { continue }
            line = line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*(\[![A-Za-z]+\][+-]?\s*)?|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[\[([^\]|]+\|)?([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(\*\*|__|==|~~|`|\*)"#, with: "", options: .regularExpression)
            if line.isEmpty { continue }
            out.append(line)
            if out.joined(separator: " ").count > 240 { break }
        }
        return String(out.joined(separator: "\n").prefix(260))
    }
}

/// The grid of cards drawn over a ```gallery block.
struct GalleryView: View {
    @Bindable var model: GalleryModel
    @Environment(VaultStore.self) private var vault
    @State private var showAll = false
    private let stats = BookStats.shared
    private let gap: CGFloat = 12

    var body: some View {
        let c = vault.cosmos
        let items = self.items(c)
        let columns = max(1, Int((model.width + gap) / (model.spec.size.minWidth + gap)))
        let cardWidth = floor((model.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let limit = columns * (model.spec.size == .small ? 3 : 2)
        let shown = showAll ? items : Array(items.prefix(limit))
        VStack(alignment: .leading, spacing: 10) {
            header(c, count: items.count)
            if items.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            }
            VStack(alignment: .leading, spacing: gap) {
                ForEach(Array(stride(from: 0, to: shown.count, by: columns)), id: \.self) { start in
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(shown[start..<min(start + columns, shown.count)], id: \.self) { id in
                            GalleryCard(id: id, width: cardWidth, size: model.spec.size, open: { model.onOpen?(link(for: id, in: c)) })
                        }
                    }
                }
            }
            if items.count > limit {
                Button { withAnimation(.smooth(duration: 0.25)) { showAll.toggle() } } label: {
                    Label(showAll ? "Свернуть" : "Показать все · \(items.count)", systemImage: showAll ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .frame(width: model.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.onHeight?(g.size.height) }
                .onChange(of: g.size.height) { _, h in model.onHeight?(h) }
        })
    }

    // MARK: Which cards

    private func items(_ c: Cosmos) -> [String] {
        let spec = model.spec
        var ids: [String]
        switch spec.source {
        case .notes:
            ids = c.notes.keys.filter { !Books.isBook($0) }
        case .books:
            ids = c.notes.keys.filter(Books.isBook)
        case .universe:
            let u = c.universes.first { $0.name.lowercased() == spec.value.lowercased() }
            ids = u.map { u in c.notes.keys.filter { c.universeOf[$0] == u.id } } ?? []
        case .folder:
            let f = spec.value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ids = c.notes.keys.filter { f.isEmpty ? !$0.contains("/") : $0.hasPrefix(f + "/") }
        case .tag:
            let t = spec.value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            ids = c.notes.values.filter { $0.tags.contains(t) }.map(\.id)
        }
        switch spec.sort {
        case .recent:
            ids.sort { (c.notes[$0]?.modified ?? .distantPast) > (c.notes[$1]?.modified ?? .distantPast) }
        case .created:
            ids.sort { (c.notes[$0]?.created ?? .distantPast) > (c.notes[$1]?.created ?? .distantPast) }
        case .title:
            ids.sort { c.title($0).localizedStandardCompare(c.title($1)) == .orderedAscending }
        case .progress:
            ids.sort {
                let a = stats.stat($0), b = stats.stat($1)
                return a.progress != b.progress ? a.progress > b.progress : (a.lastRead ?? .distantPast) > (b.lastRead ?? .distantPast)
            }
        }
        return ids
    }

    /// What the card opens: [[Title]] for notes, [[File.pdf]] for books (the note view knows both).
    private func link(for id: String, in c: Cosmos) -> String {
        Books.isBook(id) ? (id as NSString).lastPathComponent : c.title(id)
    }

    private var emptyText: String {
        switch model.spec.source {
        case .books: "В хранилище пока нет книг — положите PDF в любую папку"
        case .tag: model.spec.value.isEmpty ? "Выберите тег в меню «Источник»" : "Нет заметок с тегом #\(model.spec.value)"
        case .universe: model.spec.value.isEmpty ? "Выберите вселенную в меню «Источник»" : "В этой вселенной пока пусто"
        default: "Здесь пока пусто"
        }
    }

    // MARK: Header

    private func sourceTitle(_ s: GallerySpec) -> String {
        switch s.source {
        case .notes: "Все заметки"
        case .books: "Библиотека"
        case .universe: s.value.isEmpty ? "Вселенная" : s.value
        case .folder: s.value.isEmpty ? "Корень хранилища" : (s.value as NSString).lastPathComponent
        case .tag: s.value.isEmpty ? "Тег" : "#" + s.value
        }
    }

    private func sourceIcon(_ s: GallerySpec.Source) -> String {
        switch s {
        case .notes: "doc.text"
        case .books: "books.vertical"
        case .universe: "circle.dashed"
        case .folder: "folder"
        case .tag: "number"
        }
    }

    private func header(_ c: Cosmos, count: Int) -> some View {
        let spec = model.spec
        // Tags from the notes' properties and their text, the most used first.
        let counts = c.notes.values.flatMap(\.tags).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let tags = counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
        return HStack(spacing: 8) {
            Image(systemName: sourceIcon(spec.source)).foregroundStyle(Theme.accent)
            Text(spec.title.isEmpty ? sourceTitle(spec) : spec.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                .fixedSize()
            Spacer(minLength: 8)
            Menu {
                Button("Все заметки", systemImage: "doc.text") { model.change { $0.source = .notes; $0.value = "" } }
                Button("Книги", systemImage: "books.vertical") { model.change { $0.source = .books; $0.value = ""; if $0.sort == .recent { $0.sort = .progress } } }
                Divider()
                Menu("Вселенная") {
                    ForEach(c.universes, id: \.id) { u in
                        Button(u.name) { model.change { $0.source = .universe; $0.value = u.name } }
                    }
                }
                Menu("Тег") {
                    if tags.isEmpty { Text("Тегов пока нет") }
                    ForEach(tags, id: \.self) { t in
                        Button("#\(t) · \(counts[t] ?? 0)") { model.change { $0.source = .tag; $0.value = t } }
                    }
                }
            } label: {
                chip("Источник", icon: "line.3.horizontal.decrease")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Что показывать: все заметки, книги, вселенную или тег")
            Menu {
                ForEach(GallerySpec.Sort.allCases, id: \.self) { s in
                    Button { model.change { $0.sort = s } } label: {
                        Text(s == spec.sort ? "\(s.title)  ✓" : s.title)
                    }
                }
                Divider()
                ForEach(GallerySpec.Size.allCases, id: \.self) { s in
                    Button { model.change { $0.size = s } } label: {
                        Text(s == spec.size ? "\(s.title)  ✓" : s.title)
                    }
                }
            } label: {
                chip("Вид", icon: "square.grid.2x2")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Порядок и размер карточек")
        }
    }

    /// In a narrow gallery (a column) the menus show only their icons.
    @ViewBuilder
    private func chip(_ title: String, icon: String) -> some View {
        Group {
            if model.width < 380 {
                Image(systemName: icon)
            } else {
                Label(title, systemImage: icon)
            }
        }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .contentShape(Capsule())
    }
}

/// One card: the picture (a book's cover, the note's cover image or its first lines), then the title and details.
private struct GalleryCard: View {
    let id: String
    let width: CGFloat
    let size: GallerySpec.Size
    let open: () -> Void
    @Environment(VaultStore.self) private var vault
    @State private var hover = false
    private let cache = GalleryCache.shared
    private let stats = BookStats.shared

    var body: some View {
        let c = vault.cosmos
        let note = c.notes[id]
        let book = Books.isBook(id)
        let info = note.flatMap { cache.info(id, root: vault.rootURL, modified: $0.modified) }
        let pictureHeight = book ? width * 1.38 : width * (size == .small ? 0.62 : 0.56)
        let color = Theme.color(forUniverse: c.universeOf[id])
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if let image = info?.image {
                        Color.clear.overlay(Image(nsImage: image).resizable().scaledToFill())
                    } else if book {
                        LinearGradient(colors: [Color(hex: 0x3A1D1C), Color(hex: 0x24304A)], startPoint: .top, endPoint: .bottom)
                            .overlay(Image(systemName: "book.closed").font(.system(size: 26)).foregroundStyle(.white.opacity(0.5)))
                    } else {
                        LinearGradient(colors: [color.opacity(0.16), Color.white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Text(info?.snippet ?? "")
                            .font(.system(size: size == .small ? 9.5 : 10.5))
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(2)
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: width, height: pictureHeight)
                .clipped()

                VStack(alignment: .leading, spacing: 5) {
                    Text(c.title(id))
                        .font(.system(size: size == .small ? 12 : 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if book {
                        let s = stats.stat(id)
                        ProgressBar(value: s.progress, height: 4)
                        Text(s.pages > 0 ? "\(Int((s.progress * 100).rounded()))% · \(BookStats.duration(s.seconds))" : "Ещё не открывали")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        let n = c.backlinks(to: id).count
                        if n > 0 {
                            Label("\(n) \(plural(n, "заметка", "заметки", "заметок"))", systemImage: "doc.text")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    } else {
                        HStack(spacing: 5) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(c.universeOf[id].flatMap { c.universe($0)?.name } ?? Cosmos.inboxName)
                                .lineLimit(1)
                            if let d = note?.modified {
                                Text("· " + RuDate.dayMonth(d, short: true)).lineLimit(1)
                            }
                        }
                        .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(width: width, alignment: .leading)
            }
            .background(Color.white.opacity(hover ? 0.07 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? Theme.accent.opacity(0.55) : Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(hover ? 0.3 : 0.15), radius: hover ? 10 : 4, y: hover ? 5 : 2)
            .scaleEffect(hover ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(book ? "Открыть книгу" : "Открыть заметку")
    }
}

// MARK: - Hosting galleries in a text view

/// The galleries laid over one text view (the note, or one column of a columns block): a card grid over
/// every ```gallery block, the room each needs, and their settings written back into the text.
@MainActor
final class GalleryOverlays {
    private weak var textView: NSTextView?
    private(set) var hosts: [NSHostingView<AnyView>] = []
    private var models: [GalleryModel] = []
    /// Room kept for the k-th gallery of the text (fed to the styler).
    private(set) var heights: [CGFloat] = []
    var vault: () -> VaultStore?
    var onOpen: (String) -> Void
    /// A gallery grew or shrank: restyle the text so it keeps the new room.
    var onResize: () -> Void

    init(textView: NSTextView, vault: @escaping () -> VaultStore?, onOpen: @escaping (String) -> Void, onResize: @escaping () -> Void) {
        self.textView = textView
        self.vault = vault
        self.onOpen = onOpen
        self.onResize = onResize
    }

    var isEmpty: Bool { hosts.isEmpty }

    /// Puts a gallery over every gallery block (after a restyle, when the layout is known).
    func sync(_ blocks: [EditorBlock]) {
        let found = blocks.filter { $0.kind == .gallery }
        while hosts.count > found.count {
            hosts.removeLast().removeFromSuperview()
            models.removeLast()
        }
        guard !found.isEmpty, let tv = textView, let vault = vault(),
              let lm = tv.layoutManager, let container = tv.textContainer else { return }
        lm.ensureLayout(for: container)
        let o = tv.textContainerOrigin
        let pad = container.lineFragmentPadding
        let width = max(80, container.size.width - 2 * pad)
        let ns = tv.string as NSString
        for (k, b) in found.enumerated() {
            let model: GalleryModel
            if k < models.count {
                model = models[k]
            } else {
                model = GalleryModel()
                model.onChange = { [weak self, weak model] spec in
                    guard let self, let model else { return }
                    self.write(spec, at: model.index)
                }
                model.onOpen = { [weak self] link in self?.onOpen(link) }
                model.onHeight = { [weak self, weak model] h in
                    guard let self, let model else { return }
                    self.setHeight(h, at: model.index)
                }
                let host = NSHostingView(rootView: AnyView(GalleryView(model: model).environment(vault)))
                tv.addSubview(host)
                models.append(model)
                hosts.append(host)
            }
            model.index = k
            let spec = GallerySpec.parse(ns.substring(with: b.range))
            if model.spec != spec { model.spec = spec }
            if abs(model.width - width) > 0.5 { model.width = width }
            let height = k < heights.count ? heights[k] : 240
            let glyph = lm.glyphIndexForCharacter(at: min(b.range.location, max(ns.length - 1, 0)))
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            hosts[k].frame = NSRect(x: o.x + pad, y: o.y + line.maxY - height, width: width, height: height)
        }
    }

    private func setHeight(_ h: CGFloat, at k: Int) {
        let height = ceil(h)
        while heights.count <= k { heights.append(240) }
        guard abs(heights[k] - height) > 0.5 else { return }
        heights[k] = height
        DispatchQueue.main.async { [weak self] in self?.onResize() }
    }

    /// Writes the gallery's settings back into its block (one undoable change).
    private func write(_ spec: GallerySpec, at k: Int) {
        guard let tv = textView else { return }
        let all = (tv.layoutManager as? BlockLayoutManager)?.blocks.filter { $0.kind == .gallery } ?? []
        guard all.indices.contains(k) else { return }
        let range = all[k].range
        let new = spec.markdown
        guard (tv.string as NSString).substring(with: range) != new, tv.shouldChangeText(in: range, replacementString: new) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: new)
        tv.didChangeText()
    }

    /// The caret never stops inside a gallery's hidden Markdown: it goes past it (or before it at the end).
    /// Returns true if it moved the caret.
    func hopCaret() -> Bool {
        guard let tv = textView else { return false }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let length = (tv.string as NSString).length
        for b in (tv.layoutManager as? BlockLayoutManager)?.blocks ?? [] where b.kind == .gallery {
            let r = b.range
            guard sel.location >= r.location, sel.location <= NSMaxRange(r) else { continue }
            var to = NSMaxRange(r) + 1
            if to > length { to = r.location - 1 }
            guard to >= 0, to <= length, to != sel.location else { return false }
            tv.setSelectedRange(NSRange(location: to, length: 0))
            return true
        }
        return false
    }
}

// MARK: - The note's side

extension SpaceTextView {
    var galleryHeights: [CGFloat] { galleries.heights }

    func syncGalleries(_ editorBlocks: [EditorBlock]) { galleries.sync(editorBlocks) }
}
#endif

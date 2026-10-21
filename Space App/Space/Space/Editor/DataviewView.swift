import SwiftUI
import Observation

/// The vault read for Dataview queries (see Dataview.swift). Notes are re-read only when they change.
@MainActor
final class DataviewIndexCache {
    static let shared = DataviewIndexCache()

    private var pages: [String: (modified: Date, page: DVPage)] = [:]
    private var built: (stamp: Int, root: URL, index: DVIndex)?
    private var listed: (stamp: Int, files: [String], folders: [String])?

    /// Changes whenever a note is added, removed or saved.
    var stamp: Int? { built?.stamp }

    func peekStamp(_ vault: VaultStore) -> Int {
        var h = Hasher()
        h.combine(vault.rootURL)
        for n in vault.cosmos.notes.values.sorted(by: { $0.id < $1.id }) { h.combine(n.id); h.combine(n.modified) }
        h.combine(vault.cosmos.folders.count)
        return h.finalize()
    }

    /// All files and folders of the vault (for ```dataviewjs), listed again when notes change.
    func listing(_ vault: VaultStore) -> (files: [String], folders: [String]) {
        guard let root = vault.rootURL else { return ([], []) }
        let stamp = peekStamp(vault)
        if let l = listed, l.stamp == stamp { return (l.files, l.folders) }
        let l = DataviewJS.listing(root: root)
        listed = (stamp, l.files, l.folders)
        return l
    }

    func index(_ vault: VaultStore) -> DVIndex {
        guard let root = vault.rootURL else { return DVIndex(pages: []) }
        let notes = vault.cosmos.notes.values.filter { $0.id.lowercased().hasSuffix(".md") }
        let stamp = peekStamp(vault)
        if let b = built, b.stamp == stamp, b.root == root { return b.index }
        if built?.root != root { pages = [:] }
        var seen = Set<String>()
        for n in notes {
            seen.insert(n.id)
            if pages[n.id]?.modified == n.modified { continue }
            let page = DVPage.build(id: n.id, text: vault.text(of: n.id), created: n.created, modified: n.modified)
            pages[n.id] = (n.modified, page)
        }
        for id in pages.keys where !seen.contains(id) { pages[id] = nil }
        let index = DVIndex(pages: pages.values.map(\.page))
        built = (stamp, root, index)
        return index
    }
}

/// One ```dataview block: its query and where its clicks go.
@MainActor
@Observable
final class DataviewModel {
    var query = ""
    var width: CGFloat = 600
    /// The note the block sits in (`this`, `[[]]`).
    var noteID: String?
    /// Set when the block is shown outside its note (a pane, the dashboard).
    var widgetRef: WidgetRef?
    /// Placed freely in the note, text flowing around it (see WidgetFloat).
    var floating = false
    /// Moving (offset so far, finished?) and resizing (width change so far, finished?) a floating widget.
    @ObservationIgnored var onFloatMove: ((CGSize, Bool) -> Void)?
    @ObservationIgnored var onFloatResize: ((CGFloat, Bool) -> Void)?
    /// Switches between floating and in the line of text.
    @ObservationIgnored var onToggleFloat: (() -> Void)?
    @ObservationIgnored var onOpen: ((String) -> Void)?
    @ObservationIgnored var onToggle: ((TaskItem) -> Void)?
    /// The open note's own text, read from and written to its editor (```dataviewjs).
    @ObservationIgnored var onRead: ((String) -> String?)?
    @ObservationIgnored var onWrite: ((String, String) -> Bool)?
    /// Puts the caret into the block, which shows its Markdown again.
    @ObservationIgnored var onEdit: (() -> Void)?
    @ObservationIgnored var onHeight: ((CGFloat) -> Void)?
}

/// A query's result drawn as plain Obsidian-like output: a table, a list or tasks grouped by note.
struct DataviewView: View {
    @Bindable var model: DataviewModel
    @Environment(VaultStore.self) private var vault
    @State private var showAll = false
    @State private var jsHeight: CGFloat = 60
    @State private var hover = false
    private static let pageSize = 50

    var body: some View {
        Group {
            if DataviewJS.isJS(model.query) { script } else { query }
        }
        .overlay(alignment: .topLeading) { if model.floating { moveGrip } }
        .overlay(alignment: .bottomTrailing) { if model.floating { resizeGrip } }
        .onHover { hover = $0 }
    }

    // MARK: Floating

    @State private var grabbing = false

    /// Drag to move the widget anywhere in the note; the text makes way.
    private var moveGrip: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.ink)
            .frame(width: 24, height: 22)
            .background(Capsule().fill(Theme.accent.opacity(0.85)))
            .contentShape(Capsule())
            .opacity(hover || grabbing ? 1 : 0)
            .offset(x: -6, y: -6)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in grabbing = true; model.onFloatMove?(v.translation, false) }
                .onEnded { v in grabbing = false; model.onFloatMove?(v.translation, true) })
            .help("Перетащи виджет в любое место заметки — текст его обтечёт")
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.muted)
            .frame(width: 22, height: 20)
            .background(Capsule().fill(Theme.surfaceHigh.opacity(0.9)))
            .contentShape(Capsule())
            .opacity(hover || grabbing ? 1 : 0)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in grabbing = true; model.onFloatResize?(v.translation.width, false) }
                .onEnded { v in grabbing = false; model.onFloatResize?(v.translation.width, true) })
            .help("Потяни, чтобы изменить ширину")
    }

    // MARK: ```dataviewjs

    private var script: some View {
        let _ = vault.cosmos                  // fresh pages for the script when notes change
        return DataviewJSView(code: model.query, noteID: model.noteID, vault: vault, actions: actions, height: $jsHeight)
            .frame(width: model.width, height: jsHeight)
            .overlay(alignment: .topTrailing) {
                tools
                    .opacity(hover ? 1 : 0)
                    .offset(y: -2)
            }
            .padding(.vertical, 4)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { model.onHeight?(g.size.height) }
                    .onChange(of: g.size.height) { _, h in model.onHeight?(h) }
            })
    }

    private var actions: DataviewJSActions {
        let model = model, vault = vault
        return DataviewJSActions(
            read: { path in model.onRead?(path) },
            write: { path, text in
                if model.onWrite?(path, text) == true { return }
                vault.writeFile(path, text: text)
            },
            toggle: { path, line in
                let task = TaskItem(path: path, line: line, status: " ", text: "", description: "")
                if let t = model.onToggle { t(task) } else { vault.toggle(task) }
            },
            open: { path in
                var link = path
                if let hash = link.firstIndex(of: "#") { link = String(link[..<hash]) }
                if link.lowercased().hasSuffix(".md") || link.contains("/") {
                    link = ((link as NSString).lastPathComponent as NSString).deletingPathExtension
                }
                model.onOpen?(link)
            })
    }

    /// Where this block sits: given outside the note, found in the note's text inside it.
    private var ref: WidgetRef? {
        if let r = model.widgetRef { return r }
        guard let id = model.noteID else { return nil }
        return WidgetCatalog.blocks(in: vault.text(of: id)).firstIndex(of: model.query).map { WidgetRef(note: id, index: $0) }
    }

    /// The code button in the note; the widget's menu (pane, dashboard) wherever it can be found again.
    private var tools: some View {
        HStack(spacing: 4) {
            if model.widgetRef == nil { editButton }
            if let ref {
                WidgetMenu(ref: ref, standalone: model.widgetRef != nil, onShowCode: model.onEdit,
                           floating: model.onToggleFloat == nil ? nil : model.floating, onToggleFloat: model.onToggleFloat)
            }
        }
    }

    private var editButton: some View {
        Button { model.onEdit?() } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 24, height: 22)
                .background(Capsule().fill(Theme.surfaceHigh.opacity(0.9)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Показать код виджета")
    }

    // MARK: ```dataview

    @ViewBuilder private var query: some View {
        let _ = vault.cosmos                  // re-run when any note changes
        let result = Dataview.run(model.query, index: DataviewIndexCache.shared.index(vault), current: model.noteID)
        VStack(alignment: .leading, spacing: 8) {
            header(result)
            content(result)
            if result.count > Self.pageSize {
                Button { withAnimation(.smooth(duration: 0.25)) { showAll.toggle() } } label: {
                    Label(showAll ? "Свернуть" : "Показать все · \(result.count)", systemImage: showAll ? "chevron.up" : "chevron.down")
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
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == MarkdownStyler.noteScheme else { return .systemAction }
            let raw = url.absoluteString.dropFirst(MarkdownStyler.noteScheme.count + 1)
            model.onOpen?(String(raw).removingPercentEncoding ?? String(raw))
            return .handled
        })
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.onHeight?(g.size.height) }
                .onChange(of: g.size.height) { _, h in model.onHeight?(h) }
        })
    }

    // MARK: Header

    private func header(_ result: DVResult) -> some View {
        let (icon, title): (String, String) = switch result {
        case .table: ("tablecells", "Таблица")
        case .list: ("list.bullet", "Список")
        case .tasks: ("checklist", "Задачи")
        case .failure: ("exclamationmark.triangle", "Запрос не выполнен")
        }
        return HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Theme.muted)
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.muted)
            if case .failure = result {} else {
                Text("\(result.count)").font(.system(size: 11.5)).foregroundStyle(Theme.muted.opacity(0.7))
            }
            Spacer(minLength: 8)
            tools
        }
        .font(.system(size: 11.5))
    }

    // MARK: Results

    @ViewBuilder
    private func content(_ result: DVResult) -> some View {
        switch result {
        case .failure(let message):
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        case .list(let items):
            if items.isEmpty { empty }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(shown(items).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.accent)
                        Text(listText(item)).foregroundStyle(Theme.ink)
                    }
                    .font(.system(size: 14))
                }
            }
        case .table(let headers, let rows, _):
            if rows.isEmpty { empty } else { table(headers, shown(rows)) }
        case .tasks(let groups):
            if groups.isEmpty { empty }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(shownGroups(groups).enumerated()), id: \.offset) { _, g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.rich(.link(g.link))).font(.system(size: 13, weight: .semibold))
                        ForEach(g.tasks, id: \.self) { t in taskRow(t) }
                    }
                }
            }
        }
    }

    private var empty: some View {
        Text("Ничего не найдено")
            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private func shown<T>(_ items: [T]) -> [T] { showAll ? items : Array(items.prefix(Self.pageSize)) }

    private func shownGroups(_ groups: [DVResult.TaskGroup]) -> [DVResult.TaskGroup] {
        guard !showAll else { return groups }
        var left = Self.pageSize, out: [DVResult.TaskGroup] = []
        for var g in groups where left > 0 {
            g.tasks = Array(g.tasks.prefix(left))
            left -= g.tasks.count
            out.append(g)
        }
        return out
    }

    private func listText(_ item: DVResult.ListItem) -> AttributedString {
        var s = item.link.map { Self.rich(.link($0)) } ?? AttributedString()
        if let v = item.value, !v.isNull {
            if item.link != nil { s += AttributedString(": ") }
            s += Self.rich(v)
        }
        return s
    }

    private func table(_ headers: [String], _ rows: [[DVValue]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    Text(h)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                }
            }
            .background(Color.white.opacity(0.05))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(Color.white.opacity(0.06)).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                        Text(Self.rich(v))
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }

    private func taskRow(_ t: TaskItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.onToggle?(t) } label: {
                Image(systemName: t.completed ? "checkmark.square.fill" : (t.checked ? "minus.square" : "square"))
                    .foregroundStyle(t.completed ? Theme.accent : Theme.muted)
            }
            .buttonStyle(.plain)
            .help(t.completed ? "Снять отметку" : "Отметить выполненной")
            Text(Self.rich(.string(t.description)))
                .font(.system(size: 14))
                .foregroundStyle(t.completed ? Theme.muted : Theme.ink)
                .strikethrough(t.completed, color: Theme.muted)
            TaskDates(task: t)
        }
        .padding(.leading, CGFloat(min(t.indent, 12)) * 4)
    }

    // MARK: Text

    private static let wikilink = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]|]+)(?:\\|([^\\[\\]]+))?\\]\\]")

    /// A value as text: links clickable, [[links]] inside text too, lists joined.
    static func rich(_ v: DVValue) -> AttributedString {
        switch v {
        case .link(let l):
            var s = AttributedString(l.title)
            s.link = noteURL(l.target)
            s.foregroundColor = Color(hex: 0x8FB3FF)
            return s
        case .string(let text):
            var out = AttributedString()
            let ns = text as NSString
            var cursor = 0
            for m in wikilink.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += plain(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
                let target = ns.substring(with: m.range(at: 1))
                let alias = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
                out += rich(.link(Dataview.link(alias.map { target + "|" + $0 } ?? target)))
                cursor = NSMaxRange(m.range)
            }
            out += plain(ns.substring(from: cursor))
            return out
        case .list(let items):
            var out = AttributedString()
            for (k, item) in items.enumerated() {
                if k > 0 { out += AttributedString(", ") }
                out += rich(item)
            }
            return out
        default:
            return AttributedString(v.plain)
        }
    }

    private static func plain(_ s: String) -> AttributedString {
        AttributedString(s.replacingOccurrences(of: "(\\*\\*|__|==|~~)", with: "", options: .regularExpression))
    }

    static func noteURL(_ target: String) -> URL? {
        URL(string: MarkdownStyler.noteScheme + ":" + (target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target))
    }
}

/// A task's Tasks-plugin dates as small chips: due (red when overdue), scheduled, start, done.
struct TaskDates: View {
    let task: TaskItem

    var body: some View {
        let today = Tasks.startOfToday()
        HStack(spacing: 4) {
            if let d = task.due {
                chip("calendar", d, color: task.completed ? Theme.muted : (d < today ? Color(hex: 0xFF7A7A) : (d == today ? Color(hex: 0xF2B544) : Theme.muted)))
            }
            if let d = task.scheduled { chip("hourglass", d, color: Theme.muted) }
            if let d = task.start { chip("airplane.departure", d, color: Theme.muted) }
            if let d = task.done { chip("checkmark", d, color: Theme.muted.opacity(0.8)) }
            if task.recurrence != nil {
                Image(systemName: "repeat").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }
        .fixedSize()
    }

    private func chip(_ icon: String, _ d: Date, color: Color) -> some View {
        Label(RuDate.dayMonth(d, short: true), systemImage: icon)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Writes a ticked task back to its note (the open note's own tasks go through its editor instead).
extension VaultStore {
    /// A note is saved as usual; any other file (JSON a widget keeps, say) is written as it is.
    func writeFile(_ path: String, text: String) {
        if cosmos.notes[path] != nil { save(path, text: text); return }
        guard let url = url(for: path) else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func toggle(_ task: TaskItem) {
        var lines = text(of: task.path).components(separatedBy: "\n")
        guard lines.indices.contains(task.line), Tasks.item(lines[task.line], path: task.path, line: task.line) != nil else { return }
        lines[task.line] = Tasks.toggled(lines[task.line])
        save(task.path, text: lines.joined(separator: "\n"))
    }
}

#if os(macOS)
import AppKit

// MARK: - Hosting results in a text view

/// The query results laid over the note: one view over every ```dataview block not being edited,
/// and the room each needs (kept by the block's text, so results don't swap heights when one is opened).
@MainActor
final class DataviewOverlays {
    private weak var textView: NSTextView?
    private var hosts: [NSHostingView<AnyView>] = []
    private var models: [DataviewModel] = []
    /// Kept per block body (its code without the opening line), so moving a widget keeps its height.
    private(set) var heights: [String: CGFloat] = [:]
    /// A floating widget being dragged or resized: its frame in the text view until the drag ends.
    private var liveFrame: (index: Int, frame: NSRect)?
    private var exclusions: [NSRect] = []
    /// Room kept between a floating widget and the text around it.
    static let gap: CGFloat = 12
    var vault: () -> VaultStore?
    var noteID: () -> String?
    /// The editor holding the whole note: this one, or the note's own editor for a column's widgets.
    lazy var noteView: () -> NSTextView? = { [weak self] in self?.textView }
    var onOpen: (String) -> Void
    var onResize: () -> Void

    init(textView: NSTextView, vault: @escaping () -> VaultStore?, noteID: @escaping () -> String?,
         onOpen: @escaping (String) -> Void, onResize: @escaping () -> Void) {
        self.textView = textView
        self.vault = vault
        self.noteID = noteID
        self.onOpen = onOpen
        self.onResize = onResize
    }

    var isEmpty: Bool { hosts.isEmpty }

    func sync(_ blocks: [EditorBlock]) {
        let found = blocks.filter { $0.kind == .dataview }
        while hosts.count > found.count {
            hosts.removeLast().removeFromSuperview()
            models.removeLast()
        }
        guard !found.isEmpty, let tv = textView, let vault = vault(),
              let lm = tv.layoutManager, let container = tv.textContainer else { setExclusions([]); return }
        var floats: [NSRect] = []
        lm.ensureLayout(for: container)
        let o = tv.textContainerOrigin
        let pad = container.lineFragmentPadding
        let width = max(80, container.size.width - 2 * pad)
        let ns = tv.string as NSString
        for (k, b) in found.enumerated() {
            let model: DataviewModel
            if k < models.count {
                model = models[k]
            } else {
                model = DataviewModel()
                model.onOpen = { [weak self] link in self?.onOpen(link) }
                model.onToggle = { [weak self] task in self?.toggle(task) }
                model.onRead = { [weak self] path in
                    guard let self, path == self.noteID() else { return nil }
                    return self.noteView()?.string
                }
                model.onWrite = { [weak self] path, text in
                    guard let self, path == self.noteID() else { return false }
                    self.replaceAll(with: text)
                    return true
                }
                model.onEdit = { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.edit(model.query)
                }
                model.onHeight = { [weak self, weak model] h in
                    guard let self, let model else { return }
                    self.setHeight(h, for: model.query)
                }
                model.onToggleFloat = { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.toggleFloat(model.query)
                }
                let index = k
                model.onFloatMove = { [weak self] t, done in self?.moveFloat(index, by: t, done: done) }
                model.onFloatResize = { [weak self] dw, done in self?.resizeFloat(index, by: dw, done: done) }
                let host = NSHostingView(rootView: AnyView(DataviewView(model: model).environment(vault)))
                tv.addSubview(host)
                models.append(model)
                hosts.append(host)
            }
            let query = ns.substring(with: b.range)
            if model.query != query { model.query = query }
            if model.noteID != noteID() { model.noteID = noteID() }
            let height = heights[DataviewJS.code(of: query)] ?? Self.defaultHeight
            if let f = WidgetFloat.of(block: query) {
                // Floating: where its opening line says, the text flowing around it.
                let w = min(max(160, f.w), width)
                let x = min(max(0, f.x), width - w)
                if !model.floating { model.floating = true }
                if abs(model.width - w) > 0.5 { model.width = w }
                var frame = NSRect(x: o.x + pad + x, y: o.y + max(0, f.y), width: w, height: height)
                if let live = liveFrame, live.index == k { frame = live.frame }
                hosts[k].frame = frame
                floats.append(NSRect(x: frame.minX - o.x - Self.gap, y: frame.minY - o.y - Self.gap / 2,
                                     width: frame.width + 2 * Self.gap, height: frame.height + Self.gap * 1.5))
            } else {
                if model.floating { model.floating = false }
                if abs(model.width - width) > 0.5 { model.width = width }
                let glyph = lm.glyphIndexForCharacter(at: min(b.range.location, max(ns.length - 1, 0)))
                let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                hosts[k].frame = NSRect(x: o.x + pad, y: o.y + line.maxY - height, width: width, height: height)
            }
        }
        setExclusions(floats)
    }

    /// The text keeps out of the floating widgets' rectangles (TextKit's exclusion paths).
    private func setExclusions(_ rects: [NSRect]) {
        guard rects != exclusions, let container = textView?.textContainer else { return }
        exclusions = rects
        container.exclusionPaths = rects.map { NSBezierPath(rect: $0) }
    }

    // MARK: Floating widgets

    private func block(_ k: Int) -> (range: NSRange, text: String)? {
        guard let tv = textView, models.indices.contains(k) else { return nil }
        let r = (tv.string as NSString).range(of: models[k].query)
        return r.location == NSNotFound ? nil : (r, models[k].query)
    }

    /// Writes a new placement into the block's opening line (one undoable change).
    private func writeFloat(_ k: Int, _ f: WidgetFloat?) {
        guard let tv = textView, let b = block(k) else { return }
        let ns = tv.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: b.range.location, length: 0))
        var line = ns.substring(with: lineRange)
        let newline = line.hasSuffix("\n") ? "\n" : ""
        if !newline.isEmpty { line.removeLast() }
        let new = WidgetFloat.fenceLine(line, with: f) + newline
        guard new != line + newline, tv.shouldChangeText(in: lineRange, replacementString: new) else { return }
        tv.textStorage?.replaceCharacters(in: lineRange, with: new)
        tv.didChangeText()
    }

    private func containerWidth() -> CGFloat {
        guard let c = textView?.textContainer else { return 600 }
        return max(80, c.size.width - 2 * c.lineFragmentPadding)
    }

    private func snap(_ v: CGFloat) -> CGFloat { (v / 8).rounded() * 8 }

    private func moveFloat(_ k: Int, by t: CGSize, done: Bool) {
        guard let tv = textView, hosts.indices.contains(k), let b = block(k), let f = WidgetFloat.of(block: b.text) else { return }
        let width = containerWidth()
        let w = min(max(160, f.w), width)
        let x = min(max(0, snap(min(max(0, f.x), width - w) + t.width)), width - w)
        let y = max(0, snap(max(0, f.y) + t.height))
        if done {
            liveFrame = nil
            writeFloat(k, WidgetFloat(x: x, y: y, w: w))
        } else {
            let o = tv.textContainerOrigin, pad = tv.textContainer?.lineFragmentPadding ?? 0
            let frame = NSRect(x: o.x + pad + x, y: o.y + y, width: w, height: hosts[k].frame.height)
            liveFrame = (k, frame)
            hosts[k].frame = frame
            setExclusions(exclusions.enumerated().map { $0.offset == floatIndex(k) ? NSRect(x: frame.minX - o.x - Self.gap, y: frame.minY - o.y - Self.gap / 2, width: frame.width + 2 * Self.gap, height: frame.height + Self.gap * 1.5) : $0.element })
        }
    }

    private func resizeFloat(_ k: Int, by dw: CGFloat, done: Bool) {
        guard let tv = textView, hosts.indices.contains(k), let b = block(k), let f = WidgetFloat.of(block: b.text) else { return }
        let width = containerWidth()
        let x = min(max(0, f.x), width - 160)
        let w = min(max(160, snap(f.w + dw)), width - x)
        if done {
            liveFrame = nil
            writeFloat(k, WidgetFloat(x: x, y: f.y, w: w))
        } else {
            var frame = hosts[k].frame
            frame.size.width = w
            liveFrame = (k, frame)
            hosts[k].frame = frame
            models[k].width = w
            _ = tv
        }
    }

    /// Which entry of `exclusions` belongs to the k-th block (floating blocks only, in order).
    private func floatIndex(_ k: Int) -> Int {
        models.prefix(k).filter(\.floating).count
    }

    /// Floating ⇄ in the line. A new floating widget goes to the right half, level with where it was.
    private func toggleFloat(_ query: String) {
        guard let k = models.firstIndex(where: { $0.query == query }), let tv = textView else { return }
        if WidgetFloat.of(block: query) != nil {
            writeFloat(k, nil)
        } else {
            let width = containerWidth()
            let w = snap(min(360, max(220, width * 0.45)))
            let y = hosts.indices.contains(k) ? max(0, hosts[k].frame.minY - tv.textContainerOrigin.y) : 0
            writeFloat(k, WidgetFloat(x: width - w, y: snap(y), w: w))
        }
    }

    static let defaultHeight: CGFloat = 120

    private func setHeight(_ h: CGFloat, for query: String) {
        let height = ceil(h)
        let key = DataviewJS.code(of: query)
        guard abs((heights[key] ?? Self.defaultHeight) - height) > 0.5 else { return }
        heights[key] = height
        DispatchQueue.main.async { [weak self] in self?.onResize() }
    }

    /// Opens the block's Markdown: the caret goes to the start of the query's first line.
    private func edit(_ query: String) {
        guard let tv = textView else { return }
        let r = (tv.string as NSString).range(of: query)
        guard r.location != NSNotFound else { return }
        let firstLine = (query as NSString).range(of: "\n")
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: r.location + (firstLine.location == NSNotFound ? 0 : firstLine.location + 1), length: 0))
    }

    /// A widget rewrote this very note: the editor takes the new text as one undoable change.
    private func replaceAll(with text: String) {
        guard let tv = noteView(), tv.string != text else { return }
        let all = NSRange(location: 0, length: (tv.string as NSString).length)
        let sel = tv.selectedRange()
        guard tv.shouldChangeText(in: all, replacementString: text) else { return }
        tv.textStorage?.replaceCharacters(in: all, with: text)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
    }

    /// A task of this very note is ticked through the editor (one undoable change); others are saved to their file.
    private func toggle(_ task: TaskItem) {
        guard task.path == noteID() else { vault()?.toggle(task); return }
        guard let tv = noteView() else { return }
        let ns = tv.string as NSString
        var start = 0
        for _ in 0..<task.line {
            let nl = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
            guard nl.location != NSNotFound else { return }
            start = NSMaxRange(nl)
        }
        let lineRange = ns.lineRange(for: NSRange(location: start, length: 0))
        var line = ns.substring(with: lineRange)
        let newline = line.hasSuffix("\n") ? "\n" : ""
        if !newline.isEmpty { line.removeLast() }
        guard Tasks.item(line, path: task.path, line: task.line) != nil else { return }
        let new = Tasks.toggled(line) + newline
        guard tv.shouldChangeText(in: lineRange, replacementString: new) else { return }
        tv.textStorage?.replaceCharacters(in: lineRange, with: new)
        tv.didChangeText()
    }
}

extension SpaceTextView {
    var dataviewHeights: [String: CGFloat] { dataviews.heights }

    func syncDataviews(_ editorBlocks: [EditorBlock]) { dataviews.sync(editorBlocks) }
}
#endif

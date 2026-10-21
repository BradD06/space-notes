import SwiftUI
import Observation

/// A ```dataview / ```dataviewjs block taken out of its note: shown in a pane of its own (dragged anywhere like a
/// tab). Referred to as "note path#k", the k-th such block of that note.
nonisolated struct WidgetRef: Hashable, Sendable {
    var note: String
    var index: Int

    var token: String { "\(note)#\(index)" }

    init(note: String, index: Int) {
        self.note = note
        self.index = index
    }

    init?(token: String) {
        guard let hash = token.lastIndex(of: "#"), let k = Int(token[token.index(after: hash)...]) else { return nil }
        note = String(token[..<hash])
        index = k
    }
}

nonisolated enum WidgetCatalog {
    /// The note's ```dataview and ```dataviewjs blocks, each with its fences, in order.
    static func blocks(in text: String) -> [String] {
        var out: [String] = []
        var current: [String]?
        var marker = ""
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if current == nil {
                let lower = (t.split(separator: " ").first.map(String.init) ?? "").lowercased()
                for m in ["```", "~~~"] where lower == m + Dataview.language || lower == m + DataviewJS.language {
                    current = [line]
                    marker = m
                }
            } else {
                current!.append(line)
                if t == marker {
                    out.append(current!.joined(separator: "\n"))
                    current = nil
                }
            }
        }
        return out
    }

    /// A widget's name: the script it loads (`dv.view("Виджеты/код/погода")` → "Погода"), else the note's title.
    static func name(of block: String, note: String) -> String {
        let title = ((note as NSString).lastPathComponent as NSString).deletingPathExtension
        if let r = block.range(of: #"dv\.view\(\s*["'`]([^"'`]+)["'`]"#, options: .regularExpression) {
            let inner = block[r].replacingOccurrences(of: #"^dv\.view\(\s*["'`]"#, with: "", options: .regularExpression).dropLast()
            let last = String(inner).split(separator: "/").last.map(String.init) ?? String(inner)
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        if DataviewJS.isJS(block) {
            // "// ── Focus timer (помодоро) ──" as the first comment
            if let first = block.components(separatedBy: "\n").dropFirst().first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }) {
                let c = first.replacingOccurrences(of: #"^\s*//[\s─—-]*|[\s─—-]*$"#, with: "", options: .regularExpression)
                if !c.isEmpty, c.count < 40 { return c.components(separatedBy: ":").first ?? c }
            }
        }
        return title
    }

    static func icon(of block: String) -> String {
        DataviewJS.isJS(block) ? "square.grid.2x2" : "tablecells"
    }
}

/// Every widget in the vault (their names, for tab titles). Read again when notes change.
@MainActor
final class WidgetIndex {
    static let shared = WidgetIndex()
    struct Entry: Identifiable {
        let ref: WidgetRef
        let name: String
        let icon: String
        var id: String { ref.token }
    }
    private var cached: (stamp: Int, entries: [Entry])?

    func all(_ vault: VaultStore) -> [Entry] {
        let stamp = DataviewIndexCache.shared.peekStamp(vault)
        if let c = cached, c.stamp == stamp { return c.entries }
        var out: [Entry] = []
        for id in vault.cosmos.notes.keys.sorted() where id.lowercased().hasSuffix(".md") {
            let text = vault.text(of: id)
            guard text.contains("dataview") else { continue }
            for (k, b) in WidgetCatalog.blocks(in: text).enumerated() {
                out.append(Entry(ref: WidgetRef(note: id, index: k), name: WidgetCatalog.name(of: b, note: id), icon: WidgetCatalog.icon(of: b)))
            }
        }
        cached = (stamp, out)
        return out
    }

    func entry(_ ref: WidgetRef, _ vault: VaultStore) -> Entry? { all(vault).first { $0.ref == ref } }
}

// MARK: - A widget on its own

/// One widget outside its note, at the given width: reads its block from the note, runs it like in the note.
struct WidgetBlockView: View {
    let ref: WidgetRef
    var width: CGFloat
    @Environment(VaultStore.self) private var vault
    @State private var model = DataviewModel()

    var body: some View {
        let block = currentBlock
        Group {
            if let block {
                DataviewView(model: model)
                    .onAppear { configure(block) }
                    .onChange(of: block) { _, b in configure(b) }
                    .onChange(of: width) { _, w in model.width = w }
            } else {
                Label("Виджет не найден: блок убрали из заметки «\(title)»", systemImage: "questionmark.square.dashed")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }

    private var title: String { ((ref.note as NSString).lastPathComponent as NSString).deletingPathExtension }

    private var currentBlock: String? {
        _ = vault.cosmos.notes[ref.note]?.modified           // read again after the note is saved
        let blocks = WidgetCatalog.blocks(in: vault.text(of: ref.note))
        return blocks.indices.contains(ref.index) ? blocks[ref.index] : nil
    }

    private func configure(_ block: String) {
        if model.query != block { model.query = block }
        model.noteID = ref.note
        model.width = width
        model.widgetRef = ref
        let vault = vault
        model.onOpen = { link in
            let t = link.lowercased()
            if let id = vault.cosmos.notes.values.first(where: { $0.title.lowercased() == t })?.id { vault.selection = .note(id) }
        }
        model.onToggle = { vault.toggle($0) }
        model.onEdit = { [ref] in vault.selection = .note(ref.note) }
    }
}

/// A widget in a pane of its own (a tab like any note: dragged to a side, into another pane, closed).
struct WidgetPane: View {
    let ref: WidgetRef

    var body: some View {
        GeometryReader { g in
            ScrollView {
                WidgetBlockView(ref: ref, width: max(200, g.size.width - 40))
                    .padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
    }
}

/// The widget's own menu (in its note, in a pane): placement in the note, a pane of its own, its code.
struct WidgetMenu: View {
    let ref: WidgetRef
    var standalone = false
    var onShowCode: (() -> Void)?
    /// In its note: placed freely (true) or in the line (false); nil elsewhere.
    var floating: Bool? = nil
    var onToggleFloat: (() -> Void)? = nil
    @Environment(VaultStore.self) private var vault

    var body: some View {
        Menu {
            if let floating, let onToggleFloat {
                Button(floating ? "Вернуть в строку текста" : "Свободное размещение (текст обтекает)",
                       systemImage: floating ? "text.alignleft" : "arrow.up.and.down.and.arrow.left.and.right") { onToggleFloat() }
                Divider()
            }
            if !standalone {
                Button("Открыть в отдельной панели", systemImage: "arrow.up.forward.square") { vault.selection = .widget(ref.token) }
            }
            if let onShowCode {
                Divider()
                Button(standalone ? "Открыть заметку с виджетом" : "Показать код", systemImage: "chevron.left.forwardslash.chevron.right") { onShowCode() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.muted)
                .frame(width: 24, height: 22)
                .background(Capsule().fill(Theme.surfaceHigh.opacity(0.9)))
                .contentShape(Capsule())
        }
        #if os(macOS)
        .menuStyle(.button).menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain).fixedSize()
        .help("Виджет: размещение, отдельная панель, код")
    }
}

// MARK: - Floating in the note

/// A widget placed freely in its note, text flowing around it: kept in the block's opening line,
/// "```dataviewjs float x=520 y=0 w=320" (Obsidian reads only the first word, so the note stays compatible).
/// x, y: points from the top left of the text; w: the widget's width.
nonisolated struct WidgetFloat: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat

    static func parse(_ fenceLine: String) -> WidgetFloat? {
        let words = fenceLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.contains("float") else { return nil }
        func value(_ k: String) -> CGFloat? {
            words.first { $0.hasPrefix(k + "=") }.flatMap { Double($0.dropFirst(k.count + 1)) }.map { CGFloat($0) }
        }
        return WidgetFloat(x: value("x") ?? 0, y: value("y") ?? 0, w: value("w") ?? 320)
    }

    /// The opening line with this placement (or none): the fence and language stay, old placement words go.
    static func fenceLine(_ line: String, with f: WidgetFloat?) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var kept = words.filter { w in w != "float" && !["x=", "y=", "w="].contains { w.hasPrefix($0) } }
        if let f {
            kept += ["float", "x=\(Int(f.x.rounded()))", "y=\(Int(f.y.rounded()))", "w=\(Int(f.w.rounded()))"]
        }
        return String(indent) + kept.joined(separator: " ")
    }

    /// The first line of a block.
    static func of(block: String) -> WidgetFloat? {
        parse(String(block.prefix { $0 != "\n" }))
    }
}

import SwiftUI

/// One property of a note's frontmatter, as Obsidian shows them.
nonisolated struct NoteProperty: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case text(String)
        case list([String])
        case bool(Bool)
    }
    var key: String
    var value: Value
}

/// Obsidian-style properties: the YAML frontmatter read into a list of simple properties and written back.
/// Only the flat kind Obsidian itself edits (text, lists, true/false) is handled; anything fancier
/// (nested maps, multi-line strings) makes `parse` return nil, and the editor then shows the YAML as it is.
nonisolated enum Properties {

    /// The frontmatter of a note: its whole range (from the first "---" to the end of the closing one) and the YAML inside.
    static func frontmatter(in text: NSString) -> (range: NSRange, yaml: String)? {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        let rest = NSRange(location: 4, length: text.length - 4)
        let close = text.range(of: "\n---", options: [], range: rest)
        guard close.location != NSNotFound else { return nil }
        var end = NSMaxRange(close)
        let lineEnd = text.range(of: "\n", options: [], range: NSRange(location: end, length: text.length - end))
        end = lineEnd.location == NSNotFound ? text.length : lineEnd.location
        let yamlStart = text.hasPrefix("---\r\n") ? 5 : 4
        let yaml = close.location > yamlStart ? text.substring(with: NSRange(location: yamlStart, length: close.location - yamlStart)) : ""
        return (NSRange(location: 0, length: end), yaml)
    }

    static func parse(_ yaml: String) -> [NoteProperty]? {
        var out: [NoteProperty] = []
        var openList = false                         // the last key had no value: list items may follow
        for raw in yaml.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { return nil }                       // comments would be lost
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                guard openList, !out.isEmpty else { return nil }
                let item = unquote(String(trimmed.dropFirst(trimmed == "-" ? 1 : 2)).trimmingCharacters(in: .whitespaces))
                if case .list(var items) = out[out.count - 1].value { items.append(item); out[out.count - 1].value = .list(items) }
                else { out[out.count - 1].value = .list([item]) }
                continue
            }
            guard line.first.map({ !$0.isWhitespace }) ?? false, let colon = line.firstIndex(of: ":") else { return nil }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            if rest.isEmpty {
                out.append(NoteProperty(key: key, value: .text("")))
                openList = true
                continue
            }
            openList = false
            if rest == "|" || rest == ">" || rest.hasPrefix("{") || rest.hasPrefix("&") || rest.hasPrefix("*") { return nil }
            if rest.hasPrefix("[") && rest.hasSuffix("]") && !rest.hasPrefix("[[") {
                let inner = rest.dropFirst().dropLast()
                let items = inner.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
                out.append(NoteProperty(key: key, value: .list(items)))
            } else if rest == "true" || rest == "false" {
                out.append(NoteProperty(key: key, value: .bool(rest == "true")))
            } else {
                out.append(NoteProperty(key: key, value: .text(unquote(rest))))
            }
        }
        return out
    }

    /// YAML as Obsidian writes it: lists as "  - item", links and tricky text in quotes. Unnamed properties are skipped.
    static func serialize(_ props: [NoteProperty]) -> String {
        var lines: [String] = []
        for p in props {
            let key = p.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            switch p.value {
            case .text(let s):
                lines.append(s.isEmpty ? "\(key):" : "\(key): \(quoted(s))")
            case .bool(let b):
                lines.append("\(key): \(b ? "true" : "false")")
            case .list(let items):
                if items.isEmpty { lines.append("\(key): []"); continue }
                lines.append("\(key):")
                lines.append(contentsOf: items.map { "  - \(quoted($0))" })
            }
        }
        return lines.joined(separator: "\n")
    }

    static func frontmatterText(_ props: [NoteProperty]) -> String {
        let yaml = serialize(props)
        return yaml.isEmpty ? "---\n\n---" : "---\n\(yaml)\n---"
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        if s.count >= 2, s.hasPrefix("'") && s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    private static func quoted(_ s: String) -> String {
        let special: Set<Character> = ["[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`", ",", "?", "-"]
        let needs = s.contains(": ") || s.hasSuffix(":") || s.contains(" #") || s != s.trimmingCharacters(in: .whitespaces)
            || (s.first.map { special.contains($0) } ?? false)
            || ["true", "false", "null", "yes", "no", "~"].contains(s.lowercased())
        guard needs else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

#if os(macOS)
import AppKit

/// What the properties panel shows and edits.
@MainActor
@Observable
final class PropertiesModel {
    var items: [NoteProperty] = []
    var width: CGFloat = 600
    /// Folded to a single line (remembered for all notes, as in Obsidian).
    var collapsed: Bool = UserDefaults.standard.bool(forKey: "space.propertiesCollapsed") {
        didSet { UserDefaults.standard.set(collapsed, forKey: "space.propertiesCollapsed") }
    }
    @ObservationIgnored var onChange: (([NoteProperty]) -> Void)?
    @ObservationIgnored var onOpenLink: ((String) -> Void)?
    @ObservationIgnored var onHeight: ((CGFloat) -> Void)?

    func commit() { onChange?(items) }
}

/// Obsidian's "Properties" table above the note: an icon for the kind, the name, and the value to edit in place.
struct PropertiesView: View {
    @Bindable var model: PropertiesModel

    var body: some View {
        // Sizes follow the panel's width: a narrower key column and wrapping chips in narrow panes.
        let inner = max(160, model.width - 20)
        let keyWidth = min(130, max(70, inner * 0.28))
        let valueWidth = max(60, inner - 12 - 18 - 8 - keyWidth - 8)
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { model.collapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(model.collapsed ? 0 : 90))
                    Text("Свойства").font(.system(size: 12, weight: .semibold))
                    if model.collapsed {
                        Text("· \(model.items.count)").font(.system(size: 12))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.muted)
                .padding(.leading, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.collapsed ? "Развернуть свойства" : "Свернуть свойства")
            .padding(.bottom, model.collapsed ? 0 : 4)
            if !model.collapsed {
            ForEach(model.items.indices, id: \.self) { i in
                PropertyRow(property: binding(i), keyWidth: keyWidth, valueWidth: valueWidth,
                            commit: model.commit, openLink: { model.onOpenLink?($0) }) {
                    guard model.items.indices.contains(i) else { return }
                    model.items.remove(at: i)
                    model.commit()
                }
            }
            Button {
                var name = "свойство", n = 2
                while model.items.contains(where: { $0.key == name }) { name = "свойство \(n)"; n += 1 }
                model.items.append(NoteProperty(key: name, value: .text("")))
                model.commit()
            } label: {
                Label("Добавить свойство", systemImage: "plus")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6).frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Добавить новое свойство заметки")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, model.collapsed ? 6 : 10)
        .frame(width: model.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.onHeight?(g.size.height) }
                .onChange(of: g.size.height) { _, h in model.onHeight?(h) }
        })
    }

    private func binding(_ i: Int) -> Binding<NoteProperty> {
        Binding(get: { model.items.indices.contains(i) ? model.items[i] : NoteProperty(key: "", value: .text("")) },
                set: { if model.items.indices.contains(i) { model.items[i] = $0 } })
    }
}

private struct PropertyRow: View {
    @Binding var property: NoteProperty
    let keyWidth: CGFloat
    let valueWidth: CGFloat
    let commit: () -> Void
    let openLink: (String) -> Void
    let delete: () -> Void
    @State private var hover = false
    @State private var newItem = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(width: 18, height: 26)
            TextField("", text: $property.key)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .frame(width: keyWidth, height: 26, alignment: .leading)
                .onChange(of: property.key) { commit() }
            value
                .frame(width: valueWidth, alignment: .leading)
                .frame(minHeight: 26)
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.04 : 0)))
        .onHover { hover = $0 }
        .contextMenu {
            switch property.value {
            case .text(let s):
                Button("Сделать списком", systemImage: "list.bullet") { property.value = .list(s.isEmpty ? [] : [s]); commit() }
                Button("Сделать флажком", systemImage: "checkmark.square") { property.value = .bool(false); commit() }
            case .list(let items):
                Button("Сделать текстом", systemImage: "text.alignleft") { property.value = .text(items.joined(separator: ", ")); commit() }
            case .bool:
                Button("Сделать текстом", systemImage: "text.alignleft") { property.value = .text(""); commit() }
            }
            Divider()
            Button("Удалить свойство", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    @ViewBuilder
    private var value: some View {
        switch property.value {
        case .text(let s):
            HStack(spacing: 6) {
                TextField("Пусто", text: Binding(get: { s }, set: { property.value = .text($0); commit() }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(link(s) != nil ? Color(hex: 0x8FB3FF) : Theme.ink)
                if let target = link(s) {
                    Button { openLink(target) } label: {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(hex: 0x8FB3FF))
                    .help("Открыть «\(target)»")
                }
            }
        case .bool(let b):
            Toggle("", isOn: Binding(get: { b }, set: { property.value = .bool($0); commit() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
        case .list(let items):
            Flow(spacing: 5, width: valueWidth) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    Chip(text: item, tag: isTags, link: link(item)) {
                        var list = items
                        list.remove(at: i)
                        property.value = .list(list)
                        commit()
                    } open: { openLink($0) }
                }
                TextField("Добавить…", text: $newItem)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(width: 90, height: 22)
                    .onSubmit {
                        let t = newItem.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        property.value = .list(items + [t.hasPrefix("#") && isTags ? String(t.dropFirst()) : t])
                        newItem = ""
                        commit()
                    }
            }
            .padding(.vertical, 2)
        }
    }

    private var isTags: Bool { ["tags", "tag"].contains(property.key.lowercased()) }

    private var icon: String {
        let k = property.key.lowercased()
        if isTags { return "tag" }
        if k == "aliases" || k == "alias" { return "arrow.turn.up.right" }
        switch property.value {
        case .bool: return "checkmark.square"
        case .list: return "list.bullet"
        case .text(let s):
            if link(s) != nil { return "link" }
            if s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return "calendar" }
            if Double(s) != nil { return "number" }
            return "text.alignleft"
        }
    }

    /// "[[Title]]" → "Title".
    private func link(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[["), t.hasSuffix("]]"), t.count > 4 else { return nil }
        let inner = String(t.dropFirst(2).dropLast(2))
        return String(inner.split(separator: "|").first ?? Substring(inner))
    }
}

/// A value in a list: a tag pill, a link pill, or a plain one; × removes it.
private struct Chip: View {
    let text: String
    let tag: Bool
    let link: String?
    let remove: () -> Void
    let open: (String) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tag ? "#" + text : (link ?? text))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .onTapGesture { if let link { open(link) } }
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
                .opacity(hover ? 1 : 0.35)
                .onTapGesture(perform: remove)
                .help("Убрать")
        }
        .foregroundStyle(tag ? Color(hex: 0xC9A0FF) : (link != nil ? Color(hex: 0x8FB3FF) : Theme.ink))
        .padding(.leading, 9).padding(.trailing, 3).frame(height: 22)
        .background(Capsule().fill(tag ? Color(hex: 0xC9A0FF, opacity: 0.15) : Color.white.opacity(0.08)))
        .onHover { hover = $0 }
    }
}

/// Lays chips out in lines, wrapping to the next line when one is full.
private struct Flow: Layout {
    var spacing: CGFloat = 6
    var width: CGFloat = 400

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? self.width, self.width)
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxX = bounds.minX + min(bounds.width, width)
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: - The note's side

extension SpaceTextView {

    /// Shows the properties panel over the (hidden) frontmatter, or removes it when there is none.
    func syncProperties(_ editorBlocks: [EditorBlock]) {
        guard let block = editorBlocks.first(where: { $0.kind == .properties }),
              let lm = layoutManager, let container = textContainer,
              let fm = Properties.frontmatter(in: string as NSString), let items = Properties.parse(fm.yaml) else {
            propertiesHost?.removeFromSuperview()
            propertiesHost = nil
            return
        }
        let model: PropertiesModel
        if let m = propertiesModel { model = m } else {
            model = PropertiesModel()
            model.onChange = { [weak self] items in self?.writeProperties(items) }
            model.onOpenLink = { [weak self] title in self?.coordinator?.parent.onOpenLink(title) }
            model.onHeight = { [weak self] h in self?.setPropertiesHeight(h) }
            propertiesModel = model
        }
        // Only take the file's values when they differ from what the panel would write (so typing isn't disturbed).
        if Properties.serialize(model.items) != Properties.serialize(items) { model.items = items }

        lm.ensureLayout(for: container)
        let pad = container.lineFragmentPadding
        let width = container.size.width - 2 * pad
        if abs(model.width - width) > 0.5 { model.width = width }
        let glyph = lm.glyphIndexForCharacter(at: block.range.location)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let o = textContainerOrigin
        let host: NSHostingView<PropertiesView>
        if let h = propertiesHost { host = h } else {
            host = NSHostingView(rootView: PropertiesView(model: model))
            addSubview(host)
            propertiesHost = host
        }
        host.frame = NSRect(x: o.x + pad, y: o.y + line.maxY - propertiesHeight, width: width, height: propertiesHeight)
        host.isHidden = coordinator?.parent.hideProperties ?? false
    }

    func setPropertiesHeight(_ h: CGFloat) {
        let height = ceil(h)
        guard abs(propertiesHeight - height) > 0.5 else { return }
        propertiesHeight = height
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.textStorage else { return }
            self.coordinator?.restyle(storage, selection: self.selectedRange(), force: true)
        }
    }

    /// Writes the panel's properties back into the note's YAML (one undoable change).
    func writeProperties(_ items: [NoteProperty]) {
        guard let fm = Properties.frontmatter(in: string as NSString) else { return }
        let new = Properties.frontmatterText(items)
        guard (string as NSString).substring(with: fm.range) != new, shouldChangeText(in: fm.range, replacementString: new) else { return }
        textStorage?.replaceCharacters(in: fm.range, with: new)
        didChangeText()
    }
}
#endif

// MARK: - Full-width pages

/// A note written across the whole pane, as Notion's "Full width". Stored in the note itself as
/// `cssclasses: wide-page` — the class the Minimal theme uses, so Obsidian shows it wide too.
nonisolated enum PageWidth {
    static let wideClasses: Set<String> = ["wide-page", "wide", "full-width", "dashboard-wide"]

    private static func classes(_ p: NoteProperty) -> [String] {
        switch p.value {
        case .list(let items): return items
        case .text(let s): return s.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        case .bool: return []
        }
    }

    static func isWide(_ text: String) -> Bool {
        guard let fm = Properties.frontmatter(in: text as NSString),
              let props = Properties.parse(fm.yaml) else { return false }
        return props.contains { $0.key == "cssclasses" && classes($0).contains(where: wideClasses.contains) }
    }

    /// The note's text with the page made wide or narrow; nil when its frontmatter is too complex to rewrite safely.
    static func setting(_ text: String, wide: Bool) -> String? {
        let ns = text as NSString
        var props: [NoteProperty] = []
        var body = text
        if let fm = Properties.frontmatter(in: ns) {
            guard let parsed = Properties.parse(fm.yaml) else { return nil }
            props = parsed
            body = ns.substring(from: NSMaxRange(fm.range))
            if body.hasPrefix("\n") { body.removeFirst() }
        }
        if let i = props.firstIndex(where: { $0.key == "cssclasses" }) {
            var list = classes(props[i]).filter { !wideClasses.contains($0) }
            if wide { list.append("wide-page") }
            if list.isEmpty { props.remove(at: i) } else { props[i].value = .list(list) }
        } else if wide {
            props.append(NoteProperty(key: "cssclasses", value: .list(["wide-page"])))
        }
        if props.isEmpty { return body }
        return Properties.frontmatterText(props) + "\n" + body
    }
}

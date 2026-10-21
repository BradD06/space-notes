import SwiftUI

// MARK: - Hints: what each lens lights up

enum HintsText {
    static func explain(_ lens: MapModel.Lens) -> String {
        switch lens {
        case .suggestions: "Пары звёзд без связи, у которых общие соседи или редкие теги. «Связать» допишет [[ссылку]] в заметку."
        case .orphans: "Звёзды без единой связи: к ним не ведёт ни одна дорога, их легко потерять."
        case .forgotten: "Связанные звёзды, которых ты не касался больше двух месяцев. Сначала самые связанные."
        }
    }
}

/// One star in a hint list: its colour, name and a short detail. A click flies to it on the map.
struct StarRow: View {
    let id: String
    let detail: String
    var openNote = false
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model

    var body: some View {
        Button {
            if openNote { vault.selection = .note(id) } else { model.fly(to: id, cosmos: vault.cosmos) }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(Theme.color(forUniverse: vault.cosmos.universeOf[id])).frame(width: 8, height: 8)
                Text(vault.cosmos.title(id)).lineLimit(1)
                Spacer(minLength: 6)
                Text(detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7).padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Открыть заметку", systemImage: "doc.text") { vault.selection = .note(id) }
            Button("Показать на карте", systemImage: "sparkles") {
                model.pendingStar = id
                vault.selection = .map
            }
        }
    }
}

/// A suggested link: both stars, why they belong together, and a button that makes the link.
struct SuggestionRow: View {
    let suggestion: Insights.Suggestion
    /// The star in focus: then only the other one is named.
    var from: String? = nil
    var openNote = false
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let c = vault.cosmos
        let s = suggestion
        HStack(spacing: 8) {
            Button {
                let target = from.map { s.other(than: $0) } ?? s.a
                if openNote { vault.selection = .note(target) } else { model.fly(to: target, cosmos: c) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let from {
                            dot(s.other(than: from))
                            Text(c.title(s.other(than: from))).lineLimit(1)
                        } else {
                            dot(s.a)
                            Text(c.title(s.a)).lineLimit(1)
                            Image(systemName: "arrow.left.and.right").font(.caption2).foregroundStyle(Theme.faint)
                            dot(s.b)
                            Text(c.title(s.b)).lineLimit(1)
                        }
                    }
                    Text(reason).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            Button { vault.link(s, workspace: workspace) } label: {
                Image(systemName: "link").frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .tip("Связать: дописать [[ссылку]] в одну из заметок")
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
    }

    private var reason: String {
        let c = vault.cosmos
        var parts: [String] = []
        if !suggestion.via.isEmpty {
            parts.append("через " + suggestion.via.prefix(2).map { c.title($0) }.joined(separator: ", ")
                         + (suggestion.via.count > 2 ? " и ещё \(suggestion.via.count - 2)" : ""))
        }
        if !suggestion.tags.isEmpty { parts.append(suggestion.tags.prefix(3).map { "#" + $0 }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    private func dot(_ id: String) -> some View {
        Circle().fill(Theme.color(forUniverse: vault.cosmos.universeOf[id])).frame(width: 7, height: 7)
    }
}

extension Insights.Suggestion {
    /// Why the two notes belong together, in words: "Обе ссылаются на A и B · #swift".
    func reason(_ c: Cosmos) -> String {
        var parts: [String] = []
        if !via.isEmpty {
            parts.append("Обе ссылаются на " + via.prefix(2).map { "«\(c.title($0))»" }.joined(separator: " и ")
                         + (via.count > 2 ? " и ещё \(via.count - 2)" : ""))
        }
        if !tags.isEmpty { parts.append("общие теги " + tags.prefix(3).map { "#" + $0 }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Making a suggested link

extension VaultStore {
    /// Writes the suggested link into one of the two notes: one that is not open in an editor,
    /// so the editor doesn't overwrite it with its own copy of the text.
    func link(_ s: Insights.Suggestion, workspace: Workspace) {
        let free = [s.a, s.b].filter { !workspace.isOpen(.note($0)) && !Books.isBook($0) }
        guard let from = free.first else {
            errorMessage = "Обе заметки открыты в редакторе. Добавь ссылку [[\(cosmos.title(s.b))]] в «\(cosmos.title(s.a))» вручную."
            return
        }
        addLink(from: from, to: s.other(than: from))
    }

    /// Adds [[target]] on its own line at the end of the note.
    func addLink(from id: String, to target: String) {
        var text = text(of: id)
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        text += "[[\(cosmos.title(target))]]\n"
        save(id, text: text)
    }
}

extension Workspace {
    /// Whether the tab is open in any pane.
    func isOpen(_ tab: WorkTab) -> Bool {
        func walk(_ n: PaneNode) -> Bool { n.isPane ? n.tabs.contains(tab) : n.children.contains(where: walk) }
        return walk(root)
    }
}

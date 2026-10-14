import SwiftUI

/// Plain markdown editing for now (a TextKit 2 editor with live styling comes next).
/// Saves automatically shortly after you stop typing.
struct NoteView: View {
    let noteID: String

    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var map
    @State private var text = ""
    @State private var lastSaved = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var showOrbit = true

    var body: some View {
        let cosmos = vault.cosmos
        VStack(alignment: .leading, spacing: 14) {
            Text(location.uppercased())
                .font(Theme.mono(11)).kerning(1).foregroundStyle(Theme.muted)
            Text(cosmos.title(noteID))
                .font(.system(size: 38, weight: .semibold, design: .serif))
            TextEditor(text: $text)
                .font(.system(size: 17, design: .serif))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(SpaceBackground())
        .toolbar {
            ToolbarItemGroup {
                Button("Показать на карте", systemImage: "sparkles") {
                    flush()
                    map.pendingStar = noteID
                    vault.selection = .map
                }
                Button("Орбита", systemImage: "sidebar.right") { showOrbit.toggle() }
            }
        }
        .inspector(isPresented: $showOrbit) {
            NoteOrbitInspector(noteID: noteID)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 340)
        }
        .onAppear {
            text = vault.text(of: noteID)
            lastSaved = text
        }
        .onChange(of: text) { _, newValue in
            guard newValue != lastSaved else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                save(newValue)
            }
        }
        .onDisappear { flush() }
    }

    private var location: String {
        let c = vault.cosmos
        let u = c.universeOf[noteID].flatMap { c.universe($0)?.name } ?? ""
        let k = c.constellationOf[noteID].flatMap { c.constellationName[$0] } ?? ""
        return "\(u) › \(k)"
    }

    private func save(_ value: String) {
        vault.save(noteID, text: value)
        lastSaved = value
    }

    private func flush() {
        saveTask?.cancel()
        if text != lastSaved { save(text) }
    }
}

/// Right-hand "Орбита": what this note links to and what links back.
struct NoteOrbitInspector: View {
    let noteID: String
    @Environment(VaultStore.self) private var vault

    var body: some View {
        let c = vault.cosmos
        let back = Set(c.backlinks(to: noteID))
        let outgoing = (c.neighbors[noteID] ?? []).subtracting(back).sorted { c.title($0) < c.title($1) }
        List {
            Section("Входящие связи · \(back.count)") {
                ForEach(back.sorted { c.title($0) < c.title($1) }, id: \.self) { row($0) }
            }
            Section("Ссылки отсюда · \(outgoing.count)") {
                ForEach(outgoing, id: \.self) { row($0) }
            }
            if let tags = c.notes[noteID]?.tags, !tags.isEmpty {
                Section("Теги") {
                    Text(tags.map { "#" + $0 }.joined(separator: "  ")).foregroundStyle(Theme.muted)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ id: String) -> some View {
        let c = vault.cosmos
        return Button { vault.selection = .note(id) } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Theme.color(forUniverseIndex: c.universeOf[id].flatMap { c.universeIndex[$0] } ?? 0))
                    .frame(width: 8, height: 8)
                Text(c.title(id)).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

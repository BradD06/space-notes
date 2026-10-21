import SwiftUI
import UniformTypeIdentifiers

/// First launch: pick a folder with markdown notes (an Obsidian vault works as is).
struct OnboardingView: View {
    @Environment(VaultStore.self) private var vault
    @State private var picking = false
    @State private var creatingVault = false

    var body: some View {
        ZStack {
            SpaceBackground()
            VStack(spacing: 22) {
                Image(systemName: "circle.circle")
                    .font(.system(size: 54, weight: .thin))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Space")
                    .font(.system(size: 44, weight: .semibold, design: .serif))
                Text("Выбери папку с заметками в формате Markdown.\nХранилище Obsidian подойдёт без изменений — лучше начни с копии.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: 420)
                Button {
                    picking = true
                } label: {
                    Label("Открыть хранилище", systemImage: "folder")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)

                Button {
                    creatingVault = true
                } label: {
                    Label("Создать новое хранилище", systemImage: "externaldrive.badge.plus")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(40)
            .glassEffect(.regular, in: .rect(cornerRadius: 36))
            .padding(24)
        }
        .sheet(isPresented: $creatingVault) { CreateVaultSheet() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await vault.open(url) }
            case .failure(let error): vault.errorMessage = error.localizedDescription
            }
        }
    }
}


/// "New vault": a name, an optional starter universe, and the place on disk to create it.
/// The place is chosen in the system folder picker — that is also what gives the sandboxed app
/// permission to write there.
struct CreateVaultSheet: View {
    @Environment(VaultStore.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Space"
    @State private var withStarter = true
    @State private var picking = false
    @State private var error: String?
    @State private var working = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Новое хранилище", systemImage: "externaldrive.badge.plus")
                .font(.title2.weight(.semibold))
            Text("Обычная папка с Markdown-файлами. Её можно открыть и в Space, и в Obsidian, и в любом редакторе.")
                .font(.callout).foregroundStyle(Theme.muted)

            TextField("Название хранилища", text: $name)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .focused($nameFocused)
                .onSubmit { picking = true }

            Toggle(isOn: $withStarter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Добавить первую вселенную с примерами")
                    Text("Пара связанных звёзд, чтобы карта сразу ожила.").font(.caption).foregroundStyle(Theme.muted)
                }
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(Color(hex: 0xE8826B))
            }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button {
                    picking = true
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Выбрать, где создать…") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .onAppear { nameFocused = true }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let parent):
                working = true
                Task {
                    do {
                        try await vault.createVault(named: name, in: parent, withStarter: withStarter)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                    working = false
                }
            case .failure(let e):
                error = e.localizedDescription
            }
        }
        #if os(macOS)
        .fileDialogMessage(Text("Выбери папку, внутри которой появится хранилище «\(name)»."))
        .fileDialogConfirmationLabel(Text("Создать здесь"))
        #endif
    }
}

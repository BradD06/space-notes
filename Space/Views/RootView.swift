import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(VaultStore.self) private var vault

    var body: some View {
        Group {
            if vault.rootURL == nil {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .alert("Space", isPresented: Binding(
            get: { vault.errorMessage != nil },
            set: { if !$0 { vault.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vault.errorMessage ?? "")
        }
    }
}

/// Sidebar with universes and notes, detail with the map or a note.
struct MainView: View {
    @Environment(VaultStore.self) private var vault
    @State private var map = MapModel()
    @State private var pickingAccess = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ZStack {
                switch vault.selection {
                case .note(let id):
                    NoteView(noteID: id).id(id)
                default:
                    CosmosMapView()
                }
            }
            .overlay(alignment: .top) {
                if vault.needsWriteAccess {
                    WriteAccessBanner { pickingAccess = true }
                        .padding(.top, 70)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: vault.needsWriteAccess)
            .overlay {
                if vault.isLoading {
                    ProgressView("Читаю хранилище…")
                        .padding(24)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
        }
        .environment(map)
        // The system folder picker is the only way a sandboxed app gets write access to a folder.
        .fileImporter(isPresented: $pickingAccess, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await vault.grantAccess(with: url) } }
        }
        .fileDialogDefaultDirectory(vault.rootURL?.deletingLastPathComponent())
        #if os(macOS)
        .fileDialogMessage(Text("Выбери папку хранилища «\(vault.vaultName)», чтобы Space мог создавать и сохранять заметки."))
        .fileDialogConfirmationLabel(Text("Дать доступ"))
        #endif
    }
}

/// Shown when the vault is read-only for the app.
private struct WriteAccessBanner: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Хранилище открыто только для чтения").font(.callout.weight(.semibold))
                Text("Разреши запись, чтобы создавать вселенные, созвездия и звёзды и сохранять правки.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Button("Дать доступ", action: action)
                .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
    }
}

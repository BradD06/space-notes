import SwiftUI

/// The map of the vault in three levels: the atlas of all universes → one universe → the orbit of a note.
/// Each level names only its own things, so nothing piles up. A vault of a few notes skips the atlas
/// and shows every star with its name.
struct CosmosMapView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var model

    var body: some View {
        let atlas = model.atlas(vault)
        GeometryReader { geo in
            let wide = geo.size.width >= 900
            VStack(spacing: 12) {
                MapTopBar(atlas: atlas, compact: geo.size.width < 760)
                if wide {
                    HStack(alignment: .top, spacing: 12) {
                        level(atlas).frame(maxWidth: .infinity, maxHeight: .infinity)
                        panel(atlas)
                            .frame(width: 290)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                } else {
                    level(atlas).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            if model.showPanel {
                                panel(atlas)
                                    .frame(maxHeight: geo.size.height * 0.5)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .animation(.smooth(duration: 0.3), value: model.showPanel)
                }
            }
            .padding(12)
        }
        .background(SpaceBackground())
        .task(id: vault.generation) {
            model.sync(with: vault.cosmos, atlas: atlas)
            takePendingStar()
        }
        .onAppear { takePendingStar() }
    }

    @ViewBuilder
    private func level(_ atlas: Atlas) -> some View {
        Group {
            switch model.focus {
            case .star(let id) where vault.cosmos.notes[id] != nil:
                OrbitLevel(id: id, atlas: atlas)
            case _ where atlas.isTiny:
                TinyMapView(atlas: atlas)
            case .universe(let id):
                if let group = atlas.group(id) { UniverseLevel(group: group, atlas: atlas) } else { AtlasLevel(atlas: atlas) }
            default:
                AtlasLevel(atlas: atlas)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .id(levelKey)
    }

    @ViewBuilder
    private func panel(_ atlas: Atlas) -> some View {
        Group {
            switch model.focus {
            case .star(let id) where vault.cosmos.notes[id] != nil:
                OrbitPanel(id: id, atlas: atlas)
            case .universe(let id) where atlas.group(id) != nil && !atlas.isTiny:
                UniversePanel(group: atlas.group(id)!, atlas: atlas)
            default:
                AtlasPanel(atlas: atlas)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var levelKey: String {
        switch model.focus {
        case .multiverse: "atlas"
        case .universe(let id): "u" + id
        case .star(let id): "s" + id
        }
    }

    private func takePendingStar() {
        guard let id = model.pendingStar else { return }
        model.pendingStar = nil
        if vault.cosmos.notes[id] != nil { model.go(to: .star(id)) }
    }
}

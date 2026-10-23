import SwiftUI

/// A capsule of glass: a faint wash that brightens under the pointer and sinks in when pressed.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: false)
    }
}

/// The main action: a solid accent capsule that glows under the pointer and sinks in when pressed.
struct GlowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: true)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var spaceGlass: GlassButtonStyle { GlassButtonStyle() }
}

extension ButtonStyle where Self == GlowButtonStyle {
    static var spaceGlow: GlowButtonStyle { GlowButtonStyle() }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(prominent ? (enabled ? Color.white : Theme.muted) : Theme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background {
                Capsule().fill(fill(pressed: pressed))
                    // Pressed: a shadow inside the top edge, as if the button sank into the glass.
                    .overlay(Capsule().strokeBorder(Color.black.opacity(pressed ? 0.28 : 0), lineWidth: 2).blur(radius: 2).offset(y: 1).clipShape(Capsule()))
            }
            .overlay(Capsule().strokeBorder(prominent ? Color.white.opacity(enabled ? 0.28 : 0) : Theme.glassEdge, lineWidth: 1).mask(
                LinearGradient(colors: [.white, prominent ? .clear : .white], startPoint: .top, endPoint: .center)))
            // Glow: a soft halo, and a ring of light on hover.
            .background(Capsule().stroke(Theme.accentGlow, lineWidth: prominent && hover && enabled && !pressed ? 8 : 0).blur(radius: 1))
            .shadow(color: prominent && enabled && !pressed ? Theme.accentGlow : .clear, radius: hover ? 16 : 11, y: hover ? 6 : 4)
            .opacity(enabled || prominent ? 1 : 0.45)
            .offset(y: pressed ? 1 : 0)
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .animation(.smooth(duration: 0.15), value: hover)
            .animation(.smooth(duration: 0.08), value: pressed)
    }

    private func fill(pressed: Bool) -> Color {
        if prominent { return enabled ? Theme.accent : Theme.wash.opacity(0.13) }
        return Theme.wash.opacity(pressed || hover ? 0.13 : 0.07)
    }
}

/// The dock: a strip of thin glass floating at the bottom of the window with what is needed from anywhere —
/// the star map (⌘G), a new star, and the inbox. On narrow screens only the icons stay.
struct BottomDock: View {
    var compact = false
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var map
    @State private var creating: CreateKind?

    var body: some View {
        let inbox = vault.cosmos.universes.first { $0.name == Cosmos.inboxName }
        HStack(spacing: 6) {
            DockButton(title: "Карта звёзд", help: "Карта звёзд (⌘G)", selected: vault.selection == .map, compact: compact, orb: true) {
                vault.selection = .map
                map.go(to: .multiverse)
            } icon: {
                Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(RadialGradient(colors: [Color(hex: 0x9C8FFF), Color(hex: 0x4A3BD6)],
                                                             center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 26)))
                    .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                    .shadow(color: Theme.accentGlow, radius: 9)
            }
            .keyboardShortcut("g", modifiers: .command)
            Rectangle().fill(Theme.line).frame(width: 1, height: 26)
            DockButton(title: "Новая звезда", help: "Новая звезда", compact: compact) {
                creating = .star(universe: (inbox ?? vault.cosmos.universes.first)?.id ?? "", constellation: "")
            } icon: {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
            }
            if let inbox {
                DockButton(title: "Входящие", help: "Входящие на карте", badge: inbox.starCount, compact: compact) {
                    vault.selection = .map
                    map.go(to: .universe(inbox.id))
                } icon: {
                    Image(systemName: "tray").font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .padding(6)
        .background(GlassPanel(radius: 32, thickness: .thin))
        .sheet(item: $creating) { kind in CreateSheet(kind: kind) }
    }
}

private struct DockButton<Icon: View>: View {
    let title: String
    let help: String
    var badge: Int? = nil
    var selected = false
    var compact = false
    var orb = false
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                if !compact {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                }
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Color(hex: 0xD12F35)))
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, orb ? 4 : 14).padding(.trailing, compact ? (orb ? 4 : 14) : 16)
            .frame(height: 46)
            .background(Capsule().fill(orb ? Theme.accent.opacity(hover || selected ? 0.5 : 0.3) : Theme.wash.opacity(hover ? 0.13 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.15), value: hover)
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .tip(help)
    }
}

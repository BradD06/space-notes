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

/// "Карта звёзд": a floating slab of glass in the window's lower right corner, on every screen (⌘G).
/// A glowing star-orb, the name, and the shortcut; on narrow windows only the orb.
struct StarMapButton: View {
    let selected: Bool
    var compact = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(RadialGradient(colors: [Color(hex: 0x9C8FFF), Color(hex: 0x4A3BD6)],
                                                             center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 30)))
                    .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                    .shadow(color: Theme.accentGlow, radius: selected ? 14 : 9)
                if !compact {
                    Text("Карта звёзд")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("⌘G")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.wash.opacity(0.13)))
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, compact ? 8 : 18)
            .frame(height: 60)
            .background(GlassPanel(radius: 30))
            .overlay(Capsule().strokeBorder(Theme.accentText.opacity(selected ? 0.7 : 0), lineWidth: 1.5))
            // Hover: lifts a little and lights up.
            .shadow(color: hover || selected ? Theme.accentGlow : .clear, radius: 22, y: 10)
            .offset(y: hover ? -2 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.15), value: hover)
        .keyboardShortcut("g", modifiers: .command)
        .accessibilityLabel("Открыть карту звёзд")
        .tip("Карта звёзд (⌘G)")
    }
}

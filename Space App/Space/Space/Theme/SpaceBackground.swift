import SwiftUI

/// The scene behind every screen: a deliberately colourful nebula (night sky in the dark theme, dawn in the light one),
/// faint orbits and stars. The glass panels need something lively behind them to look like glass at all.
struct SpaceBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if scheme == .light { dawn } else { night }
            Orbits(color: scheme == .light ? Color(hex: 0x28204F, opacity: 0.06) : Color.white.opacity(0.07))
            if scheme != .light { StarDust() }
        }
        .ignoresSafeArea()
        // Pure decoration: it reaches past its view's edges (under bars and tabs), so it must never take clicks.
        .allowsHitTesting(false)
    }

    private var night: some View {
        ZStack {
            // Slightly see-through, so the blurred desktop still tints the window.
            Color(hex: 0x070814, opacity: 0.9)
            nebula(0x7C5CFF, 0.55, x: 0.12, y: 0.18, size: 1.0)
            nebula(0x00B4C8, 0.38, x: 0.88, y: 0.26, size: 0.9)
            nebula(0xFF7846, 0.40, x: 0.62, y: 0.96, size: 0.9)
            nebula(0xFFFFFF, 0.10, x: 0.46, y: 0.46, size: 0.4)
        }
    }

    private var dawn: some View {
        ZStack {
            LinearGradient(stops: [.init(color: Color(hex: 0xF4D4BE), location: 0), .init(color: Color(hex: 0xE7DAF6), location: 0.4),
                                   .init(color: Color(hex: 0xC7DAFF), location: 0.72), .init(color: Color(hex: 0xF2E4D4), location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            nebula(0x6E5AFF, 0.45, x: 0.30, y: 0.30, size: 0.85)
            nebula(0x281E46, 0.40, x: 0.96, y: 0.90, size: 0.75)
            nebula(0x3C2D5A, 0.30, x: 0.0, y: 1.0, size: 0.6)
            // Two beams of light across the sky.
            beam(at: 0.36, width: 0.09, opacity: 0.75)
            beam(at: 0.63, width: 0.06, opacity: 0.55)
        }
    }

    private func beam(at center: CGFloat, width: CGFloat, opacity: Double) -> some View {
        LinearGradient(stops: [.init(color: .clear, location: center - width), .init(color: Color.white.opacity(opacity), location: center),
                               .init(color: .clear, location: center + width)],
                       startPoint: UnitPoint(x: 0, y: 0.2), endPoint: UnitPoint(x: 1, y: 0.8))
    }

    private func nebula(_ hex: UInt32, _ opacity: Double, x: CGFloat, y: CGFloat, size: CGFloat) -> some View {
        GeometryReader { geo in
            let d = max(geo.size.width, geo.size.height) * size
            RadialGradient(colors: [Color(hex: hex, opacity: opacity), .clear], center: .center, startRadius: 0, endRadius: d / 2)
                .frame(width: d, height: d)
                .position(x: geo.size.width * x, y: geo.size.height * y)
        }
    }
}

/// Behind the content of a pane. On the Mac the pane is already a slab of glass over the window's nebula, so
/// nothing is drawn; on iPhone and iPad (no glass panes) it is the nebula under a frosted wash.
struct PaneBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        #if os(macOS)
        Color.clear
        #else
        SpaceBackground()
            .overlay(Theme.glassTint.opacity(scheme == .light ? 0.72 : 0.62).ignoresSafeArea())
            .allowsHitTesting(false)
        #endif
    }
}

/// Faint concentric orbits around a point low on the right, the app's star map hinted at in the backdrop.
private struct Orbits: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width * 0.72, y: size.height * 0.62)
            let reach = hypot(max(c.x, size.width - c.x), max(c.y, size.height - c.y))
            var r: CGFloat = 47
            while r < reach {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r * 1.25, y: c.y - r, width: r * 2.5, height: r * 2)), with: .color(color), lineWidth: 1)
                r += 48
            }
        }
    }
}

private struct StarDust: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 7
            func rnd() -> CGFloat {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
            }
            for _ in 0..<140 {
                let p = CGPoint(x: rnd() * size.width, y: rnd() * size.height)
                let r: CGFloat = rnd() < 0.85 ? 0.6 : 1.1
                ctx.opacity = 0.15 + rnd() * 0.55
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }
}

#if os(macOS)
import AppKit

/// The desktop behind the window, blurred (the window's own frosted glass).
struct DesktopBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
#endif

import SwiftUI

/// Deep space behind every screen: soft nebulae plus a quiet star field.
/// Liquid Glass panels need something behind them to refract — this is it.
struct SpaceBackground: View {
    var body: some View {
        ZStack {
            // A soft slate gradient with a little light from the top, and very faint dust.
            // Translucent graphite: the blurred desktop shows through, as frosted glass.
            LinearGradient(colors: [Color(hex: 0x2B2B2E, opacity: 0.55), Color(hex: 0x1F1F22, opacity: 0.66), Color(hex: 0x161618, opacity: 0.76)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            nebula(0xFFFFFF, 0.04, x: 0.35, y: 0.0, size: 1.1)
            nebula(0xFFFFFF, 0.025, x: 0.85, y: 0.9, size: 0.9)
            StarDust()
        }
        .ignoresSafeArea()
        // Pure decoration: it reaches past its view's edges (under bars and tabs), so it must never take clicks.
        .allowsHitTesting(false)
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

private struct StarDust: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 7
            func rnd() -> CGFloat {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
            }
            for _ in 0..<90 {
                let p = CGPoint(x: rnd() * size.width, y: rnd() * size.height)
                let r: CGFloat = rnd() < 0.85 ? 0.6 : 1.1
                ctx.opacity = 0.04 + rnd() * 0.14
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Theme.ink))
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

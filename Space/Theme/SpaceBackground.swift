import SwiftUI

/// Deep space behind every screen: soft nebulae plus a quiet star field.
/// Liquid Glass panels need something behind them to refract — this is it.
struct SpaceBackground: View {
    var body: some View {
        ZStack {
            Theme.ground
            nebula(0x8FB3FF, 0.16, x: 0.12, y: 0.08, size: 0.75)
            nebula(0xF2B544, 0.11, x: 0.92, y: 0.22, size: 0.6)
            nebula(0xC9A0FF, 0.13, x: 0.55, y: 1.05, size: 0.85)
            nebula(0x7FD1A8, 0.06, x: 0.38, y: 0.45, size: 0.5)
            StarDust()
        }
        .ignoresSafeArea()
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
            for _ in 0..<160 {
                let p = CGPoint(x: rnd() * size.width, y: rnd() * size.height)
                let r: CGFloat = rnd() < 0.85 ? 0.6 : 1.1
                ctx.opacity = 0.12 + rnd() * 0.35
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Theme.ink))
            }
        }
        .allowsHitTesting(false)
    }
}

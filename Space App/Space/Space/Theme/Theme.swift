import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Theme {
    // Translucent glass over a nebula: cool ink-blue glass in the dark theme, milky glass in the light one.
    // Text is always a solid colour (never see-through), picked to stay readable over the brightest spot behind it.
    static let ground = adaptive(dark: 0x10121E, light: 0xF4F1FA)
    static let sidebar = adaptive(dark: 0x161827, light: 0xFFFFFF)
    static let surface = adaptive(dark: 0x1E2032, light: 0xF7F5FC)
    static let surfaceHigh = adaptive(dark: 0x2A2D44, light: 0xECE8F6)
    static let line = adaptive(dark: 0xFFFFFF, light: 0x1E193C, darkOpacity: 0.10, lightOpacity: 0.10)
    static let ink = adaptive(dark: 0xF4F5FB, light: 0x15141D)
    static let muted = adaptive(dark: 0xA6A9B9, light: 0x47455A)
    static let faint = adaptive(dark: 0x5A5D70, light: 0x9A98AC)
    static let accent = adaptive(dark: 0x5B4BEA, light: 0x4F3FE0)
    /// The accent as text or an outline on glass (the filled accent is too dark to read on dark glass).
    static let accentText = adaptive(dark: 0xBDB4FF, light: 0x4434C9)
    static let accentGlow = adaptive(dark: 0x7C6CFF, light: 0x4F3FE0, darkOpacity: 0.5, lightOpacity: 0.35)

    /// Light washes on glass: hover, chips, guide lines. White in the dark theme, ink in the light one.
    static let wash = adaptive(dark: 0xFFFFFF, light: 0x1E193C)
    /// A small solid chip floating over glass (the fold arrow, labels over pictures).
    static let chip = adaptive(dark: 0x0A0C16, light: 0xFFFFFF, darkOpacity: 0.78, lightOpacity: 0.88)

    // The glass itself.
    static let glassTint = adaptive(dark: 0x10121E, light: 0xFFFFFF)
    static let glassEdge = adaptive(dark: 0xFFFFFF, light: 0xFFFFFF, darkOpacity: 0.13, lightOpacity: 0.6)
    static let glassSheen = adaptive(dark: 0xFFFFFF, light: 0xFFFFFF, darkOpacity: 0.12, lightOpacity: 0.55)
    static let glassRim = adaptive(dark: 0xFFFFFF, light: 0xFFFFFF, darkOpacity: 0.55, lightOpacity: 1)
    static let glassRim2 = adaptive(dark: 0xA096FF, light: 0xFFFFFF, darkOpacity: 0.35, lightOpacity: 0.6)
    static let glassDrop = adaptive(dark: 0x000000, light: 0x32285A, darkOpacity: 0.45, lightOpacity: 0.18)

    /// A colour with one value for the dark theme and one for the light theme, resolved when drawn.
    static func adaptive(dark: UInt32, light: UInt32, darkOpacity: Double = 1, lightOpacity: Double = 1) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
                ? NSColor(hex: light, alpha: lightOpacity) : NSColor(hex: dark, alpha: darkOpacity)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(hex: light, alpha: lightOpacity) : UIColor(hex: dark, alpha: darkOpacity)
        })
        #endif
    }

    /// Corner radii: rounded, soft panels in the spirit of macOS 26.
    static let panelRadius: CGFloat = 20
    static let rowRadius: CGFloat = 10

    /// One colour per universe, in universe order. Similar lightness so no universe shouts louder.
    static let universePalette: [Color] = [
        Color(hex: 0x8FB3FF), Color(hex: 0xF2B544), Color(hex: 0xE8826B), Color(hex: 0x7FD1A8),
        Color(hex: 0xC9A0FF), Color(hex: 0xF28FB8), Color(hex: 0xD9D4C7), Color(hex: 0x6EC6E8),
        Color(hex: 0xB8E07A), Color(hex: 0xFFB38A)
    ]

    static func color(forUniverseIndex i: Int) -> Color { universePalette[i % universePalette.count] }

    /// The colour of a universe: the one the user picked, white by default.
    @MainActor static func color(forUniverse id: String?) -> Color {
        UniverseColors.shared.color(for: id)
    }

    static let serif = Font.system(.body, design: .serif)
    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

#if os(macOS)
extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#else
extension UIColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#endif

/// The app's look: dark or light, the user's choice (dark by default).
enum Appearance: String {
    case dark, light
    static let key = "space.appearance"
    var scheme: ColorScheme { self == .light ? .light : .dark }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Stable across launches (unlike `hashValue`), used to give every star its own drift.
nonisolated func stableSeed(_ s: String) -> UInt64 {
    var h: UInt64 = 1_469_598_103_934_665_603
    for b in s.utf8 { h ^= UInt64(b); h = h &* 1_099_511_628_211 }
    return h
}

/// Russian plural: plural(1, "звезда", "звезды", "звёзд") → "звезда".
nonisolated func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

/// Colours the user picked for universes, remembered per vault. Universes without a choice are white.
@MainActor
@Observable
final class UniverseColors {
    static let shared = UniverseColors()

    struct Swatch: Identifiable, Hashable { let name: String; let hex: UInt32; var id: UInt32 { hex } }

    static let white: UInt32 = 0xF1F0EC
    static let swatches: [Swatch] = [
        Swatch(name: "Белый", hex: white), Swatch(name: "Золотой", hex: 0xF2B544), Swatch(name: "Синий", hex: 0x8FB3FF),
        Swatch(name: "Коралловый", hex: 0xE8826B), Swatch(name: "Мятный", hex: 0x7FD1A8), Swatch(name: "Лиловый", hex: 0xC9A0FF),
        Swatch(name: "Розовый", hex: 0xF28FB8), Swatch(name: "Бирюзовый", hex: 0x6EC6E8), Swatch(name: "Лаймовый", hex: 0xB8E07A),
        Swatch(name: "Персиковый", hex: 0xFFB38A), Swatch(name: "Песочный", hex: 0xD9C9A3), Swatch(name: "Серебряный", hex: 0xA9B0C0)
    ]

    private(set) var hexes: [String: UInt32] = [:]
    private var vaultKey = ""
    @ObservationIgnored private var cache: [String: Color] = [:]

    /// Switch to the colours of another vault.
    func load(vault name: String) {
        vaultKey = "space.universeColors." + name
        let raw = UserDefaults.standard.dictionary(forKey: vaultKey) as? [String: Int] ?? [:]
        hexes = raw.mapValues { UInt32($0) }
        cache = [:]
    }

    func hex(for id: String?) -> UInt32 { id.flatMap { hexes[$0] } ?? Self.white }

    func color(for id: String?) -> Color {
        let h = hex(for: id)
        if let c = cache[String(h)] { return c }
        let c = Color(hex: h)
        cache[String(h)] = c
        return c
    }

    func set(_ hex: UInt32, for id: String) {
        if hex == Self.white { hexes[id] = nil } else { hexes[id] = hex }
        guard !vaultKey.isEmpty else { return }
        UserDefaults.standard.set(hexes.mapValues { Int($0) }, forKey: vaultKey)
    }
}

/// A rounded pane of translucent glass: the scene shows through, blurred and toned down (darker in the dark theme,
/// lighter in the light one) so text on it stays readable. A diagonal sheen and a rim that glows brighter at the
/// top-left make it read as a slab of glass. Used only as a background, so it never takes clicks.
/// `density` scales how solid it is: 1 is the sidebar's glass, more for panes full of text.
struct GlassPanel: View {
    var radius: CGFloat = Theme.panelRadius
    var density: Double = 1
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let alpha = min(0.95, (scheme == .light ? 0.56 : 0.42) * density)
        Group {
            if reduceTransparency {
                // Asked for less transparency: nearly solid, no blur.
                shape.fill(Theme.glassTint.opacity(0.97))
            } else {
                Color.clear
                    .glassEffect(.regular.tint(Theme.glassTint.opacity(alpha)), in: .rect(cornerRadius: radius))
                    // A wash that tones the scene behind down, like the lens of the mockup.
                    .overlay(shape.fill(Theme.glassTint.opacity(alpha * 0.55)))
                    // The diagonal highlight, as if light falls on the glass from the top left.
                    .overlay(shape.fill(LinearGradient(colors: [Theme.glassSheen, .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.42, y: 0.5))))
            }
        }
        .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
        // The glowing rim: bright at the top left, a cooler glint at the bottom right, clear between.
        .overlay(shape.strokeBorder(LinearGradient(stops: [.init(color: Theme.glassRim, location: 0), .init(color: .clear, location: 0.3),
                                                           .init(color: .clear, location: 0.7), .init(color: Theme.glassRim2, location: 1)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: Theme.glassDrop, radius: 26, y: 12)
        .allowsHitTesting(false)
    }
}

/// Dates in Russian, whatever the system's language: "19 октября", "19 окт", "5 минут назад".
nonisolated enum RuDate {
    static let locale = Locale(identifier: "ru_RU")
    static func dayMonth(_ d: Date, short: Bool = false) -> String {
        d.formatted(Date.FormatStyle(locale: locale).day().month(short ? .abbreviated : .wide))
    }
    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.dateTimeStyle = .named
        return f.localizedString(for: d, relativeTo: Date())
    }
}

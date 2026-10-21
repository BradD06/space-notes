import SwiftUI

enum Theme {
    // Graphite glass: neutral greys over a blurred desktop, one red accent for what is selected.
    static let ground = Color(hex: 0x1C1C1E)
    static let sidebar = Color(hex: 0x2A2A2D)
    static let surface = Color(hex: 0x2C2C2F)
    static let surfaceHigh = Color(hex: 0x38383C)
    static let line = Color.white.opacity(0.08)
    static let ink = Color(hex: 0xF2F2F2)
    static let muted = Color(hex: 0x9E9EA4)
    static let faint = Color(hex: 0x4A4A4F)
    static let accent = Color(hex: 0xC8312B)

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

/// A rounded pane of Liquid Glass, tinted to the slate theme. Used only as a background, so it never takes clicks.
struct GlassPanel: View {
    var radius: CGFloat = Theme.panelRadius
    var tint: Color = Theme.ground.opacity(0.45)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Color.clear
            .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: radius))
            // A soft sheen from the top, like frosted glass catching light.
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.06), Color.white.opacity(0.14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
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

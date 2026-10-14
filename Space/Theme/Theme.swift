import SwiftUI

enum Theme {
    static let ground = Color(hex: 0x07080C)
    static let ink = Color(hex: 0xECE8DF)
    static let muted = Color(hex: 0x9A9FAD)
    static let faint = Color(hex: 0x3A4050)
    static let accent = Color(hex: 0xF2B544)

    /// One colour per universe, in universe order. Similar lightness so no universe shouts louder.
    static let universePalette: [Color] = [
        Color(hex: 0x8FB3FF), Color(hex: 0xF2B544), Color(hex: 0xE8826B), Color(hex: 0x7FD1A8),
        Color(hex: 0xC9A0FF), Color(hex: 0xF28FB8), Color(hex: 0xD9D4C7), Color(hex: 0x6EC6E8),
        Color(hex: 0xB8E07A), Color(hex: 0xFFB38A)
    ]

    static func color(forUniverseIndex i: Int) -> Color { universePalette[i % universePalette.count] }

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
func stableSeed(_ s: String) -> UInt64 {
    var h: UInt64 = 1_469_598_103_934_665_603
    for b in s.utf8 { h ^= UInt64(b); h = h &* 1_099_511_628_211 }
    return h
}

/// Russian plural: plural(1, "звезда", "звезды", "звёзд") → "звезда".
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

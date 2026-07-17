import SwiftUI

/// Visual palette for a rendered mahjong tile. The five themes are transcribed
/// verbatim from `MahjongTile.html` (design spec §2.1 / §3.2).
///
/// Convention: **jade** = tiles rendered inside the app; **ivory** = tiles
/// composited over the live camera (physical look).
public struct TileTheme: Sendable, Hashable {
    public var face1: Color
    public var face2: Color
    public var border: Color
    public var shadowColor: Color
    public var shadowBlur: CGFloat   // reference px at w = 64; scaled by width
    public var shadowY: CGFloat      // reference px at w = 64
    public var goldInnerRing: Bool   // jade's inset gold ring
    public var dot: Color
    public var dotRing: Color
    public var bam: Color
    public var num: Color
    public var sub: Color
    public var wind: Color
    public var dragonRed: Color
    public var dragonGreen: Color
    public var dragonWhite: Color
    public var usesSerif: Bool
    public var isGlass: Bool

    public init(face1: Color, face2: Color, border: Color, shadowColor: Color,
                shadowBlur: CGFloat, shadowY: CGFloat, goldInnerRing: Bool = false,
                dot: Color, dotRing: Color, bam: Color, num: Color, sub: Color, wind: Color,
                dragonRed: Color, dragonGreen: Color, dragonWhite: Color,
                usesSerif: Bool, isGlass: Bool = false) {
        self.face1 = face1; self.face2 = face2; self.border = border
        self.shadowColor = shadowColor; self.shadowBlur = shadowBlur; self.shadowY = shadowY
        self.goldInnerRing = goldInnerRing
        self.dot = dot; self.dotRing = dotRing; self.bam = bam
        self.num = num; self.sub = sub; self.wind = wind
        self.dragonRed = dragonRed; self.dragonGreen = dragonGreen; self.dragonWhite = dragonWhite
        self.usesSerif = usesSerif; self.isGlass = isGlass
    }
}

public extension TileTheme {
    /// Default in-app tile: dark green + gold.
    static let jade = TileTheme(
        face1: Color(hex: 0x1A5B4E), face2: Color(hex: 0x0E3A31), border: Color(hex: 0x08251F),
        shadowColor: Color(white: 0, opacity: 0.42), shadowBlur: 14, shadowY: 5, goldInnerRing: true,
        dot: Color(hex: 0xE7C877), dotRing: Color(hex: 0xF0D89A), bam: Color(hex: 0xE7C877),
        num: Color(hex: 0xEBD9A8), sub: Color(hex: 0xE9C56F), wind: Color(hex: 0xEBD9A8),
        dragonRed: Color(hex: 0xE9B44C), dragonGreen: Color(hex: 0xEBD9A8), dragonWhite: Color(hex: 0xEBD9A8),
        usesSerif: true)

    /// Warm aged bone — used for camera-detected tiles.
    static let ivory = TileTheme(
        face1: Color(hex: 0xF8EFDB), face2: Color(hex: 0xE7D2AC), border: Color(hex: 0xD8C299),
        shadowColor: Color(hex: 0x462D0A, alpha: 0.24), shadowBlur: 12, shadowY: 5,
        dot: Color(hex: 0x2B57A6), dotRing: Color(hex: 0xA8342A), bam: Color(hex: 0x1C7040),
        num: Color(hex: 0x1C7040), sub: Color(hex: 0xA8342A), wind: Color(hex: 0x2A2016),
        dragonRed: Color(hex: 0xA8342A), dragonGreen: Color(hex: 0x1C7040), dragonWhite: Color(hex: 0x2B57A6),
        usesSerif: true)

    /// Cream paper, serif — the traditional look.
    static let classic = TileTheme(
        face1: Color(hex: 0xFDFAF3), face2: Color(hex: 0xF1E9D6), border: Color(hex: 0xE7DDC6),
        shadowColor: Color(hex: 0x3C2A0F, alpha: 0.16), shadowBlur: 6, shadowY: 3,
        dot: Color(hex: 0x2E5AAC), dotRing: Color(hex: 0xC9302C), bam: Color(hex: 0x1E7A44),
        num: Color(hex: 0x1E7A44), sub: Color(hex: 0xB23A2E), wind: Color(hex: 0x26364F),
        dragonRed: Color(hex: 0xB23A2E), dragonGreen: Color(hex: 0x1E7A44), dragonWhite: Color(hex: 0x2E5AAC),
        usesSerif: true)

    /// Clinical white, system font.
    static let flat = TileTheme(
        face1: .white, face2: .white, border: Color(hex: 0xE5E5EA),
        shadowColor: Color(white: 0, opacity: 0.10), shadowBlur: 2, shadowY: 1,
        dot: Color(hex: 0x1C1C1E), dotRing: Color(hex: 0x1C1C1E), bam: Color(hex: 0x1C1C1E),
        num: Color(hex: 0x1C1C1E), sub: Color(hex: 0xD33A2C), wind: Color(hex: 0x1C1C1E),
        dragonRed: Color(hex: 0xD33A2C), dragonGreen: Color(hex: 0x1C1C1E), dragonWhite: Color(hex: 0x2E6BD6),
        usesSerif: false)

    /// Frosted translucent, all-white marks.
    static let glass = TileTheme(
        face1: Color(white: 1, opacity: 0.16), face2: Color(white: 1, opacity: 0.05),
        border: Color(white: 1, opacity: 0.55),
        shadowColor: Color(white: 0, opacity: 0.28), shadowBlur: 22, shadowY: 8,
        dot: .white, dotRing: .white, bam: .white, num: .white, sub: .white, wind: .white,
        dragonRed: .white, dragonGreen: .white, dragonWhite: .white,
        usesSerif: false, isGlass: true)
}

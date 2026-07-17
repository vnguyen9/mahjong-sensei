import SwiftUI

/// The Mahjong Sensei "Jade · Dark" palette. Values transcribed from the design spec (§2.1).
public enum MJColor {
    // MARK: Greens — ground & structure
    public static let jade         = Color(hex: 0x1C6553) // primary green / brand
    public static let deepJade     = Color(hex: 0x0E3A31) // gradient dark stop
    public static let jadeCardTop  = Color(hex: 0x175247) // selected row gradient start
    public static let jadeHeroDeep = Color(hex: 0x0C3128) // result hero gradient end
    public static let jadeAccent   = Color(hex: 0x1F6F5C) // tab accent, toggle "on"
    public static let inkOnGold    = Color(hex: 0x0C2C24) // text/glyphs on gold

    // MARK: Gold / cream — accent & ink
    public static let gold         = Color(hex: 0xE7C877) // primary accent
    public static let lightGold    = Color(hex: 0xF0D89A) // big numerals, highlights
    public static let creamHeading = Color(hex: 0xF5ECD4) // screen titles
    public static let cream        = Color(hex: 0xF3E6C4) // body text (base)
    public static let creamStatus  = Color(hex: 0xF1E9D6) // status bar
    public static let jadeNumeral  = Color(hex: 0xEBD9A8) // numerals inside jade tiles

    // MARK: Semantic states — warn / avoid
    public static let amberLowConf  = Color(hex: 0xFF9F0A) // low-confidence flag
    public static let amberWarn     = Color(hex: 0xFFB84D) // warning heading, chicken glyph
    public static let amberLowLight = Color(hex: 0xFFD08A) // low-light heading
    public static let rustAvoid     = Color(hex: 0xB4542A) // AVOID tag bg

    // MARK: Alpha helpers (cream/gold ladders appear throughout the spec)
    public static func cream(_ a: Double) -> Color { Color(hex: 0xF3E6C4, alpha: a) }
    public static func gold(_ a: Double)  -> Color { Color(hex: 0xE7C877, alpha: a) }

    // MARK: Common surfaces
    public static let cardSurface   = Color(white: 1, opacity: 0.04)
    public static let cardRaised    = Color(white: 1, opacity: 0.06)
    public static let sheetGlass    = Color(hex: 0x0D2D25, alpha: 0.90) // rgba(13,45,37,.85–.94)
    public static let meldGroupBg   = Color(white: 0, opacity: 0.22)
}

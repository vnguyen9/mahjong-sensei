import SwiftUI

/// Type ramp for Mahjong Sensei. Display / Chinese / numerals use **Noto Serif TC**;
/// body & UI use **SF Pro** (system). Until the serif face is bundled we fall back to
/// the system serif design, so the app renders correctly offline from day one.
public enum MJFont {
    /// Flip to `true` once "Noto Serif TC" is bundled + registered (UIAppFonts).
    public static var bundledSerifAvailable = false
    public static let serifFamily = "Noto Serif TC"

    /// Serif display face (headings, big numerals, Chinese glyphs).
    public static func serif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if bundledSerifAvailable {
            return .custom(serifFamily, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// UI / body face (SF Pro).
    public static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // Named ramp steps (device pt ≈ mockup px × 1.72; values chosen from spec §2.2).
    public static var appTitle: Font      { serif(28, weight: .bold) }
    public static var screenTitle: Font   { serif(28, weight: .bold) }
    public static var sheetTitle: Font    { serif(20, weight: .bold) }
    public static var bigFaan: Font       { serif(64, weight: .bold) }
    public static var faanMark: Font      { serif(26, weight: .bold) }
    public static var body: Font          { ui(16, weight: .regular) }
    public static var label: Font         { ui(15, weight: .semibold) }
    public static var caption: Font       { ui(13, weight: .regular) }
    public static var eyebrow: Font       { ui(12, weight: .semibold) }
    public static var buttonLabel: Font   { ui(16, weight: .bold) }
    public static var tabLabel: Font      { ui(11, weight: .semibold) }
}

public extension Text {
    /// Applies an UPPERCASE eyebrow style (gold, tracked).
    func eyebrowStyle(_ color: Color = MJColor.gold(0.7)) -> some View {
        self.font(MJFont.eyebrow)
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

import SwiftUI
import MahjongCore

/// A procedurally-drawn mahjong tile. Every dimension is a ratio of `width`
/// (design spec §3.2), so it scales cleanly from dense grids (w≈18) to hero
/// tiles (w≈60). Pip/stick arrangements follow real HK tiles (quincunx 5, M/W
/// 8-bamboo, 3×3 9, …). Pass a `Tile` from MahjongCore and one of the `TileTheme`s.
///
/// `showsBadge` overlays a small top-right helper mark (suit number, wind letter,
/// flower/season number) so beginners can read a hand at a glance; it auto-hides
/// below ~30pt and on decorative tiles (pass `showsBadge: false`).
public struct MahjongTileView: View {
    public let tile: Tile
    public var theme: TileTheme
    public var width: CGFloat
    public var showsBadge: Bool

    public init(_ tile: Tile, theme: TileTheme = .jade, width: CGFloat = 40, showsBadge: Bool = true) {
        self.tile = tile
        self.theme = theme
        self.width = width
        self.showsBadge = showsBadge
    }

    private var height: CGFloat { (width * 1.35).rounded() }
    private var corner: CGFloat { (width * 0.19).rounded() }
    /// Central content box the pips/sticks are laid out within (leaves a margin
    /// so corner badges and the tile edge stay clear).
    private var contentW: CGFloat { width * 0.76 }
    private var contentH: CGFloat { height * 0.80 }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                face
                content
            }
            badge
        }
        .frame(width: width, height: height)
        .shadow(color: theme.shadowColor,
                radius: theme.shadowBlur / 2 * (width / 64),
                x: 0, y: theme.shadowY * (width / 64))
        .accessibilityElement()
        .accessibilityLabel(Text(tile.code))
    }

    // MARK: Face

    private var face: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(faceFill)
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            }
            .overlay {
                if theme.goldInnerRing {
                    RoundedRectangle(cornerRadius: max(2, corner - 1), style: .continuous)
                        .strokeBorder(MJColor.gold(0.30), lineWidth: 1.5)
                        .padding(1.5)
                }
            }
    }

    private var faceFill: AnyShapeStyle {
        if theme.isGlass { return AnyShapeStyle(theme.face1) }
        return AnyShapeStyle(LinearGradient(colors: [theme.face1, theme.face2],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func serif(_ size: CGFloat) -> Font {
        theme.usesSerif ? MJFont.serif(size, weight: .bold) : MJFont.ui(size, weight: .bold)
    }

    // MARK: Helper badge (top-right index mark)

    @ViewBuilder private var badge: some View {
        if showsBadge, width >= 30, let text = badgeText {
            Text(text)
                .font(MJFont.ui(max(6.5, width * 0.16), weight: .bold))
                .foregroundStyle(theme.sub.opacity(0.9))
                .shadow(color: theme.shadowColor, radius: 0.5)
                .padding(width * 0.05)
        }
    }

    /// Suits → rank number; winds → E/S/W/N; flowers/seasons → 1–4; dragons → none.
    private var badgeText: String? {
        switch tile {
        case let .suited(_, r):  return String(r)
        case let .wind(w):       return ["E", "S", "W", "N"][w.rawValue]
        case .dragon:            return nil
        case let .flower(f):     return String(f.rawValue)
        case let .season(s):     return String(s.rawValue)
        }
    }

    // MARK: Content dispatch

    @ViewBuilder private var content: some View {
        switch tile {
        case let .suited(.dots, r):
            if r == 1 { oneDot } else { dotGrid(r) }
        case let .suited(.bamboo, r):
            if r == 1 { bird } else { barGrid(r) }
        case let .suited(.characters, r):
            chars(r)
        case let .wind(w):
            glyph(windGlyph(w), color: theme.wind)
        case let .dragon(d):
            cued { dragon(d, scaled: cueEmoji != nil) }
        case let .flower(f):
            cued { glyph(flowerGlyph(f), color: theme.dragonGreen, scaled: cueEmoji != nil) }
        case let .season(s):
            cued { glyph(seasonGlyph(s), color: theme.dragonGreen, scaled: cueEmoji != nil) }
        }
    }

    /// A small emoji hint for the categories a non-Chinese reader can't parse —
    /// seasons, flowers, dragons. Follows the same visibility rules as the badge
    /// (helper marks on, tile ≥ 30pt); nil otherwise so dense strips/decor stay clean.
    private var cueEmoji: String? {
        guard showsBadge, width >= 30 else { return nil }
        switch tile {
        case let .season(s): return ["", "🌸", "☀️", "🍁", "❄️"][s.rawValue]
        case .flower:        return "🌺"
        case .dragon:        return "🐲"
        default:             return nil
        }
    }

    /// Stacks `cueEmoji` under the tile's primary glyph when one applies.
    @ViewBuilder private func cued<V: View>(@ViewBuilder _ primary: () -> V) -> some View {
        if let emoji = cueEmoji {
            VStack(spacing: width * 0.04) {
                primary()
                Text(emoji).font(.system(size: width * 0.26))
            }
        } else {
            primary()
        }
    }

    // MARK: Dots (筒) — authored per-rank layouts

    private var oneDot: some View {
        let d = width * 0.5
        return ZStack {
            Circle().fill(theme.dotRing).frame(width: d, height: d)
            Circle().fill(theme.face2).frame(width: d * 0.7, height: d * 0.7)
            Circle().fill(theme.dot).frame(width: d * 0.46, height: d * 0.46)
        }
    }

    private func dotGrid(_ n: Int) -> some View {
        let layout = Self.dotLayouts[n] ?? []
        let d = width * (Self.dotDiameter[n] ?? 0.20)
        return ZStack {
            ForEach(Array(layout.enumerated()), id: \.offset) { _, p in
                dot(d).position(x: p.x * contentW, y: p.y * contentH)
            }
        }
        .frame(width: contentW, height: contentH)
    }

    private func dot(_ size: CGFloat) -> some View {
        Circle()
            .fill(theme.dot)
            .overlay { Circle().strokeBorder(theme.dotRing, lineWidth: 1.5) }
            .overlay {
                Circle().fill(
                    RadialGradient(colors: [.white.opacity(0.55), .clear],
                                   center: .init(x: 0.38, y: 0.34),
                                   startRadius: 0, endRadius: size * 0.55)
                )
            }
            .frame(width: size, height: size)
    }

    // MARK: Bamboo (索) — authored per-rank layouts

    private func barGrid(_ n: Int) -> some View {
        let layout = Self.bambooLayouts[n] ?? []
        let size = Self.bambooSize[n] ?? (w: 0.10, h: 0.34)
        let bw = width * size.w
        let bh = width * size.h
        return ZStack {
            ForEach(Array(layout.enumerated()), id: \.offset) { _, s in
                RoundedRectangle(cornerRadius: width * 0.06)
                    .fill(theme.bam)
                    .frame(width: bw, height: bh)
                    .rotationEffect(.degrees(s.rot))
                    .position(x: s.x * contentW, y: s.y * contentH)
            }
        }
        .frame(width: contentW, height: contentH)
    }

    private var bird: some View {
        VStack(spacing: width * 0.02) {
            Circle().fill(theme.dragonRed).frame(width: width * 0.26, height: width * 0.26)
            DownTriangle().fill(theme.dragonRed)
                .frame(width: width * 0.22, height: width * 0.16)
            RoundedRectangle(cornerRadius: 2).fill(theme.bam)
                .frame(width: width * 0.055, height: width * 0.26)
        }
    }

    // MARK: Characters / honors

    private func chars(_ n: Int) -> some View {
        VStack(spacing: width * 0.03) {
            Text(Self.cnNumerals[n]).font(serif(width * 0.5)).foregroundStyle(theme.num)
            Text("萬").font(serif(width * 0.33)).foregroundStyle(theme.sub)
        }
        .lineLimit(1)
    }

    private func glyph(_ s: String, color: Color, scaled: Bool = false) -> some View {
        Text(s).font(serif(width * (scaled ? 0.48 : 0.62))).foregroundStyle(color).lineLimit(1)
    }

    @ViewBuilder private func dragon(_ d: Dragon, scaled: Bool = false) -> some View {
        switch d {
        case .red:   glyph("中", color: theme.dragonRed, scaled: scaled)
        case .green: glyph("發", color: theme.dragonGreen, scaled: scaled)
        case .white:
            let k: CGFloat = scaled ? 0.8 : 1.0
            ZStack {
                RoundedRectangle(cornerRadius: 3).strokeBorder(theme.dragonWhite, lineWidth: 2)
                    .frame(width: width * 0.46 * k, height: width * 0.6 * k)
                RoundedRectangle(cornerRadius: 2).strokeBorder(theme.dragonWhite, lineWidth: 1)
                    .frame(width: (width * 0.46 - width * 0.12) * k, height: (width * 0.6 - width * 0.12) * k)
            }
        }
    }

    // MARK: Layout tables (pip/stick centers in the 0–1 content box)

    private static let dotDiameter: [Int: CGFloat] = [
        2: 0.30, 3: 0.26, 4: 0.26, 5: 0.24, 6: 0.20, 7: 0.19, 8: 0.175, 9: 0.19,
    ]
    private static let dotLayouts: [Int: [CGPoint]] = [
        2: [CGPoint(x: 0.5, y: 0.24), CGPoint(x: 0.5, y: 0.76)],
        3: [CGPoint(x: 0.24, y: 0.20), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.76, y: 0.80)],
        4: [CGPoint(x: 0.28, y: 0.24), CGPoint(x: 0.72, y: 0.24),
            CGPoint(x: 0.28, y: 0.76), CGPoint(x: 0.72, y: 0.76)],
        5: [CGPoint(x: 0.24, y: 0.20), CGPoint(x: 0.76, y: 0.20), CGPoint(x: 0.50, y: 0.50),
            CGPoint(x: 0.24, y: 0.80), CGPoint(x: 0.76, y: 0.80)],
        6: [CGPoint(x: 0.32, y: 0.16), CGPoint(x: 0.68, y: 0.16),
            CGPoint(x: 0.32, y: 0.50), CGPoint(x: 0.68, y: 0.50),
            CGPoint(x: 0.32, y: 0.84), CGPoint(x: 0.68, y: 0.84)],
        7: [CGPoint(x: 0.22, y: 0.13), CGPoint(x: 0.50, y: 0.21), CGPoint(x: 0.78, y: 0.29),
            CGPoint(x: 0.32, y: 0.58), CGPoint(x: 0.68, y: 0.58),
            CGPoint(x: 0.32, y: 0.86), CGPoint(x: 0.68, y: 0.86)],
        8: [CGPoint(x: 0.32, y: 0.125), CGPoint(x: 0.68, y: 0.125),
            CGPoint(x: 0.32, y: 0.375), CGPoint(x: 0.68, y: 0.375),
            CGPoint(x: 0.32, y: 0.625), CGPoint(x: 0.68, y: 0.625),
            CGPoint(x: 0.32, y: 0.875), CGPoint(x: 0.68, y: 0.875)],
        9: [CGPoint(x: 0.20, y: 0.16), CGPoint(x: 0.50, y: 0.16), CGPoint(x: 0.80, y: 0.16),
            CGPoint(x: 0.20, y: 0.50), CGPoint(x: 0.50, y: 0.50), CGPoint(x: 0.80, y: 0.50),
            CGPoint(x: 0.20, y: 0.84), CGPoint(x: 0.50, y: 0.84), CGPoint(x: 0.80, y: 0.84)],
    ]

    private static let bambooSize: [Int: (w: CGFloat, h: CGFloat)] = [
        2: (0.11, 0.42), 3: (0.11, 0.42), 4: (0.105, 0.40), 5: (0.105, 0.40),
        6: (0.10, 0.34), 7: (0.095, 0.30), 8: (0.095, 0.32), 9: (0.095, 0.30),
    ]
    /// (x, y, rotation°) — 8索 is the classic "M over W" of tilted sticks.
    private static let bambooLayouts: [Int: [(x: CGFloat, y: CGFloat, rot: Double)]] = [
        2: [(0.50, 0.25, 0), (0.50, 0.75, 0)],
        3: [(0.50, 0.25, 0), (0.30, 0.75, 0), (0.70, 0.75, 0)],
        4: [(0.30, 0.25, 0), (0.70, 0.25, 0), (0.30, 0.75, 0), (0.70, 0.75, 0)],
        5: [(0.28, 0.25, 0), (0.72, 0.25, 0), (0.50, 0.50, 0), (0.28, 0.75, 0), (0.72, 0.75, 0)],
        6: [(0.22, 0.25, 0), (0.50, 0.25, 0), (0.78, 0.25, 0),
            (0.22, 0.75, 0), (0.50, 0.75, 0), (0.78, 0.75, 0)],
        7: [(0.50, 0.14, 0),
            (0.22, 0.50, 0), (0.50, 0.50, 0), (0.78, 0.50, 0),
            (0.22, 0.86, 0), (0.50, 0.86, 0), (0.78, 0.86, 0)],
        8: [(0.17, 0.26, 30), (0.39, 0.26, -30), (0.61, 0.26, 30), (0.83, 0.26, -30),
            (0.17, 0.74, -30), (0.39, 0.74, 30), (0.61, 0.74, -30), (0.83, 0.74, 30)],
        9: [(0.22, 0.16, 0), (0.50, 0.16, 0), (0.78, 0.16, 0),
            (0.22, 0.50, 0), (0.50, 0.50, 0), (0.78, 0.50, 0),
            (0.22, 0.84, 0), (0.50, 0.84, 0), (0.78, 0.84, 0)],
    ]

    // MARK: Glyph maps

    private static let cnNumerals = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    private func windGlyph(_ w: Wind) -> String { ["東", "南", "西", "北"][w.rawValue] }
    private func flowerGlyph(_ f: Flower) -> String { ["", "梅", "蘭", "菊", "竹"][f.rawValue] }
    private func seasonGlyph(_ s: Season) -> String { ["", "春", "夏", "秋", "冬"][s.rawValue] }
}

/// A downward-pointing triangle (the 1-bamboo bird's tail).
private struct DownTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

#if DEBUG
#Preview("Tiles · jade") {
    let sample: [Tile] = [.m(5), .p(1), .p(5), .p(7), .p(8), .p(9), .s(1), .s(5), .s(8), .s(9), .east, .redDragon, .greenDragon, .whiteDragon, .flower(.plum), .season(.spring)]
    return ScrollView(.horizontal) {
        HStack(spacing: 8) {
            ForEach(Array(sample.enumerated()), id: \.offset) { _, t in
                MahjongTileView(t, theme: .jade, width: 44)
            }
        }
        .padding()
    }
    .screenBackground(.content)
}
#endif

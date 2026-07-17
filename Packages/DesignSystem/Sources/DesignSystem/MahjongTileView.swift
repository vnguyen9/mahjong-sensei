import SwiftUI
import MahjongCore

/// A procedurally-drawn mahjong tile. Every dimension is a ratio of `width`
/// (design spec §3.2), so it scales cleanly from dense grids (w≈18) to hero
/// tiles (w≈60). Pass a `Tile` from MahjongCore and one of the five `TileTheme`s.
public struct MahjongTileView: View {
    public let tile: Tile
    public var theme: TileTheme
    public var width: CGFloat

    public init(_ tile: Tile, theme: TileTheme = .jade, width: CGFloat = 40) {
        self.tile = tile
        self.theme = theme
        self.width = width
    }

    private var height: CGFloat { (width * 1.35).rounded() }
    private var corner: CGFloat { (width * 0.19).rounded() }

    public var body: some View {
        ZStack {
            face
            content
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
            dragon(d)
        case let .flower(f):
            glyph(flowerGlyph(f), color: theme.dragonGreen)
        case let .season(s):
            glyph(seasonGlyph(s), color: theme.dragonGreen)
        }
    }

    // MARK: Dots

    private var oneDot: some View {
        let d = width * 0.5
        return ZStack {
            Circle().fill(theme.dotRing).frame(width: d, height: d)
            Circle().fill(theme.face2).frame(width: d * 0.7, height: d * 0.7)
            Circle().fill(theme.dot).frame(width: d * 0.46, height: d * 0.46)
        }
    }

    private func dotGrid(_ n: Int) -> some View {
        let ds = (n <= 5 ? width * 0.22 : width * 0.175).rounded()
        let gap = width * 0.07
        let perRow = max(1, Int((width * 0.7 + gap) / (ds + gap)))
        return VStack(spacing: gap) {
            ForEach(rowRanges(n, perRow: perRow), id: \.self) { range in
                HStack(spacing: gap) {
                    ForEach(range, id: \.self) { _ in dot(ds) }
                }
            }
        }
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

    // MARK: Bamboo

    private func barGrid(_ n: Int) -> some View {
        let bw = (width * 0.1).rounded()
        let bh = (width * 0.4).rounded()
        let gap = width * 0.08
        let containerW = (n <= 2 ? width * 0.42 : width * 0.64)
        let perRow = max(1, Int((containerW + gap) / (bw + gap)))
        return VStack(spacing: gap * 0.7) {
            ForEach(rowRanges(n, perRow: perRow), id: \.self) { range in
                HStack(spacing: gap) {
                    ForEach(range, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: width * 0.06)
                            .fill(theme.bam)
                            .frame(width: bw, height: bh)
                    }
                }
            }
        }
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

    private func glyph(_ s: String, color: Color) -> some View {
        Text(s).font(serif(width * 0.62)).foregroundStyle(color).lineLimit(1)
    }

    @ViewBuilder private func dragon(_ d: Dragon) -> some View {
        switch d {
        case .red:   glyph("中", color: theme.dragonRed)
        case .green: glyph("發", color: theme.dragonGreen)
        case .white:
            ZStack {
                RoundedRectangle(cornerRadius: 3).strokeBorder(theme.dragonWhite, lineWidth: 2)
                    .frame(width: width * 0.46, height: width * 0.6)
                RoundedRectangle(cornerRadius: 2).strokeBorder(theme.dragonWhite, lineWidth: 1)
                    .frame(width: width * 0.46 - width * 0.12, height: width * 0.6 - width * 0.12)
            }
        }
    }

    // MARK: Glyph maps

    private static let cnNumerals = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    private func windGlyph(_ w: Wind) -> String { ["東", "南", "西", "北"][w.rawValue] }
    private func flowerGlyph(_ f: Flower) -> String { ["", "梅", "蘭", "菊", "竹"][f.rawValue] }
    private func seasonGlyph(_ s: Season) -> String { ["", "春", "夏", "秋", "冬"][s.rawValue] }

    private func rowRanges(_ count: Int, perRow: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: perRow).map { $0..<Swift.min($0 + perRow, count) }
    }
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
    let sample: [Tile] = [.m(5), .p(1), .p(6), .s(1), .s(3), .east, .redDragon, .greenDragon, .whiteDragon, .flower(.plum), .season(.spring)]
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

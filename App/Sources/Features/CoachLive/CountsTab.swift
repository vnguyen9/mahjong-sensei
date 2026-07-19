import SwiftUI
import DesignSystem
import MahjongCore

/// 34-slot tile grid: real tile faces + seen-pips, gold wait ring, dead
/// dimming (UI plan §9 CountsTab). Grid identity is the static 34 slots —
/// only pips/opacity animate, never the layout.
///
/// The grid is **sized to fit its measured height** so all four suit rows
/// (chars / dots / bamboo / honors) are visible at every breathing split,
/// including the compressed 70% action split — never scrolled, never clipped.
/// Tile width targets the mockup's ~21pt at the rest split and scales down
/// from the available height under compression; the seen-pips scale with it so
/// a row's height stays proportional (which keeps the fit exact). Earlier this
/// tab used a fixed 20pt tile inside a `ScrollView`, so the honors row fell
/// off the bottom of the pane at the default 54% split.
struct CountsTab: View {
    @Environment(CoachLiveSession.self) private var session
    let onTapTile: (Tile) -> Void

    /// classIndex order: chars 0..<9, dots 9..<18, bamboo 18..<27, honors
    /// 27..<34 (E S W N 中 發 白) — exactly the recognizer's 42-class schema.
    private static let rows: [[Tile]] = [Array(0..<9), Array(9..<18), Array(18..<27), Array(27..<34)]
        .map { $0.compactMap(Tile.init(classIndex:)) }

    // Layout constants — kept tight so four rows fit even when the state pane
    // is squeezed at the 70% action split.
    private static let maxTile: CGFloat = 22          // mockup ~21pt at rest
    private static let cellPad: CGFloat = 2           // room for the wait ring
    private static let cellGap: CGFloat = 2           // tile → pips
    private static let rowSpacing: CGFloat = 4
    private static let colSpacing: CGFloat = 5
    /// Height a full-scale (22pt) seen-pip row occupies; scales with the tile.
    private static let pipsBase: CGFloat = 4.5

    private var waitTiles: Set<Tile> { session.advice?.currentWaitTileSet ?? [] }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = tileWidth(for: geo.size)
                let pipScale = min(1, width / Self.maxTile)
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: Self.colSpacing) {
                            ForEach(row, id: \.self) { tile in
                                cell(tile, width: width, pipScale: pipScale)
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            }
            Text("tap a tile to fix its count")
                .font(MJFont.ui(11))
                .foregroundStyle(MJColor.cream(0.5))
        }
    }

    /// The tile width that lets all four rows fit the measured space, capped at
    /// the mockup's ~21pt and bounded by the 9-tile row width. No lower clamp —
    /// so the grid always fits rather than clipping a row.
    private func tileWidth(for size: CGSize) -> CGFloat {
        // Width: 9 tiles + 8 gaps + per-cell horizontal padding.
        let byWidth = (size.width - 8 * Self.colSpacing - 9 * 2 * Self.cellPad) / 9
        // Height: four rows, each 1.35·tile (face) + a tile-proportional pip
        // row + gap + padding, plus the three inter-row gaps.
        let perRowConstant = Self.cellGap + 2 * Self.cellPad
        let rowFactor = 1.35 + Self.pipsBase / Self.maxTile   // pip height ≈ base·(tile/maxTile)
        let available = size.height - 3 * Self.rowSpacing - 4 * perRowConstant
        let byHeight = available / (4 * rowFactor)
        return max(4, min(Self.maxTile, byWidth, byHeight))
    }

    private func cell(_ tile: Tile, width: CGFloat, pipScale: CGFloat) -> some View {
        let seen = session.seenHistogram.indices.contains(tile.classIndex) ? session.seenHistogram[tile.classIndex] : 0
        let isWait = waitTiles.contains(tile)
        let isDead = seen >= 4
        return Button { onTapTile(tile) } label: {
            VStack(spacing: Self.cellGap) {
                MahjongTileView(tile, theme: .jade, width: width)
                SeenPips(seen: seen, scale: pipScale)
            }
            .padding(Self.cellPad)
            .background {
                if isWait {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(MJColor.gold(0.16))
                }
            }
            .overlay {
                if isWait {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(MJColor.gold, lineWidth: 1)
                }
            }
            .opacity(isDead ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: seen)
    }
}

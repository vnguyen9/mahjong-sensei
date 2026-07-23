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
/// a row's height stays proportional (which keeps the fit exact).
///
/// Pure/reusable: reads counts from an injected `histogram` (classIndex-keyed,
/// same convention as `CoachLiveSession.seenHistogram`) rather than owning any
/// session state, so it can back both CoachLive's `CountsTab` and Tracker's
/// count grid.
struct TileCountGrid: View {
    let histogram: [Int]
    /// Optional per-face hand counts — when non-nil, pips split gold (table) / cream (hand).
    var handHistogram: [Int]? = nil
    var highlight: Set<Tile> = []
    var tileWidthCap: CGFloat = 22
    /// iPad Coach Live asks for 44+pt correction targets. The measured grid
    /// height remains authoritative, so compact drawers cap this per-cell
    /// value rather than overflowing their four required rows.
    var minimumHitTarget: CGFloat = 0
    /// When true (Tracker), show short East/South/…/Red captions under the honors row.
    var showHonorCaptions: Bool = false
    let onTap: (Tile) -> Void

    /// classIndex order: chars 0..<9, dots 9..<18, bamboo 18..<27, honors
    /// 27..<34 (E S W N 中 發 白) — exactly the recognizer's 42-class schema.
    private static let rows: [[Tile]] = [Array(0..<9), Array(9..<18), Array(18..<27), Array(27..<34)]
        .map { $0.compactMap(Tile.init(classIndex:)) }

    // Layout constants — kept tight so four rows fit even when the state pane
    // is squeezed at the 70% action split.
    private static let cellPad: CGFloat = 2           // room for the wait ring
    private static let cellGap: CGFloat = 2           // tile → pips
    private static let rowSpacing: CGFloat = 4
    private static let colSpacing: CGFloat = 5
    /// Height a full-scale (22pt) seen-pip row occupies; scales with the tile.
    private static let pipsBase: CGFloat = 4.5
    private static let captionBase: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let width = tileWidth(for: geo.size)
            let pipScale = min(1, width / tileWidthCap)
            let availableCellHeight = max(0, (geo.size.height - 3 * Self.rowSpacing) / 4)
            let effectiveHitTarget = min(minimumHitTarget, availableCellHeight)
            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: Self.colSpacing) {
                        ForEach(row, id: \.self) { tile in
                            cell(tile, width: width, pipScale: pipScale,
                                 showCaption: showHonorCaptions && rowIndex == 3,
                                 minimumHitTarget: effectiveHitTarget)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private func tileWidth(for size: CGSize) -> CGFloat {
        let byWidth = (size.width - 8 * Self.colSpacing - 9 * 2 * Self.cellPad) / 9
        let perRowConstant = Self.cellGap + 2 * Self.cellPad
        let captionExtra = showHonorCaptions ? Self.captionBase / tileWidthCap : 0
        let rowFactor = 1.35 + Self.pipsBase / tileWidthCap + captionExtra
        let captionBudget = showHonorCaptions ? Self.captionBase + 2 : 0
        let available = size.height - 3 * Self.rowSpacing - 4 * perRowConstant - captionBudget
        let byHeight = available / (4 * rowFactor)
        return max(4, min(tileWidthCap, byWidth, byHeight))
    }

    private func cell(_ tile: Tile, width: CGFloat, pipScale: CGFloat, showCaption: Bool,
                      minimumHitTarget: CGFloat) -> some View {
        let table = histogram.indices.contains(tile.classIndex) ? histogram[tile.classIndex] : 0
        let hand: Int = {
            guard let handHistogram else { return 0 }
            return handHistogram.indices.contains(tile.classIndex) ? handHistogram[tile.classIndex] : 0
        }()
        let combined = min(4, table + hand)
        let isWait = highlight.contains(tile)
        let isDead = combined >= 4
        return Button { onTap(tile) } label: {
            VStack(spacing: Self.cellGap) {
                MahjongTileView(tile, width: width)
                if handHistogram != nil {
                    SeenPips(table: table, hand: hand, scale: pipScale)
                } else {
                    SeenPips(seen: table, scale: pipScale)
                }
                if showCaption, let label = honorCaption(tile) {
                    Text(label)
                        .font(MJFont.ui(max(7, 8 * pipScale), weight: .semibold))
                        .foregroundStyle(MJColor.cream(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
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
            .frame(minWidth: minimumHitTarget, minHeight: minimumHitTarget)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: combined)
    }

    private func honorCaption(_ tile: Tile) -> String? {
        switch tile {
        case .wind(.east): return "East"
        case .wind(.south): return "South"
        case .wind(.west): return "West"
        case .wind(.north): return "North"
        case .dragon(.red): return "Red"
        case .dragon(.green): return "Green"
        case .dragon(.white): return "White"
        default: return nil
        }
    }
}

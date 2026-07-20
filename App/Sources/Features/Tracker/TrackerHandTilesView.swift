import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData

/// Wrapping hand tile strip — breaks into multiple rows so nothing is clipped
/// off-screen (used on TrackerCard and TrackerHandSheet).
struct TrackerHandTilesView: View {
    let tiles: [Tile]
    var tileWidth: CGFloat = 28
    var spacing: CGFloat = 6
    var onTap: ((Tile) -> Void)?

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: tileWidth), spacing: spacing)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                Group {
                    if let onTap {
                        Button { onTap(tile) } label: {
                            MahjongTileView(tile, theme: .jade, width: tileWidth)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(MahjongData.name(for: tile).english)")
                    } else {
                        MahjongTileView(tile, theme: .jade, width: tileWidth)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

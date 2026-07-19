import SwiftUI
import DesignSystem
import MahjongCore

/// CoachLive's Counts tab: `TileCountGrid` bound to the live session's
/// histogram + current wait set, plus the "tap a tile to fix its count" hint
/// (UI plan §9 CountsTab). The grid itself is reusable — see
/// `TileCountGrid.swift`.
struct CountsTab: View {
    @Environment(CoachLiveSession.self) private var session
    let onTapTile: (Tile) -> Void

    var body: some View {
        VStack(spacing: 4) {
            TileCountGrid(
                histogram: session.seenHistogram,
                highlight: session.advice?.currentWaitTileSet ?? [],
                onTap: onTapTile
            )
            Text("tap a tile to fix its count")
                .font(MJFont.ui(11))
                .foregroundStyle(MJColor.cream(0.5))
        }
    }
}

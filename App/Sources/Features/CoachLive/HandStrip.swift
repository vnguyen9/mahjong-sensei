import SwiftUI
import DesignSystem
import MahjongCore
import Recognition

/// 13 concealed tiles + a separated draw, with the recommended discard's
/// gold ring/tag — fixed-height, never hides under compression (UI plan §10).
struct HandStrip: View {
    @Environment(CoachLiveSession.self) private var session
    let onTapTile: (TrackID) -> Void

    /// The first hand/drawn tile matching the recommended discard's face —
    /// mirrors the old `CoachView`'s `firstIndex(of:)` convention (rings one
    /// instance, not every duplicate).
    private var recommendedID: TrackID? {
        guard let target = session.advice?.best?.tile else { return nil }
        if let match = session.handTiles.first(where: { $0.face == target }) { return match.id }
        if session.drawnTile?.face == target { return session.drawnTile?.id }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2.5) {
                ForEach(session.handTiles) { tracked in
                    tile(tracked)
                }
            }
            if let drawn = session.drawnTile {
                tile(drawn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ tracked: TrackedTile) -> some View {
        let isDiscardPick = tracked.id == recommendedID
        return MahjongTileView(tracked.face, theme: .ivory, width: 22)
            .overlay {
                if isDiscardPick {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(MJColor.gold, lineWidth: 2).padding(-2)
                        .shadow(color: MJColor.gold(0.6), radius: 5)
                }
            }
            .overlay(alignment: .top) {
                if isDiscardPick {
                    Text("DISCARD")
                        .font(MJFont.ui(9, weight: .bold))
                        .foregroundStyle(MJColor.inkOnGold)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(MJColor.gold, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .fixedSize()   // else `.overlay` proposes the 22pt tile's width and wraps "DISCARD"
                        .offset(y: -16)
                }
            }
            .onTapGesture { onTapTile(tracked.id) }
    }
}

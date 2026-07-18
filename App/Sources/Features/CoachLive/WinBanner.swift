import SwiftUI
import DesignSystem
import MahjongCore

/// Gold banner announcing a detected win, dropped below the `LivePill`
/// inside the feed pane — one tap triggers the handoff to the Score flow
/// (UI plan §11).
struct WinBanner: View {
    @Environment(CoachLiveSession.self) private var session
    let onScoreHandoff: () -> Void

    var body: some View {
        if let win = session.winDetected {
            VStack(spacing: 8) {
                Button(action: onScoreHandoff) {
                    HStack(spacing: 8) {
                        Text(win.isSelfDraw ? "Winning hand! 自摸" : "Winning hand! 食糊")
                            .font(MJFont.ui(14, weight: .bold))
                            .foregroundStyle(MJColor.inkOnGold)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(MJColor.inkOnGold)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(colors: [MJColor.lightGold, MJColor.gold], startPoint: .top, endPoint: .bottom),
                        in: Capsule()
                    )
                    .shadow(color: MJColor.gold(0.4), radius: 8, y: 4)
                }
                .buttonStyle(.plain)

                TextLink("Keep playing") { session.winDetected = nil }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

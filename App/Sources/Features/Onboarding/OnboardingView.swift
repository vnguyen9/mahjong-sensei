import SwiftUI
import DesignSystem
import MahjongCore

/// Lane 1 · Welcome (spec screen 1). The remaining onboarding steps
/// (Pick style / Set table / Camera primer) attach here next.
struct OnboardingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            ScreenBackground(.welcome)
            VStack(spacing: 0) {
                Spacer()

                MahjongTileView(.redDragon, theme: .jade, width: 62)
                    .padding(.bottom, 26)

                Text("Mahjong Sensei")
                    .font(MJFont.serif(30, weight: .bold))
                    .foregroundStyle(MJColor.lightGold)

                Text("麻雀先生")
                    .font(MJFont.ui(12))
                    .tracking(6)
                    .foregroundStyle(MJColor.cream(0.5))
                    .padding(.top, 10)

                VStack(spacing: 3) {
                    Text("Point your phone at the tiles.")
                    Text("Get the score, and the reason why.")
                }
                .font(MJFont.ui(16))
                .foregroundStyle(MJColor.cream(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 24)

                Spacer()

                GoldButton("Get started", withShadow: true) {
                    withAnimation(.smooth) { app.completeOnboarding() }
                }
                Text("100% on-device · works offline")
                    .font(MJFont.ui(11, weight: .medium))
                    .foregroundStyle(MJColor.cream(0.5))
                    .padding(.top, 16)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 44)
        }
    }
}

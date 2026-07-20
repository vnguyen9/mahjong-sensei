import SwiftUI
import DesignSystem
import MahjongGameEngine

/// Hidden debug entry point for a playable, one-hand local table.
struct GameLauncherView: View {
    @State private var seedText = ""
    @State private var seat = 0
    @State private var isPlaying = false
    @State private var launchSeed = UInt64.random(in: 1...UInt64.max)

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Mahjong game")
                        .font(MJFont.screenTitle)
                        .foregroundStyle(MJColor.creamHeading)
                    Text("EXPERIMENTAL · LOCAL TEST TABLE")
                        .eyebrowStyle()

                    VStack(alignment: .leading, spacing: 14) {
                        Text("A complete Hong Kong Mahjong hand with local practice opponents. The test table uses the deterministic rules engine; your future model can take over the seats without changing this screen.")
                            .font(MJFont.body)
                            .foregroundStyle(MJColor.cream(0.70))
                            .fixedSize(horizontal: false, vertical: true)

                        TextField("Random seed", text: $seedText)
                            .keyboardType(.numberPad)
                            .font(MJFont.ui(16, weight: .medium))
                            .foregroundStyle(MJColor.creamHeading)
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(MJColor.gold(0.22)) }
                            .accessibilityLabel("Optional game seed")

                        Text("Your seat")
                            .font(MJFont.label)
                            .foregroundStyle(MJColor.creamHeading)
                        Picker("Your seat", selection: $seat) {
                            Text("East").tag(0); Text("South").tag(1); Text("West").tag(2); Text("North").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .tint(MJColor.gold)
                    }
                    .mjCard()

                    GoldButton("Quick deal", withShadow: true) {
                        launchSeed = UInt64(seedText) ?? UInt64.random(in: 1...UInt64.max)
                        isPlaying = true
                    }
                    .accessibilityHint("Starts a new experimental Mahjong hand")

                    Text("Hands stay on this device. There is no account or online play.")
                        .font(MJFont.caption)
                        .foregroundStyle(MJColor.cream(0.50))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(20)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Mahjong game")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isPlaying) {
            GameView(session: GameSession(seed: launchSeed, humanSeat: seat))
        }
    }
}

/// Centralizes deterministic screenshot scenes so RootView only needs one route hook.
@MainActor
enum MahjongGameDebugScene {
    static func view(for route: String) -> AnyView? {
        let seed: UInt64 = 20_260_720
        switch route {
        case "game":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0)) })
        case "game-reaction":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 1, humanSeat: 0), forceReactionSheet: true) })
        case "game-result":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 2, humanSeat: 0), forceResultSheet: true) })
        case "game-inspector":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), forceInspector: true) })
        default:
            return nil
        }
    }
}

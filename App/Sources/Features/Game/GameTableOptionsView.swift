import SwiftUI
import DesignSystem

/// In-match presentation preferences. Values commit immediately and persist,
/// while optional callbacks let `GameSession` start, pause, or reconfigure its
/// own timers without giving this view access to game state.
struct GameTableOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var tileInsightsEnabled: Bool
    @Binding private var stepThroughEnabled: Bool
    @Binding private var claimTimer: GameClaimTimer
    @State private var soundsEnabled: Bool

    /// Bind to session-owned values so changing the timer can immediately
    /// reconfigure an in-flight reaction countdown.
    init(
        tileInsightsEnabled: Binding<Bool>,
        stepThroughEnabled: Binding<Bool>,
        claimTimer: Binding<GameClaimTimer>
    ) {
        _tileInsightsEnabled = tileInsightsEnabled
        _stepThroughEnabled = stepThroughEnabled
        _claimTimer = claimTimer
        _soundsEnabled = State(initialValue: GameSounds.enabled)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MJColor.sheetGlass.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Table options")
                            .font(MJFont.sheetTitle)
                            .foregroundStyle(MJColor.creamHeading)

                        optionCard(title: "Learning") {
                            VStack(spacing: 0) {
                                Toggle(isOn: $tileInsightsEnabled) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Tile insights")
                                            .font(MJFont.ui(14, weight: .medium))
                                            .foregroundStyle(MJColor.creamHeading)
                                        Text("Hold a tile in your hand, or tap a face-up table tile, to learn.")
                                            .font(MJFont.ui(11))
                                            .foregroundStyle(MJColor.cream(0.58))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .tint(MJColor.gold)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 58)
                                .accessibilityHint("Turns contextual tile learning on or off. Hand taps still select a tile for discard.")

                                Divider().overlay(MJColor.gold(0.12)).padding(.leading, 12)

                                Toggle(isOn: $stepThroughEnabled) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Step-by-step pace")
                                            .font(MJFont.ui(14, weight: .medium))
                                            .foregroundStyle(MJColor.creamHeading)
                                        Text("Pause after visible actions until you tap Proceed.")
                                            .font(MJFont.ui(11))
                                            .foregroundStyle(MJColor.cream(0.58))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .tint(MJColor.gold)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 58)
                                .accessibilityHint("Controls whether the learning table waits for Proceed between actions.")
                            }
                        }

                        optionCard(title: "Claims") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Claim timer")
                                    .font(MJFont.ui(14, weight: .medium))
                                    .foregroundStyle(MJColor.creamHeading)
                                Text("Automatically pass only when you choose a timer. The setting applies to the current table immediately.")
                                    .font(MJFont.ui(11))
                                    .foregroundStyle(MJColor.cream(0.58))
                                    .fixedSize(horizontal: false, vertical: true)
                                Picker("Claim timer", selection: $claimTimer) {
                                    ForEach(GameClaimTimer.allCases) { timer in
                                        Text(timer.title).tag(timer)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .tint(MJColor.gold)
                                .accessibilityLabel("Claim timer")
                                .accessibilityValue(claimTimer.accessibilityDescription)
                            }
                            .padding(12)
                            .frame(minHeight: 108)
                        }

                        optionCard(title: "Sound") {
                            Toggle(isOn: $soundsEnabled) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Game sounds")
                                        .font(MJFont.ui(14, weight: .medium))
                                        .foregroundStyle(MJColor.creamHeading)
                                    Text("Subtle dice, tile, claim, and win cues that follow Silent Mode.")
                                        .font(MJFont.ui(11))
                                        .foregroundStyle(MJColor.cream(0.58))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .tint(MJColor.gold)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 58)
                            .accessibilityHint("Turns Mahjong sound cues on or off.")
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(MJColor.gold)
                        .accessibilityHint("Closes table options. Changes are already saved.")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .onChange(of: tileInsightsEnabled) { _, value in
            GameLearningPreferences.tileInsightsEnabled = value
        }
        .onChange(of: stepThroughEnabled) { _, value in
            GameLearningPreferences.stepThroughEnabled = value
        }
        .onChange(of: claimTimer) { _, value in
            GameLearningPreferences.claimTimer = value
        }
        .onChange(of: soundsEnabled) { _, value in
            GameSounds.enabled = value
        }
    }

    private func optionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MJFont.ui(11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(MJColor.gold(0.9))
                .padding(.leading, 2)
            VStack(spacing: 0, content: content)
                .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

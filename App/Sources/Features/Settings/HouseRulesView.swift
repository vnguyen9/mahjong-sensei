import SwiftUI
import DesignSystem

/// Table rules for new experimental Mahjong matches. A match reads one
/// `GameRulesPrefs.snapshot` when it is created, so changing a control here
/// never changes scoring during an active hand.
struct HouseRulesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var minimumFaan = GameRulesPrefs.minimumFaan
    @State private var faanLimit = GameRulesPrefs.faanLimit
    @State private var scoreFlowers = GameRulesPrefs.scoreFlowers
    @State private var paymentStyle = GameRulesPrefs.paymentStyle
    @State private var gameSoundsEnabled = GameSounds.enabled

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                MJBackHeader(title: "House Rules") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ruleCard(title: "Winning") {
                            rulePicker(
                                title: "Minimum faan",
                                detail: "Faan needed to declare a win.",
                                selection: $minimumFaan,
                                options: [(1, "1 faan"), (3, "3 faan")]
                            )
                            Divider().overlay(MJColor.gold(0.12))
                            rulePicker(
                                title: "Limit cap",
                                detail: "Maximum payable faan.",
                                selection: $faanLimit,
                                options: [(10, "10 faan"), (13, "13 faan")]
                            )
                        }

                        ruleCard(title: "Bonus") {
                            Toggle(isOn: $scoreFlowers) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Flowers")
                                        .font(MJFont.ui(14, weight: .medium))
                                        .foregroundStyle(MJColor.creamHeading)
                                    Text("Score seat flowers, seasons, and bouquets.")
                                        .font(MJFont.ui(11))
                                        .foregroundStyle(MJColor.cream(0.55))
                                }
                            }
                            .tint(MJColor.gold)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 52)
                            .accessibilityHint("Controls flower and season scoring for new matches.")
                        }

                        ruleCard(title: "Payments") {
                            rulePicker(
                                title: "Payment style",
                                detail: paymentStyle.detail,
                                selection: $paymentStyle,
                                options: GamePaymentStyle.allCases.map { ($0, $0.title) }
                            )
                        }

                        ruleCard(title: "Experience") {
                            Toggle(isOn: $gameSoundsEnabled) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Game sounds")
                                        .font(MJFont.ui(14, weight: .medium))
                                        .foregroundStyle(MJColor.creamHeading)
                                    Text("Subtle tile, claim, and win sounds that follow Silent Mode.")
                                        .font(MJFont.ui(11))
                                        .foregroundStyle(MJColor.cream(0.55))
                                }
                            }
                            .tint(MJColor.gold)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 52)
                            .accessibilityHint("Turns Mahjong game sounds on or off for new and current matches.")
                        }

                        Text("These settings apply when you start a new match. An active match keeps the rules it started with.")
                            .font(MJFont.ui(11))
                            .foregroundStyle(MJColor.cream(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
        }
        .onChange(of: minimumFaan) { _, value in GameRulesPrefs.minimumFaan = value }
        .onChange(of: faanLimit) { _, value in GameRulesPrefs.faanLimit = value }
        .onChange(of: scoreFlowers) { _, value in GameRulesPrefs.scoreFlowers = value }
        .onChange(of: paymentStyle) { _, value in GameRulesPrefs.paymentStyle = value }
        .onChange(of: gameSoundsEnabled) { _, value in GameSounds.enabled = value }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func ruleCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).eyebrowStyle().padding(.leading, 2)
            VStack(spacing: 0, content: content).mjCard(padding: 4)
        }
    }

    private func rulePicker<Value: Hashable>(
        title: String,
        detail: String,
        selection: Binding<Value>,
        options: [(Value, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MJFont.ui(14, weight: .medium))
                    .foregroundStyle(MJColor.creamHeading)
                Text(detail)
                    .font(MJFont.ui(11))
                    .foregroundStyle(MJColor.cream(0.55))
            }
            Picker(title, selection: selection) {
                ForEach(options.indices, id: \.self) { index in
                    let (value, label) = options[index]
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 72)
    }
}

import SwiftUI
import DesignSystem
import MahjongCore

/// Lane 2 · A few quick taps (spec screen 8). Seat + round winds, win type, dealer.
struct ContextView: View {
    @Environment(ScanCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var session = coordinator.session
        ZStack {
            ScreenBackground(.content)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Winds are computed for you.")
                        .font(MJFont.ui(13)).foregroundStyle(MJColor.cream(0.6))

                    labeled("Your seat") { WindPicker(selection: $session.seatWind) }
                    labeled("Round wind") { WindPicker(selection: $session.roundWind) }

                    if session.seatWind == session.roundWind {
                        doubleWindPill(session.seatWind)
                    }

                    labeled("How did you win?") {
                        TwoCellPicker(selection: $session.isSelfDraw,
                                      left: ("Self-draw 自摸", true), right: ("By discard", false))
                    }

                    HStack {
                        Text("I'm the dealer")
                            .font(MJFont.ui(14, weight: .medium)).foregroundStyle(MJColor.creamHeading)
                        Spacer()
                        Toggle("", isOn: $session.isDealer).labelsHidden().tint(MJColor.jadeAccent)
                    }
                    .mjCard()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GoldButton("See result →") { coordinator.push(.result) }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(MJFont.ui(14, weight: .medium)).foregroundStyle(MJColor.gold)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Almost there").font(MJFont.serif(17, weight: .bold)).foregroundStyle(MJColor.creamHeading)
            Spacer()
            Color.clear.frame(width: 44)
        }
        .padding(.horizontal, 20).padding(.top, 16)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).eyebrowStyle()
            content()
        }
    }

    private func doubleWindPill(_ wind: Wind) -> some View {
        Text("Double \(windEnglish(wind)) · seat + round match → +2 faan")
            .font(MJFont.ui(11, weight: .semibold))
            .foregroundStyle(MJColor.inkOnGold)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(MJColor.gold, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private func windEnglish(_ w: Wind) -> String { ["East", "South", "West", "North"][w.rawValue] }
private func windGlyph(_ w: Wind) -> String { ["東", "南", "西", "北"][w.rawValue] }

/// Four-cell seat/round wind selector.
private struct WindPicker: View {
    @Binding var selection: Wind
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Wind.allCases, id: \.self) { wind in
                let active = wind == selection
                Button { selection = wind } label: {
                    VStack(spacing: 3) {
                        Text(windGlyph(wind)).font(MJFont.serif(20, weight: .bold))
                        Text(windEnglish(wind)).font(MJFont.ui(9, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .foregroundStyle(active ? MJColor.creamHeading : MJColor.cream(0.55))
                    .mjCard(cornerRadius: 12, selected: active, padding: 0)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A full-width two-cell selector for a boolean choice.
private struct TwoCellPicker: View {
    @Binding var selection: Bool
    let left: (String, Bool)
    let right: (String, Bool)

    var body: some View {
        HStack(spacing: 8) {
            cell(left)
            cell(right)
        }
    }

    private func cell(_ option: (String, Bool)) -> some View {
        let active = selection == option.1
        return Button { selection = option.1 } label: {
            Text(option.0)
                .font(MJFont.ui(13, weight: .semibold))
                .foregroundStyle(active ? MJColor.creamHeading : MJColor.cream(0.55))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .mjCard(cornerRadius: 12, selected: active, padding: 0)
        }
        .buttonStyle(.plain)
    }
}

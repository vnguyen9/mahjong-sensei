import SwiftUI
import DesignSystem
import MahjongCore

/// Lane 2 · A few quick taps (spec screen 8). Seat + round winds, win type, dealer.
struct ContextView: View {
    @Environment(ScanCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var session = coordinator.session
        // A scroll region (so a tall hand — e.g. with the Special-win rows —
        // never clips its top selector) with the CTA as a FIXED FOOTER below
        // it. Siblings in the VStack, so "See result →" can never overlap or
        // bleed through the scrolling content, is always visible, and its
        // bottom padding reserves room for the floating dock. Header is a
        // pinned top inset.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Winds are computed for you.")
                        .font(MJFont.ui(13)).foregroundStyle(MJColor.cream(0.6))
                        .padding(.horizontal, 20)

                    Group {
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

                        labeled("Special win (optional)") {
                            VStack(spacing: 8) {
                                circumstanceRow("Won on the last tile", "海底撈月", $session.isLastTile)
                                circumstanceRow("Kong replacement", "槓上開花", $session.isReplacement)
                                circumstanceRow("Robbing a kong", "搶槓", $session.isRobbingKong)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GoldButton("See result →") { coordinator.push(.result) }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 96)
        }
        .safeAreaInset(edge: .top) { header }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CapturedBackdrop(photo: session.capturedPhoto, fallback: .content))
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
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.horizontal, 20).padding(.top, 16)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).eyebrowStyle()
            content()
        }
    }

    /// A card row for a special-win circumstance: English + 繁中 name and a toggle.
    private func circumstanceRow(_ english: String, _ zh: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(english).font(MJFont.ui(14, weight: .medium)).foregroundStyle(MJColor.creamHeading)
                Text(zh).font(MJFont.serif(11)).foregroundStyle(MJColor.gold(0.7))
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(MJColor.jadeAccent)
        }
        .mjCard()
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

/// Shared wind label helpers — internal (not `private`) so Coach Live's Map tab,
/// setup card, and hand-ended rotation line can reuse them instead of duplicating.
func windEnglish(_ w: Wind) -> String { ["East", "South", "West", "North"][w.rawValue] }
func windGlyph(_ w: Wind) -> String { ["東", "南", "西", "北"][w.rawValue] }

/// Four-cell seat/round wind selector. De-privatized so Coach Live's setup card
/// and hand-ended rotation editor can reuse it verbatim.
struct WindPicker: View {
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

import SwiftUI
import DesignSystem
import MahjongCore

/// Round/seat wind quick setup — two taps over the live feed, no separate
/// screen (UI plan §6). Defaults East/East, matching `CoachLiveSession`'s
/// own defaults, so the common case is literally 0–2 taps + Start.
struct CoachLiveSetupView: View {
    @Environment(CoachLiveSession.self) private var session
    @State private var roundWind: Wind = .east
    @State private var seatWind: Wind = .east
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            ScreenBackground(.live)
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("Coach Live").font(MJFont.serif(20, weight: .bold)).foregroundStyle(MJColor.creamHeading)
                    Text("Two taps and I'll watch the table.")
                        .font(MJFont.ui(13)).foregroundStyle(MJColor.cream(0.6))
                }

                labeled("Round wind") { WindPicker(selection: $roundWind) }
                labeled("Your seat") { WindPicker(selection: $seatWind) }

                GoldButton("Start tracking →") {
                    session.begin(roundWind: roundWind, seatWind: seatWind)
                    onStart()
                }
                TextLink("Cancel", action: onCancel)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .mjCard(cornerRadius: 20)
            .padding(20)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).eyebrowStyle()
            content()
        }
    }
}

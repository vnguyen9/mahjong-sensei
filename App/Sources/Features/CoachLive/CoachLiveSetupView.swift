import SwiftUI
import DesignSystem
import MahjongCore

/// Round/seat wind quick setup — two taps over the live feed, no separate
/// screen (UI plan §6). Defaults East/East, matching `CoachLiveSession`'s
/// own defaults, so the common case is literally 0–2 taps + Start.
///
struct CoachLiveSetupView: View {
    @Environment(CoachLiveSession.self) private var session
    @State private var roundWind: Wind = .east
    @State private var seatWind: Wind = .east
    /// Set synchronously the instant Start is tapped — `begin()` itself
    /// returns immediately (the real loop spins up in the background), so
    /// without this the button gives no feedback at all during the
    /// setup→live crossfade, which is exactly the "Start tracking did
    /// nothing" complaint the staged-loading overlay (A1) also targets.
    @State private var isStarting = false
    /// Fresh start: winds are stashed on the session; the caller starts one
    /// continuous AR/census pipeline before moving into guided calibration.
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

                // A local decoration over the shared `GoldButton` (not a
                // change to the component itself — other call sites are
                // unaffected): the title swaps to "Starting…" and a trailing
                // spinner overlays the label while `isStarting`, so the tap
                // reads as instantly registered on slow phones.
                GoldButton(isStarting ? "Starting…" : "Start tracking →") {
                    isStarting = true
                    // Stash winds; the flow starts one continuous AR/census
                    // pipeline before presenting guided calibration.
                    session.seatWind = seatWind
                    session.roundWind = roundWind
                    onStart()
                }
                .overlay(alignment: .trailing) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(MJColor.inkOnGold)
                            .padding(.trailing, 18)
                    }
                }
                .disabled(isStarting)

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

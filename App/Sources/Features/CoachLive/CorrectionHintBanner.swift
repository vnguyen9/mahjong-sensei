import SwiftUI
import DesignSystem

/// One-time discoverability tip for the corrections surface (plan A3): "tap
/// any tile, count, or bracket to fix it" — mounted above the state pane's
/// tab content (`CoachLiveView.statePane`). Shows once per device, then
/// never again: dismisses itself either on tap or after ~4s, and persists
/// that it's been seen via `CoachLivePrefs.hasSeenCorrectionHint`.
///
/// Mock/MJ_SCREEN sessions never show this: rather than threading a
/// "is this a real session" flag through the view (`CoachLiveSession`'s
/// `tracker` is deliberately private — nothing else needs to distinguish
/// real from mock at the view layer), `MockCoachLive.make` marks the pref
/// seen at construction time. That's the cleaner seam — it keeps this view
/// a pure function of the one pref it already needs to read, and mock
/// sessions have no "first launch" concept for a tip like this anyway.
struct CorrectionHintBanner: View {
    @State private var isVisible = !CoachLivePrefs.hasSeenCorrectionHint

    var body: some View {
        if isVisible {
            Button(action: dismiss) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Tap any tile, count, or bracket to fix it")
                        .font(MJFont.ui(12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(MJColor.inkOnGold)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(MJColor.gold, in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .task {
                try? await Task.sleep(for: .seconds(4))
                dismiss()
            }
        }
    }

    private func dismiss() {
        guard isVisible else { return }
        CoachLivePrefs.hasSeenCorrectionHint = true
        withAnimation(.easeOut(duration: 0.25)) { isVisible = false }
    }
}

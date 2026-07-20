import SwiftUI

/// The feed/state-pane split fraction, adjusted by dragging the seam (UI plan
/// §8). Auto-breathing (the old phase-driven split animation) was removed — the
/// seam is now purely manual: the split stays wherever the user leaves it. Pure
/// UI logic — no view, no camera — so it stays trivially reasoned-about and
/// screenshot-driven.
@Observable
final class BreathingController {
    static let range: ClosedRange<CGFloat> = 0.40...0.72
    static let defaultFraction: CGFloat = 0.54

    /// The single rendered value — `CoachLiveView` sizes the feed pane from
    /// this fraction of the full-screen height.
    var fraction: CGFloat = BreathingController.defaultFraction

    // MARK: - Drag interaction

    /// Finger-attached update: the seam moving *down* by `translationY` grows
    /// the feed pane, so the fraction rises by `translationY / paneHeight`.
    /// Assigned directly (no animation) so it tracks the finger 1:1, clamped
    /// into `range`.
    func dragChanged(startFraction: CGFloat, translationY: CGFloat, paneHeight: CGFloat) {
        guard paneHeight > 0 else { return }
        let proposed = startFraction + translationY / paneHeight
        fraction = min(Self.range.upperBound, max(Self.range.lowerBound, proposed))
    }

    /// Seam release: settle with a soft spring into `range`.
    func dragEnded() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            fraction = min(Self.range.upperBound, max(Self.range.lowerBound, fraction))
        }
    }
}

import SwiftUI

/// The feed/state-pane split fraction, driven by `CoachLiveSession.phase` and
/// overridable by dragging the seam (UI plan §8).
///
/// Two behaviours live here: the phase-driven **auto target** (a slow "breath"
/// to the rest/action/think split when the table's phase changes) and the
/// **manual override** (a finger-attached seam drag, clamped to `range`, that
/// suspends auto-breathing for a 10s grace window and then eases back to the
/// current phase's target). Pure UI logic — no view, no camera — so it stays
/// trivially reasoned-about and screenshot-driven.
@Observable
final class BreathingController {
    static let range: ClosedRange<CGFloat> = 0.40...0.72
    static let rest: CGFloat = 0.54
    static let action: CGFloat = 0.70
    static let think: CGFloat = 0.40
    /// How long a manual drag suspends auto-breathing before it eases back.
    static let overrideGrace: Duration = .seconds(10)

    /// The single rendered value — `CoachLiveView` sizes the feed pane from
    /// this fraction of the full-screen height.
    var fraction: CGFloat = BreathingController.rest
    /// True while a seam drag (or its grace window) is overriding the phase
    /// target — the seam label switches to "MANUAL" and shows a resume hint.
    private(set) var isManual = false

    /// Whether phase changes are allowed to move `fraction`. Off while the
    /// user's `autoBreathing` setting is disabled (§13); a manual override is
    /// tracked separately via `isManual`. When off, manual overrides never
    /// expire (the manual split becomes the third, sticky "setting").
    var autoEnabled = true

    /// The phase last reported by the session — remembered so the grace timer
    /// knows where to ease back to when it fires (a drag can outlive several
    /// phase changes).
    private var currentPhase: CoachLiveSession.Phase = .rest
    /// The pending auto-resume; re-armed on every drag, cancelled on drag start.
    private var resumeTask: Task<Void, Never>?

    /// Moves `fraction` to the target split for `phase`, unless a manual
    /// override is active or auto-breathing is off. Always records the phase so
    /// a later auto-resume returns to the right split. Called from
    /// `CoachLiveView.onChange(of: session.phase)` (animated — a slow "breath")
    /// and once from `.onAppear` (unanimated, so the initial screenshot/scene
    /// lands directly on target instead of mid-transition).
    func autoTarget(for phase: CoachLiveSession.Phase, animated: Bool = true) {
        currentPhase = phase
        guard autoEnabled, !isManual else { return }
        let target = Self.target(for: phase)
        if animated {
            withAnimation(.smooth(duration: 0.9)) { fraction = target }
        } else {
            fraction = target
        }
    }

    static func target(for phase: CoachLiveSession.Phase) -> CGFloat {
        switch phase {
        case .rest:     return rest
        case .action:   return action
        case .thinking: return think
        }
    }

    // MARK: - Drag interaction (the signature manual override)

    /// Seam touch-down: take over from auto-breathing and cancel any pending
    /// resume so the split stays put under the finger.
    func dragBegan() {
        resumeTask?.cancel()
        resumeTask = nil
        isManual = true
    }

    /// Finger-attached update: the seam moving *down* by `translationY` grows
    /// the feed pane, so the fraction rises by `translationY / paneHeight`.
    /// Assigned directly (no animation) so it tracks the finger 1:1, clamped
    /// into `range`.
    func dragChanged(startFraction: CGFloat, translationY: CGFloat, paneHeight: CGFloat) {
        isManual = true
        guard paneHeight > 0 else { return }
        let proposed = startFraction + translationY / paneHeight
        fraction = min(Self.range.upperBound, max(Self.range.lowerBound, proposed))
    }

    /// Seam release: settle with a soft spring and, when auto-breathing is on,
    /// arm the 10s grace timer that eases back to the current phase target.
    /// With auto-breathing off the manual split simply persists.
    func dragEnded() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            fraction = min(Self.range.upperBound, max(Self.range.lowerBound, fraction))
        }
        armResume()
    }

    private func armResume() {
        resumeTask?.cancel()
        guard autoEnabled else { resumeTask = nil; return }   // manual is sticky when auto is off
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.overrideGrace)
            guard let self, !Task.isCancelled else { return }
            self.isManual = false
            self.resumeTask = nil
            withAnimation(.smooth(duration: 0.9)) {
                self.fraction = Self.target(for: self.currentPhase)
            }
        }
    }
}

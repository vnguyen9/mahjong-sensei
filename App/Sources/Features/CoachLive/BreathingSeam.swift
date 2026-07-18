import SwiftUI
import DesignSystem

/// The draggable divider between the live feed and the state pane (UI plan §8).
///
/// Shows the grabber + an honest state label: `DRAG · AUTO n%` while breathing
/// follows the table's phase, `DRAG · MANUAL n%` while a drag override holds —
/// with a subtle "resumes auto" hint when the 10s grace timer will hand control
/// back. Dragging the seam adjusts the split live via `BreathingController`
/// (finger-attached, clamped 0.40–0.72).
struct BreathingSeam: View {
    /// `@Observable` — reading `fraction`/`isManual` here observes them, so the
    /// label tracks both auto breaths and live drags.
    let controller: BreathingController
    /// Full-screen height — the denominator that turns a drag translation into
    /// a fraction delta (the fraction is of the full screen).
    let paneHeight: CGFloat

    static let height: CGFloat = 24

    @State private var startFraction: CGFloat?

    var body: some View {
        VStack(spacing: 4) {
            Capsule().fill(MJColor.cream(0.35)).frame(width: 44, height: 5)
            label
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .gesture(drag)
        .accessibilityLabel("Drag to resize the live feed")
        .accessibilityValue("\(percent) percent")
    }

    private var label: some View {
        HStack(spacing: 5) {
            Text("DRAG · \(controller.isManual ? "MANUAL" : "AUTO") \(percent)%")
                .font(MJFont.ui(10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(MJColor.cream(0.5))
            if controller.isManual && controller.autoEnabled {
                Text("· resumes auto")
                    .font(MJFont.ui(9, weight: .medium))
                    .foregroundStyle(MJColor.gold(0.7))
            }
        }
    }

    private var percent: Int { Int((controller.fraction * 100).rounded()) }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if startFraction == nil {
                    startFraction = controller.fraction
                    controller.dragBegan()
                }
                controller.dragChanged(startFraction: startFraction ?? controller.fraction,
                                       translationY: value.translation.height,
                                       paneHeight: paneHeight)
            }
            .onEnded { _ in
                controller.dragEnded()
                startFraction = nil
            }
    }
}

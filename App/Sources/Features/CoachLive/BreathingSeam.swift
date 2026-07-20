import SwiftUI
import DesignSystem

/// The draggable divider between the live feed and the state pane (UI plan §8).
///
/// Shows the grabber + the split percentage. Dragging the seam adjusts the
/// split live via `BreathingController` (finger-attached, clamped 0.40–0.72);
/// it stays wherever the user leaves it (auto-breathing was removed).
struct BreathingSeam: View {
    /// `@Observable` — reading `fraction` here observes it, so the label
    /// tracks live drags.
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
        Text("DRAG · \(percent)%")
            .font(MJFont.ui(10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(MJColor.cream(0.5))
    }

    private var percent: Int { Int((controller.fraction * 100).rounded()) }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if startFraction == nil {
                    startFraction = controller.fraction
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

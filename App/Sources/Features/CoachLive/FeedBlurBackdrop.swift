import SwiftUI
import UIKit
import DesignSystem

/// The live feed's "slightly soft, clearly live" backdrop blur (UI plan §7).
///
/// The mockup is a `backdrop-filter: blur(3px)` + `rgba(8,25,20,.2)` tint — a
/// *backdrop* blur, which iOS composites in the render server at ~zero CPU
/// cost, the thermally-correct choice for hours-long sessions. A plain SwiftUI
/// `.blur` does not reliably filter `AVCaptureVideoPreviewLayer` video, and
/// re-rendering frames through CoreImage at 30fps for hours is a non-starter —
/// so this uses the standard variable-blur technique: a `UIVisualEffectView`
/// whose `UIViewPropertyAnimator` is paused at a small `fractionComplete`
/// (~"3px"), never started, so the effect is evaluated once and then held by
/// the render server.
///
/// If the paused-animator trick ever misbehaves on an iOS 26 point release,
/// flip `forcesFallback` to `true` for the ship-safe `ViewfinderBlurOverlay`
/// recipe (full-strength `.ultraThinMaterial` + jade tint — stronger than 3px
/// but privacy-correct).
///
/// Sits ABOVE the preview, BELOW the brackets/pill/buttons (those stay sharp,
/// like the mockup). Installed only when the feed-blur setting is on (§13).
struct FeedBlurBackdrop: View {
    /// Escape hatch for the paused-animator technique (see the type doc). Left
    /// as a stored flag so a device-QA regression is a one-line flip, not a
    /// rewrite.
    static var forcesFallback = false

    /// Approximate "3px" — the paused animator's `fractionComplete`.
    private static let blurFraction: CGFloat = 0.06

    var body: some View {
        Group {
            if Self.forcesFallback {
                // Ship-safe fallback: the exact `ViewfinderBlurOverlay` recipe.
                Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    .overlay(MJColor.deepJade.opacity(0.3))
            } else {
                PausedBlurView(fraction: Self.blurFraction)
                    // Mockup tint: rgba(8,25,20,.2) ≈ 0x081914 @ 20%.
                    .overlay(Color(hex: 0x081914, alpha: 0.2))
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// A `UIVisualEffectView` driven by a paused `UIViewPropertyAnimator` so its
/// blur is evaluated at a small, fixed radius and then composited by the render
/// server (see `FeedBlurBackdrop`). The animator is retained by the coordinator
/// (an un-retained animator deallocates and the effect snaps back to `nil`) and
/// is never started.
private struct PausedBlurView: UIViewRepresentable {
    var fraction: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
            view.effect = UIBlurEffect(style: .regular)
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = fraction
        context.coordinator.animator = animator
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        context.coordinator.animator?.fractionComplete = fraction
    }

    static func dismantleUIView(_ uiView: UIVisualEffectView, coordinator: Coordinator) {
        // Finish the paused animator so it doesn't leak / warn on teardown.
        coordinator.animator?.stopAnimation(true)
        coordinator.animator = nil
    }

    final class Coordinator {
        /// Retained for the view's lifetime — the blur resets if this is freed.
        var animator: UIViewPropertyAnimator?
    }
}

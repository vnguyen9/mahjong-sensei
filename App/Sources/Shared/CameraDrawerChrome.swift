import SwiftUI
import UIKit
import DesignSystem

private struct FloatingDockClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var floatingDockClearance: CGFloat {
        get { self[FloatingDockClearanceKey.self] }
        set { self[FloatingDockClearanceKey.self] = newValue }
    }
}

enum CameraDrawerDetent: Int, CaseIterable, Comparable, Sendable {
    case small
    case medium
    case big

    static func < (lhs: CameraDrawerDetent, rhs: CameraDrawerDetent) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var next: CameraDrawerDetent {
        CameraDrawerDetent(rawValue: rawValue + 1) ?? self
    }

    var previous: CameraDrawerDetent {
        CameraDrawerDetent(rawValue: rawValue - 1) ?? self
    }

    var accessibilityValue: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .big: return "Large"
        }
    }
}

enum CameraDrawerHeights {
    static func resolved(for height: CGFloat, isPad: Bool)
        -> (small: CGFloat, medium: CGFloat, big: CGFloat) {
        let small: CGFloat = isPad
            ? min(360, max(300, height * 0.36))
            : min(300, max(240, height * 0.34))
        let medium: CGFloat = isPad
            ? max(small + 20, height * 0.34)
            : min(height * 0.58, max(360, height - 180))
        let big: CGFloat = isPad
            ? max(medium + 80, min(height * 0.56, height - 110))
            : min(height * 0.72, max(480, height - 120))
        return (small, medium, big)
    }

    static func height(for detent: CameraDrawerDetent,
                       availableHeight: CGFloat, isPad: Bool) -> CGFloat {
        let values = resolved(for: availableHeight, isPad: isPad)
        switch detent {
        case .small: return values.small
        case .medium: return values.medium
        case .big: return values.big
        }
    }
}

/// Shared 44-point drag/tap affordance for camera-backed gameplay drawers.
struct CameraDrawerHandle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var detent: CameraDrawerDetent
    var noun = "drawer"
    var onCollapse: (() -> Void)?

    var body: some View {
        Capsule()
            .fill(MJColor.cream(0.35))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { change(to: detent.next) }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        if value.translation.height < -36 {
                            change(to: detent.next)
                        } else if value.translation.height > 36 {
                            collapseOrChangeDown()
                        }
                    }
            )
            .accessibilityLabel("Resize \(noun)")
            .accessibilityValue(detent.accessibilityValue)
            .accessibilityHint("Swipe up or down to resize the \(noun)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: change(to: detent.next)
                case .decrement: collapseOrChangeDown()
                @unknown default: break
                }
            }
    }

    private func change(to value: CameraDrawerDetent) {
        guard value != detent else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(reduceMotion ? nil : .spring(response: 0.35,
                                                   dampingFraction: 0.88)) {
            detent = value
        }
    }

    private func collapseOrChangeDown() {
        if detent == .small, let onCollapse {
            UISelectionFeedbackGenerator().selectionChanged()
            onCollapse()
        } else {
            change(to: detent.previous)
        }
    }
}

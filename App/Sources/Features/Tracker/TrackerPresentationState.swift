import Observation

enum TrackerPresentationPhase: Sendable, Equatable {
    case cameraFirst
    case capturing
    case frozenAnalyzing
    case review
    case dashboard
}

/// Process-lifetime presentation only. Counts persist in `TrackerSession`, but
/// each fresh app launch deliberately returns to the unobstructed camera.
@Observable
final class TrackerPresentationState {
    private(set) var phase: TrackerPresentationPhase = .cameraFirst
    var isDrawerVisible = false
    var drawerDetent: CameraDrawerDetent = .small
    private var stablePhaseBeforeCapture: TrackerPresentationPhase = .cameraFirst

    func beginCapture() {
        stablePhaseBeforeCapture = isDrawerVisible ? .dashboard : .cameraFirst
        phase = .capturing
    }

    func showFrozenAnalysis() {
        phase = .frozenAnalyzing
    }

    func showReview() {
        phase = .review
    }

    func cancelReviewOrCapture() {
        phase = stablePhaseBeforeCapture
    }

    func rescan() {
        phase = .cameraFirst
        isDrawerVisible = false
    }

    func showAfterApply() {
        phase = .dashboard
        drawerDetent = .small
        isDrawerVisible = true
    }

    func showExistingCounts() {
        phase = .dashboard
        isDrawerVisible = true
    }

    func collapseDrawer() {
        phase = .cameraFirst
        drawerDetent = .small
        isDrawerVisible = false
    }

    func reset() {
        phase = .cameraFirst
        drawerDetent = .small
        isDrawerVisible = false
    }
}

import SwiftUI
import Observation
import DesignSystem

/// App-wide state: which tab is showing and whether onboarding is done.
@Observable
final class AppState {
    var selectedTab: MJTab = .scan
    var hasOnboarded: Bool

    /// "Higher accuracy" — swaps the scan detector for the larger, slower model.
    /// Persisted under the shared key the scan coordinator reads. Defaults to on.
    var prefersHighAccuracy: Bool {
        didSet { TileDetector.prefersHighAccuracy = prefersHighAccuracy }
    }

    /// Dev-only detector override. Mirrors `TileDetector.devModel`; surfaced by the
    /// Debug-only Developer card in Settings and consulted by the recognizer only in
    /// Debug builds. Inert in Release (no UI sets it, and `preferredModelName` ignores it).
    var devDetectorModel: DetectorModel {
        didSet { TileDetector.devModel = devDetectorModel }
    }

    /// Coach Live: blur the live feed for privacy. Read live by
    /// `FeedBlurBackdrop` (a later chunk) via `@Environment(AppState.self)`.
    var blursLiveFeed: Bool {
        didSet { CoachLivePrefs.blursFeed = blursLiveFeed }
    }
    /// Coach Live: the feed pane grows/shrinks with the action automatically.
    var autoBreathing: Bool {
        didSet { CoachLivePrefs.autoBreathes = autoBreathing }
    }

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardKey)
        prefersHighAccuracy = TileDetector.prefersHighAccuracy
        devDetectorModel = TileDetector.devModel
        blursLiveFeed = CoachLivePrefs.blursFeed
        autoBreathing = CoachLivePrefs.autoBreathes
    }

    func completeOnboarding() {
        hasOnboarded = true
        UserDefaults.standard.set(true, forKey: Self.onboardKey)
    }

    /// Resets onboarding — handy while developing.
    func resetOnboarding() {
        hasOnboarded = false
        UserDefaults.standard.set(false, forKey: Self.onboardKey)
    }

    private static let onboardKey = "hasOnboarded"
}

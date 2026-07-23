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

    #if DEBUG
    /// Debug-only switch for scalar Tracker model and fusion evidence. The
    /// Release binary has neither this setting nor the diagnostics controls.
    var trackerDeveloperMode: Bool {
        didSet {
            UserDefaults.standard.set(trackerDeveloperMode,
                                      forKey: Self.trackerDeveloperModeKey)
        }
    }
    #endif

    /// Coach Live: blur the live feed for privacy. Read live by
    /// `FeedBlurBackdrop` (a later chunk) via `@Environment(AppState.self)`.
    var blursLiveFeed: Bool {
        didSet { CoachLivePrefs.blursFeed = blursLiveFeed }
    }

    /// User-selected tile theme, applied app-wide. `nil` = Auto (Jade menus ·
    /// Ivory game table). Persisted as its raw string; unset → Auto.
    var tileTheme: TileThemeChoice? {
        didSet {
            if let tileTheme {
                UserDefaults.standard.set(tileTheme.rawValue, forKey: Self.tileThemeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.tileThemeKey)
            }
        }
    }

    /// User-selected tile back cap style, applied app-wide. Persisted as its
    /// raw string; unset → `.gold` (the original glitter cap).
    var tileBack: TileBackStyle {
        didSet {
            UserDefaults.standard.set(tileBack.rawValue, forKey: Self.tileBackKey)
        }
    }

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardKey)
        prefersHighAccuracy = TileDetector.prefersHighAccuracy
        devDetectorModel = TileDetector.devModel
        #if DEBUG
        trackerDeveloperMode = UserDefaults.standard.bool(
            forKey: Self.trackerDeveloperModeKey
        )
        #endif
        blursLiveFeed = CoachLivePrefs.blursFeed
        tileTheme = UserDefaults.standard.string(forKey: Self.tileThemeKey)
            .flatMap(TileThemeChoice.init(rawValue:))
        tileBack = UserDefaults.standard.string(forKey: Self.tileBackKey)
            .flatMap(TileBackStyle.init(rawValue:)) ?? .gold
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
    private static let tileThemeKey = "settings.tileTheme"
    private static let tileBackKey = "settings.tileBack"
    #if DEBUG
    private static let trackerDeveloperModeKey = "trackerDeveloperMode"
    #endif
}

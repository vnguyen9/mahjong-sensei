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

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardKey)
        prefersHighAccuracy = TileDetector.prefersHighAccuracy
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

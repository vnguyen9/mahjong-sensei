import SwiftUI
import Observation
import DesignSystem

/// App-wide state: which tab is showing and whether onboarding is done.
@Observable
final class AppState {
    var selectedTab: MJTab = .scan
    var hasOnboarded: Bool

    init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardKey)
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

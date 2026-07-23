import Foundation
import MahjongCore

/// The payment convention selected for a new experimental Mahjong match.
///
/// This intentionally describes the table preference rather than implementing
/// settlement math. `MatchState` maps the captured snapshot to its own
/// `SettlementPolicy`, so changing Settings never changes a hand in progress.
enum GamePaymentStyle: String, CaseIterable, Codable, Sendable {
    case halfSpicy
    case fullSpicy

    var title: String {
        switch self {
        case .halfSpicy: "Half-spicy"
        case .fullSpicy: "Full-spicy"
        }
    }

    var detail: String {
        switch self {
        case .halfSpicy: "Split payments"
        case .fullSpicy: "Full table payments"
        }
    }
}

/// An immutable copy of game rules taken when a match begins.
struct GameRulesSnapshot: Sendable, Codable, Hashable {
    let minimumFaan: Int
    let faanLimit: Int
    let scoreFlowers: Bool
    let paymentStyle: GamePaymentStyle

    var houseRules: HouseRules {
        HouseRules(
            minimumFaan: minimumFaan,
            faanLimit: faanLimit,
            scoreFlowers: scoreFlowers
        )
    }
}

/// UserDefaults-backed game-rule preferences. Values are deliberately small,
/// validated enums/scalars so corrupt or legacy defaults safely fall back to
/// the classic experimental-table configuration.
enum GameRulesPrefs {
    private static let minimumFaanKey = "gameRules.minimumFaan"
    private static let faanLimitKey = "gameRules.faanLimit"
    private static let scoreFlowersKey = "gameRules.scoreFlowers"
    private static let paymentStyleKey = "gameRules.paymentStyle"

    static var minimumFaan: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: minimumFaanKey)
            return stored == 1 || stored == 3 ? stored : 3
        }
        set { UserDefaults.standard.set(newValue == 1 ? 1 : 3, forKey: minimumFaanKey) }
    }

    static var faanLimit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: faanLimitKey)
            return stored == 10 || stored == 13 ? stored : 13
        }
        set { UserDefaults.standard.set(newValue == 10 ? 10 : 13, forKey: faanLimitKey) }
    }

    static var scoreFlowers: Bool {
        get { UserDefaults.standard.object(forKey: scoreFlowersKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: scoreFlowersKey) }
    }

    static var paymentStyle: GamePaymentStyle {
        get {
            GamePaymentStyle(
                rawValue: UserDefaults.standard.string(forKey: paymentStyleKey) ?? ""
            ) ?? .halfSpicy
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: paymentStyleKey) }
    }

    /// Read once at match creation. A `GameSession` or `MatchState` must retain
    /// this value for the life of its match rather than rereading preferences.
    static var snapshot: GameRulesSnapshot {
        GameRulesSnapshot(
            minimumFaan: minimumFaan,
            faanLimit: faanLimit,
            scoreFlowers: scoreFlowers,
            paymentStyle: paymentStyle
        )
    }
}

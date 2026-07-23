import Foundation
import MahjongCore
import ScoringEngine

/// Data-driven settlement for a single winning hand. Values are net points, not
/// currency; every settlement vector is guaranteed zero-sum.
public struct SettlementPolicy: Codable, Sendable, Hashable {
    public var id: String
    public var basePoints: [Int: Int]
    public var selfDrawNumerator: Int
    public var selfDrawDenominator: Int

    public init(id: String, basePoints: [Int: Int], selfDrawNumerator: Int = 3, selfDrawDenominator: Int = 2) {
        self.id = id; self.basePoints = basePoints; self.selfDrawNumerator = selfDrawNumerator; self.selfDrawDenominator = selfDrawDenominator
    }

    public func points(forFaan faan: Int) -> Int {
        if let exact = basePoints[faan] { return exact }
        let ceiling = basePoints.keys.max() ?? 0
        return basePoints[ceiling] ?? 0
    }

    public func payments(faan: Int, winner: Int, source: WinSource, discarder: Int?) -> [Int] {
        let base = points(forFaan: faan)
        var payments = Array(repeating: 0, count: 4)
        if source == .selfDraw || source == .flowerSeven || source == .flowerEight {
            let total = base * selfDrawNumerator / max(1, selfDrawDenominator)
            let each = total / 3
            var remainder = total % 3
            for seat in 0..<4 where seat != winner { payments[seat] -= each }
            var cursor = (winner + 1) % 4
            while remainder > 0 {
                if cursor != winner { payments[cursor] -= 1; remainder -= 1 }
                cursor = (cursor + 1) % 4
            }
            payments[winner] = -payments.reduce(0, +)
        } else if let discarder {
            payments[discarder] = -base
            payments[winner] = base
        }
        return payments
    }

    /// Half-spicy / 半辣上 points table used by the certified v2 profile.
    public static let halfSpicyV2 = SettlementPolicy(
        id: "half_spicy_v2",
        basePoints: [0: 1, 1: 2, 2: 4, 3: 8, 4: 16, 5: 24, 6: 32, 7: 48, 8: 64, 9: 96, 10: 128, 11: 192, 12: 256, 13: 384]
    )

    /// Classic match policy: published three-faan minimum table. The hand
    /// profile enforces the minimum, so no values below three are required.
    public static let classicHalfSpicy = SettlementPolicy(
        id: "half_spicy_classic_v3",
        basePoints: [3: 8, 4: 16, 5: 24, 6: 32, 7: 48, 8: 64, 9: 96, 10: 128, 11: 192, 12: 256, 13: 384]
    )

    /// Full-spicy settlement: every non-winner pays the full table value on a
    /// self draw (three times the discard-win collection).
    public static let classicFullSpicy = SettlementPolicy(
        id: "full_spicy_classic_v3",
        basePoints: [3: 8, 4: 16, 5: 24, 6: 32, 7: 48, 8: 64, 9: 96, 10: 128, 11: 192, 12: 256, 13: 384],
        selfDrawNumerator: 3, selfDrawDenominator: 1
    )
}

public enum SettlementStyle: String, Codable, CaseIterable, Sendable, Hashable {
    case halfSpicy, fullSpicy
    public var policy: SettlementPolicy { self == .halfSpicy ? .classicHalfSpicy : .classicFullSpicy }
}

/// Codable classic-table settings frozen into a match at its start. These map to
/// a deterministic profile identity so individual `GameReplayV2` records can be
/// reconstructed without relying on mutable app preferences.
public struct MatchRulesConfiguration: Codable, Sendable, Hashable {
    public var minimumFaan: Int
    public var faanCap: Int
    /// Controls flower/season faan lines (including no-flower). Physical flowers,
    /// replacement draws, and seven/eight-flower instant wins remain rule-level
    /// mechanics so a disabled scoring bonus cannot corrupt tile conservation.
    public var scoreFlowers: Bool
    public var settlementStyle: SettlementStyle

    public init(minimumFaan: Int = 3, faanCap: Int = 13, scoreFlowers: Bool = true,
                settlementStyle: SettlementStyle = .halfSpicy) {
        self.minimumFaan = minimumFaan; self.faanCap = faanCap; self.scoreFlowers = scoreFlowers; self.settlementStyle = settlementStyle
    }

    public func makeProfile() throws -> RulesProfile {
        guard [1, 3].contains(minimumFaan), [10, 13].contains(faanCap) else {
            throw MahjongGameError.replayMismatch("unsupported classic rules settings")
        }
        return RulesProfile.classic(minimumFaan: minimumFaan, faanCap: faanCap, scoreFlowers: scoreFlowers, settlementStyle: settlementStyle)
    }
}

/// Rules identity injected at hand construction. Profiles are immutable values:
/// replays resolve the profile from their id/hash and fail closed on a mismatch.
public struct RulesProfile: Sendable, Hashable {
    public var id: String
    public var rulesHash: String
    public var minimumFaan: Int
    public var faanCap: Int
    public var scoreFlowers: Bool
    public var permitsSevenPairs: Bool
    public var permitsThirteenOrphans: Bool
    public var faanTable: FaanTable
    public var settlement: SettlementPolicy

    public init(id: String, rulesHash: String, minimumFaan: Int, faanCap: Int,
                scoreFlowers: Bool, permitsSevenPairs: Bool, permitsThirteenOrphans: Bool,
                faanTable: FaanTable, settlement: SettlementPolicy) {
        self.id = id; self.rulesHash = rulesHash; self.minimumFaan = minimumFaan; self.faanCap = faanCap
        self.scoreFlowers = scoreFlowers; self.permitsSevenPairs = permitsSevenPairs
        self.permitsThirteenOrphans = permitsThirteenOrphans; self.faanTable = faanTable; self.settlement = settlement
    }

    /// Frozen Python-parity profile. Keep as the default `GameState` profile.
    public static let hk3FaanV2 = RulesProfile(
        id: "hk_3faan_v2", rulesHash: "0e0ce106e67fbc42", minimumFaan: 3, faanCap: 13,
        scoreFlowers: true, permitsSevenPairs: false, permitsThirteenOrphans: false,
        faanTable: FaanTable(values: {
            var values = FaanTable.standard.values
            values[.chickenHand] = 1
            values[.fullFlush] = 7
            values[.sevenPairs] = 0
            return values
        }()), settlement: .halfSpicyV2
    )

    /// User-facing classic match profile. Special concealed hands are enabled;
    /// the original v2 profile remains available for parity training/replays.
    public static let hkClassicV3 = RulesProfile(
        id: "hk_classic_v3", rulesHash: "hk_classic_v3_3f_13cap", minimumFaan: 3, faanCap: 13,
        scoreFlowers: true, permitsSevenPairs: true, permitsThirteenOrphans: true,
        faanTable: .standard, settlement: .classicHalfSpicy
    )

    public static func classic(minimumFaan: Int = 3, faanCap: Int = 13, scoreFlowers: Bool = true,
                               settlementStyle: SettlementStyle = .halfSpicy) -> RulesProfile {
        let id = "hk_classic_v3_m\(minimumFaan)_c\(faanCap)_f\(scoreFlowers ? 1 : 0)_\(settlementStyle.rawValue)"
        return RulesProfile(id: id, rulesHash: "classic-v3:\(id)", minimumFaan: minimumFaan, faanCap: faanCap,
                            scoreFlowers: scoreFlowers, permitsSevenPairs: true, permitsThirteenOrphans: true,
                            faanTable: .standard, settlement: settlementStyle.policy)
    }

    public static func resolve(id: String, rulesHash: String? = nil) throws -> RulesProfile {
        let profile: RulesProfile
        switch id {
        case hk3FaanV2.id: profile = .hk3FaanV2
        case hkClassicV3.id: profile = .hkClassicV3
        default:
            let parts = id.split(separator: "_")
            guard parts.count == 7, parts[0] == "hk", parts[1] == "classic", parts[2] == "v3",
                  parts[3].first == "m", parts[4].first == "c", parts[5].first == "f",
                  let minimum = Int(parts[3].dropFirst()), let cap = Int(parts[4].dropFirst()),
                  let flowers = Int(parts[5].dropFirst()), let style = SettlementStyle(rawValue: String(parts[6])) else {
                throw MahjongGameError.replayMismatch("unknown rules profile \(id)")
            }
            profile = classic(minimumFaan: minimum, faanCap: cap, scoreFlowers: flowers == 1, settlementStyle: style)
        }
        if let rulesHash, profile.rulesHash != rulesHash { throw MahjongGameError.replayMismatch("rules identity") }
        return profile
    }
}

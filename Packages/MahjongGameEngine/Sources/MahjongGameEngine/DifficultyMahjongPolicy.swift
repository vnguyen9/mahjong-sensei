import Foundation
import MahjongCore

/// Deterministic policy selector for match difficulty. Each decision is derived
/// only from `PublicObservationV3` and its 127-bit legal mask; no difficulty can
/// inspect opponent concealed tiles or `GameState` internals.
public struct DifficultyMahjongPolicy: MahjongPolicy {
    public let difficulty: BotDifficulty
    public let seed: UInt64

    public init(difficulty: BotDifficulty, seed: UInt64 = 0) {
        self.difficulty = difficulty; self.seed = seed
    }

    public func decision(for observation: PublicObservationV3, legalMask: [Bool]) async throws -> PolicyDecision {
        switch difficulty {
        case .easy: return easyDecision(observation: observation, legalMask: legalMask)
        case .normal: return try await HeuristicMahjongPolicy().decision(for: observation, legalMask: legalMask)
        case .hard: return try await hardDecision(observation: observation, legalMask: legalMask)
        }
    }

    private func easyDecision(observation: PublicObservationV3, legalMask: [Bool]) -> PolicyDecision {
        let legal = legalIDs(legalMask)
        guard let fallback = legal.first else { return PolicyDecision(actionID: 0, diagnostics: "easy: no legal action") }
        if legal.contains(1) { return PolicyDecision(actionID: 1, diagnostics: "easy: win") }
        if observation.phase == .reaction { return PolicyDecision(actionID: legal.contains(0) ? 0 : fallback, diagnostics: "easy: pass") }
        let discards = legal.filter { (2...35).contains($0) }
        guard !discards.isEmpty else { return PolicyDecision(actionID: fallback, diagnostics: "easy: fallback") }
        let index = Int(stableHash(observation) % UInt64(discards.count))
        return PolicyDecision(actionID: discards[index], diagnostics: "easy: seeded legal discard")
    }

    private func hardDecision(observation: PublicObservationV3, legalMask: [Bool]) async throws -> PolicyDecision {
        let legal = legalIDs(legalMask)
        if legal.contains(1) { return PolicyDecision(actionID: 1, diagnostics: "hard: win") }
        let discards = legal.filter { (2...35).contains($0) }
        if !discards.isEmpty, observation.opponentMelds.contains(where: { $0.count >= 2 }) {
            // A tile already discarded by more opponents is a modest, fully-public
            // safety signal. Break ties by stable action id.
            let opponentRiver = observation.opponentDiscards.flatMap { $0 }
            let safest = discards.max { left, right in
                let l = opponentRiver.filter { $0.classIndex == left - 2 }.count
                let r = opponentRiver.filter { $0.classIndex == right - 2 }.count
                return l == r ? left > right : l < r
            }!
            return PolicyDecision(actionID: safest, diagnostics: "hard: public-river defense")
        }
        var decision = try await HeuristicMahjongPolicy().decision(for: observation, legalMask: legalMask)
        if !legal.contains(decision.actionID) { decision = PolicyDecision(actionID: legal.first ?? 0, diagnostics: "hard: legal fallback") }
        return decision
    }

    private func legalIDs(_ mask: [Bool]) -> [Int] { mask.enumerated().compactMap { $0.element ? $0.offset : nil } }
    private func stableHash(_ observation: PublicObservationV3) -> UInt64 {
        var hash = seed ^ UInt64(observation.turn) &* 0x9E3779B97F4A7C15
        for value in observation.concealed + observation.physicalPublic + observation.remainingBelief {
            hash = (hash ^ UInt64(value &+ 0x9E37)) &* 0x100000001B3
        }
        hash ^= UInt64(observation.wallRemaining) << 17
        return hash
    }
}

/// Placeholder for the future bundled Core ML policy. The model-facing contract
/// is fixed here: 34-length `concealed`, `physicalPublic`, and `remainingBelief`
/// vectors plus the 127-wide legal mask in `GameAction` order. Until a model is
/// supplied, this safely delegates to the normal heuristic policy.
public struct ModelMahjongPolicy: MahjongPolicy {
    public let modelIdentifier: String
    public let fallback: DifficultyMahjongPolicy

    public init(modelIdentifier: String = "MahjongPolicy", fallbackSeed: UInt64 = 0) {
        self.modelIdentifier = modelIdentifier
        fallback = DifficultyMahjongPolicy(difficulty: .normal, seed: fallbackSeed)
    }

    public func decision(for observation: PublicObservationV3, legalMask: [Bool]) async throws -> PolicyDecision {
        var decision = try await fallback.decision(for: observation, legalMask: legalMask)
        decision.diagnostics = "model \(modelIdentifier) unavailable; \(decision.diagnostics ?? "legal fallback")"
        return decision
    }
}

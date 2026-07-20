import Foundation
import MahjongCore
import CoachEngine
import ScoringEngine

/// Deterministic offline baseline for the experimental table. It deliberately
/// treats the simulator's legal mask as authoritative: a policy can never make
/// an illegal move, and a future Core ML policy can use the exact same seam.
public struct HeuristicMahjongPolicy: MahjongPolicy {
    public init() {}

    public func decision(for observation: PublicObservationV3, legalMask: [Bool]) async throws -> PolicyDecision {
        let legal = legalMask.enumerated().compactMap { $0.element ? $0.offset : nil }
        guard let fallback = legal.first else { return PolicyDecision(actionID: 0, diagnostics: "no legal action") }
        if legal.contains(1) { return PolicyDecision(actionID: 1, diagnostics: "legal win") }

        // Claims are conservative: kongs first (only when legal), then a pung of
        // honors/terminals, then a chow. Passing is the safe default for a weak call.
        if observation.phase == .reaction {
            if legal.contains(58) { return PolicyDecision(actionID: 58, diagnostics: "legal exposed kong") }
            if legal.contains(57), let offered = observation.offerTile, offered.isHonor || offered.isTerminal { return PolicyDecision(actionID: 57, diagnostics: "value pung") }
            if let chow = legal.first(where: { (36...56).contains($0) }) { return PolicyDecision(actionID: chow, diagnostics: "legal chow") }
            return PolicyDecision(actionID: legal.contains(0) ? 0 : fallback, diagnostics: "pass reaction")
        }

        if let kong = legal.first(where: { (59...92).contains($0) }) { return PolicyDecision(actionID: kong, diagnostics: "concealed kong") }
        if let kong = legal.first(where: { (93...126).contains($0) }) { return PolicyDecision(actionID: kong, diagnostics: "added kong") }
        let discards = legal.filter { (2...35).contains($0) }
        guard !discards.isEmpty else { return PolicyDecision(actionID: fallback, diagnostics: "first legal fallback") }

        let ranked = rankedDiscards(observation: observation, candidates: discards)
        return PolicyDecision(actionID: ranked.first ?? discards[0], diagnostics: "coach-ranked discard")
    }

    private func rankedDiscards(observation: PublicObservationV3, candidates: [Int]) -> [Int] {
        var tiles: [Tile] = []
        for index in 0..<min(34, observation.concealed.count) {
            tiles += Array(repeating: Tile(classIndex: index)!, count: observation.concealed[index])
        }
        // CoachEngine needs a complete table snapshot. It is used when its input
        // shape is valid; an entirely deterministic face-value fallback covers
        // claim turns and unusual mid-kong states.
        let melds = observation.melds.map { gameMeld in
            Meld(kind: gameMeld.kind == .chow ? .chow : (gameMeld.kind == .pung ? .pung : .kong), tiles: gameMeld.tiles.map(\.tile), isConcealed: gameMeld.isConcealed)
        }
        let seen = observation.physicalPublic
        let context = GameContext(seatWind: observation.seatWind, prevailingWind: observation.prevailingWind, houseRules: HouseRules(minimumFaan: 3, faanLimit: 13, scoreFlowers: true))
        let table = TableState(concealed: tiles, melds: melds, bonusTiles: observation.flowers, seenHistogram: seen, unseenCount: max(0, observation.remainingBelief.reduce(0, +)), drawsRemaining: observation.wallRemaining, opponentMeldCount: observation.opponentMelds.reduce(0) { $0 + $1.count }, context: context)
        let advice = CoachAdvisor.advise(table)
        let coachOrder = advice.options.compactMap { option -> Int? in
            let id = option.tile.classIndex + 2
            return candidates.contains(id) ? id : nil
        }
        if !coachOrder.isEmpty { return coachOrder }
        return candidates.sorted { discardValue($0 - 2, counts: observation.concealed) < discardValue($1 - 2, counts: observation.concealed) }
    }

    private func discardValue(_ index: Int, counts: [Int]) -> Int {
        guard let tile = Tile(classIndex: index) else { return 999 }
        var value = 0
        if tile.isHonor { value -= 8 }
        if tile.isTerminal { value -= 5 }
        let copies = index < counts.count ? counts[index] : 0
        value += copies * 8
        if let rank = tile.rank, let suit = tile.suit {
            for neighbour in [rank - 2, rank - 1, rank + 1, rank + 2] where (1...9).contains(neighbour) {
                let nearby = Tile.suited(suit, neighbour).classIndex
                value += (nearby < counts.count ? counts[nearby] : 0) * 3
            }
        }
        return value
    }
}

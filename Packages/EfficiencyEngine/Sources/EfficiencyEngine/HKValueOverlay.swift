import MahjongCore

// MARK: - HK value overlay (heuristic — deliberately kept separate)

public extension EfficiencyEngine {
    /// A **rough** Hong Kong value-potential heuristic — *not* a scoring engine
    /// and no substitute for real faan (番) evaluation.
    ///
    /// It rewards the two payouts that are cheapest to spot from tile shape
    /// alone:
    /// - **Flush** (清一色 / 混一色): concentration in a single suit, with
    ///   honours treated as flush-compatible.
    /// - **All triplets** (對對糊): tiles already sitting in pairs/triplets.
    ///
    /// It is used *only* as an opt-in tiebreak in
    /// ``rankDiscards(_:hkValueTiebreak:)`` when two discards are otherwise
    /// identical on shanten and ukeire. A higher score means more value
    /// potential is retained in the hand you keep. Do not read anything more
    /// precise into the number.
    static func hkPotentialScore(remaining tiles: [Tile], melds: [Meld] = []) -> Int {
        var suitCounts: [Suit: Int] = [:]
        var honors = 0
        var faces = [Int](repeating: 0, count: Tile.baseClassCount)

        for t in tiles + melds.flatMap(\.tiles) where !t.isBonus {
            faces[t.classIndex] += 1
            if let s = t.suit { suitCounts[s, default: 0] += 1 } else { honors += 1 }
        }

        // Flush potential: the dominant suit, with honours riding along (混一色).
        let flush = (suitCounts.values.max() ?? 0) + honors
        // Triplet potential: tiles already paired or tripled up.
        var triplets = 0
        for c in faces where c >= 2 { triplets += c }

        return flush * 2 + triplets     // flush weighted a touch above triplets
    }
}

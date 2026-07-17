import Foundation

/// One complete parse of a hand into 4 sets + 1 pair, or a recognized special hand.
///
/// For special hands the flags carry the meaning:
/// - `isSevenPairs`: `melds` holds the seven pairs, `pair` is nil.
/// - `isThirteenOrphans`: `melds` and `pair` are empty/nil.
public struct HandDecomposition: Sendable, Hashable {
    public var melds: [Meld]
    public var pair: Meld?
    public var isSevenPairs: Bool
    public var isThirteenOrphans: Bool

    public init(melds: [Meld], pair: Meld?, isSevenPairs: Bool = false, isThirteenOrphans: Bool = false) {
        self.melds = melds
        self.pair = pair
        self.isSevenPairs = isSevenPairs
        self.isThirteenOrphans = isThirteenOrphans
    }

    /// All sets plus the pair, as a flat list of melds (special hands excluded).
    public var allGroups: [Meld] { melds + (pair.map { [$0] } ?? []) }
}

/// Decomposes hands into winning shapes. Pure, deterministic, allocation-light.
public enum HandParser {

    /// Every valid standard decomposition (4 sets + pair) of the hand, treating
    /// `fixedMelds` as already-formed sets and parsing `concealed` into the rest.
    public static func standardDecompositions(concealed: [Tile], fixedMelds: [Meld] = []) -> [HandDecomposition] {
        var counts = [Int](repeating: 0, count: Tile.baseClassCount)
        for t in concealed where !t.isBonus { counts[t.classIndex] += 1 }

        let fixedSets = fixedMelds.filter(\.isSet)
        guard fixedSets.count <= 4 else { return [] }

        var results: [HandDecomposition] = []
        for p in 0..<Tile.baseClassCount where counts[p] >= 2 {
            counts[p] -= 2
            for sets in setPartitions(&counts) where fixedSets.count + sets.count == 4 {
                results.append(HandDecomposition(melds: fixedSets + sets,
                                                 pair: .pair(Tile(classIndex: p)!)))
            }
            counts[p] += 2
        }
        return dedupe(results)
    }

    /// True if the tiles form any winning shape (standard, seven pairs, or thirteen orphans).
    public static func isWinningHand(concealed: [Tile], fixedMelds: [Meld] = []) -> Bool {
        if !standardDecompositions(concealed: concealed, fixedMelds: fixedMelds).isEmpty { return true }
        guard fixedMelds.isEmpty else { return false }
        let base = concealed.filter { !$0.isBonus }
        return sevenPairs(base) != nil || thirteenOrphans(base) != nil
    }

    // MARK: Special hands

    /// 七對子 — seven distinct pairs (fully concealed, 14 tiles).
    public static func sevenPairs(_ tiles: [Tile]) -> HandDecomposition? {
        let base = tiles.filter { !$0.isBonus }
        guard base.count == 14 else { return nil }
        var counts: [Int: Int] = [:]
        for t in base { counts[t.classIndex, default: 0] += 1 }
        guard counts.count == 7, counts.values.allSatisfy({ $0 == 2 }) else { return nil }
        let pairs = counts.keys.sorted().map { Meld.pair(Tile(classIndex: $0)!) }
        return HandDecomposition(melds: pairs, pair: nil, isSevenPairs: true)
    }

    /// 十三么 — one of each terminal/honor (13 unique) plus one duplicate.
    public static func thirteenOrphans(_ tiles: [Tile]) -> HandDecomposition? {
        let base = tiles.filter { !$0.isBonus }
        guard base.count == 14 else { return nil }
        var counts: [Int: Int] = [:]
        for t in base { counts[t.classIndex, default: 0] += 1 }
        let required = Tile.allBase.filter(\.isTerminalOrHonor)   // exactly 13
        guard counts.count == 13,
              required.allSatisfy({ counts[$0.classIndex] != nil }),
              counts.values.filter({ $0 == 2 }).count == 1 else { return nil }
        return HandDecomposition(melds: [], pair: nil, isThirteenOrphans: true)
    }

    // MARK: Core recursion

    /// All ways to fully consume `counts` into chow/pung sets (empty if impossible).
    private static func setPartitions(_ counts: inout [Int]) -> [[Meld]] {
        guard let i = counts.firstIndex(where: { $0 > 0 }) else { return [[]] }
        let tile = Tile(classIndex: i)!
        var out: [[Meld]] = []

        if counts[i] >= 3 {
            counts[i] -= 3
            for rest in setPartitions(&counts) { out.append([.pung(tile, isConcealed: true)] + rest) }
            counts[i] += 3
        }
        // Chow: suited only, and i, i+1, i+2 within the same nine-tile suit block.
        if i < 27, i % 9 <= 6, counts[i + 1] > 0, counts[i + 2] > 0, let chow = Meld.chow(tile, isConcealed: true) {
            counts[i] -= 1; counts[i + 1] -= 1; counts[i + 2] -= 1
            for rest in setPartitions(&counts) { out.append([chow] + rest) }
            counts[i] += 1; counts[i + 1] += 1; counts[i + 2] += 1
        }
        return out
    }

    private static func dedupe(_ list: [HandDecomposition]) -> [HandDecomposition] {
        var seen = Set<String>()
        var out: [HandDecomposition] = []
        for d in list {
            let key = d.melds.map { $0.kind.rawValue + ":" + $0.tiles.map(\.code).joined() }.sorted().joined(separator: "|")
                + "/" + (d.pair?.representative.code ?? "")
            if seen.insert(key).inserted { out.append(d) }
        }
        return out
    }
}

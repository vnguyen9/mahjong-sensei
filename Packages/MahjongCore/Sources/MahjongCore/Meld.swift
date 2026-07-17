import Foundation

public enum MeldKind: String, Sendable, Codable, Hashable {
    case chow   // 順子 — a run of three consecutive suited tiles
    case pung   // 刻子 — a triplet
    case kong   // 槓   — a quad
    case pair   // 眼/將 — the eye

    /// Counts toward the four "sets" of a standard hand (i.e. not the pair).
    public var isSet: Bool { self != .pair }
    public var isTriplet: Bool { self == .pung || self == .kong }
}

/// A grouped set of tiles: a chow, pung, kong, or the pair.
public struct Meld: Hashable, Sendable, Codable {
    public var kind: MeldKind
    /// Tiles in ascending order. 3 for chow/pung, 4 for kong, 2 for pair.
    public var tiles: [Tile]
    /// Concealed (drawn / in hand) vs melded (claimed from a discard).
    public var isConcealed: Bool

    public init(kind: MeldKind, tiles: [Tile], isConcealed: Bool = true) {
        self.kind = kind
        self.tiles = tiles.sorted()
        self.isConcealed = isConcealed
    }
}

public extension Meld {
    var isSet: Bool { kind.isSet }
    var isTriplet: Bool { kind.isTriplet }
    /// Lowest tile — a representative for pung/kong/pair (all equal) or the base of a chow.
    var representative: Tile { tiles.first ?? .m(1) }

    var isAllTerminalOrHonor: Bool { tiles.allSatisfy(\.isTerminalOrHonor) }
    var containsTerminalOrHonor: Bool { tiles.contains(where: \.isTerminalOrHonor) }

    /// A chow starting at `lowest` (must be suited rank ≤ 7), else nil.
    static func chow(_ lowest: Tile, isConcealed: Bool = false) -> Meld? {
        guard case let .suited(su, r) = lowest, r <= 7 else { return nil }
        return Meld(kind: .chow,
                    tiles: [.suited(su, r), .suited(su, r + 1), .suited(su, r + 2)],
                    isConcealed: isConcealed)
    }
    static func pung(_ t: Tile, isConcealed: Bool = false) -> Meld {
        Meld(kind: .pung, tiles: [t, t, t], isConcealed: isConcealed)
    }
    static func kong(_ t: Tile, isConcealed: Bool = true) -> Meld {
        Meld(kind: .kong, tiles: [t, t, t, t], isConcealed: isConcealed)
    }
    static func pair(_ t: Tile) -> Meld {
        Meld(kind: .pair, tiles: [t, t], isConcealed: true)
    }
}

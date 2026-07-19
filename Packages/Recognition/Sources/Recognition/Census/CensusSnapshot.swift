import Foundation
import simd
import MahjongCore

/// A count per distinct ``Tile`` face — the census's MINE/TABLE currency.
/// Keyed by ``Tile``, never by ``TileFace``: only tracks with a confirmed,
/// visible (non-`back`) face ever contribute here (§10.2).
public struct TileMultiset: Sendable, Hashable {
    public private(set) var counts: [Tile: Int]

    public init(counts: [Tile: Int] = [:]) {
        self.counts = counts
    }

    public mutating func add(_ tile: Tile, count: Int = 1) {
        counts[tile, default: 0] += count
    }

    public subscript(_ tile: Tile) -> Int { counts[tile] ?? 0 }

    public var total: Int { counts.values.reduce(0, +) }
    public var isEmpty: Bool { counts.isEmpty }
}

/// Why one physical track didn't resolve into `mine`/`table` this snapshot.
public enum UnresolvedReason: Sendable, Hashable {
    /// Bucket is `.unresolved`: no calibrated zone claims the footprint, or
    /// it straddles a zone boundary beyond tolerance (§10.1).
    case ownershipUnresolved
    /// Bucket resolved to `.mine`/`.table`, but face fusion hasn't published
    /// a face — not enough evidence yet, or conflicting strong views (§9.3).
    case faceUnresolved
    /// Downgraded by conservation (§10.3): keeping this track would exceed
    /// the physical copy limit for its published face.
    case conservationConflict
}

/// One physical track that a trustworthy census must show explicitly rather
/// than silently folding into the nearest bucket or face to make totals look
/// complete (§10.2).
public struct UnresolvedTile: Sendable, Hashable {
    public var trackID: CensusTrackID
    public var reason: UnresolvedReason
    public var anchorCenter: SIMD2<Float>
    /// The track's best face guess, if it has one — informational only;
    /// never folded into `mine`/`table` (§10.2).
    public var candidateFace: TileFace?

    public init(trackID: CensusTrackID, reason: UnresolvedReason,
                anchorCenter: SIMD2<Float>, candidateFace: TileFace? = nil) {
        self.trackID = trackID
        self.reason = reason
        self.anchorCenter = anchorCenter
        self.candidateFace = candidateFace
    }
}

/// How recently one calibrated zone has actually been observed.
public struct ZoneFreshness: Sendable, Hashable {
    public var lastObservedAt: TimeInterval?
    public var isStale: Bool

    public init(lastObservedAt: TimeInterval?, isStale: Bool) {
        self.lastObservedAt = lastObservedAt
        self.isStale = isStale
    }
}

/// A coarse, explicit trust signal for the whole snapshot — never a number
/// dressed up as false precision (§10.2: don't fold uncertainty into totals
/// merely to look complete).
public enum CensusConfidence: Sendable, Hashable, Comparable {
    case low, medium, high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (l: CensusConfidence, r: CensusConfidence) -> Bool { l.rank < r.rank }
}

/// The census's entire public output (§10.2). Only confirmed tracks with a
/// confirmed, visible face ever enter `mine`/`table`; everything else the
/// pipeline is unsure about is explicit in `unresolved`, never guessed into
/// a bucket.
public struct CensusSnapshot: Sendable {
    public var mine: TileMultiset
    public var table: TileMultiset
    public var unresolved: [UnresolvedTile]
    public var zoneFreshness: [SemanticZoneID: ZoneFreshness]
    public var coverage: [SemanticZoneID: Float]
    public var confidence: CensusConfidence
    public var generatedAt: TimeInterval

    public init(mine: TileMultiset = TileMultiset(), table: TileMultiset = TileMultiset(),
                unresolved: [UnresolvedTile] = [], zoneFreshness: [SemanticZoneID: ZoneFreshness] = [:],
                coverage: [SemanticZoneID: Float] = [:], confidence: CensusConfidence = .low,
                generatedAt: TimeInterval) {
        self.mine = mine
        self.table = table
        self.unresolved = unresolved
        self.zoneFreshness = zoneFreshness
        self.coverage = coverage
        self.confidence = confidence
        self.generatedAt = generatedAt
    }
}

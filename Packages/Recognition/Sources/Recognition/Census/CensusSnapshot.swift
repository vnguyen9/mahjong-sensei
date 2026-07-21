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

public struct CensusAnchor: Sendable, Hashable {
    public var id: CensusTrackID
    public var worldPosition: SIMD3<Float>

    public init(id: CensusTrackID, worldPosition: SIMD3<Float>) {
        self.id = id
        self.worldPosition = worldPosition
    }
}

/// The census's best recent face suggestion for an unresolved physical tile.
/// Informational only: it never contributes to gameplay counts until the
/// strong-read rule publishes it or the user confirms it.
public struct CensusFaceSuggestion: Sendable, Hashable {
    public var face: TileFace
    public var confidence: Float

    public init(face: TileFace, confidence: Float) {
        self.face = face
        self.confidence = confidence
    }
}

/// Frame-specific facts computed by the app from AR tracking, exact
/// recognizer coverage, and depth/occlusion tests. The package never guesses
/// which unmatched world tracks were genuinely visible.
public struct CensusFrameContext: Sendable {
    public var worldToTable: simd_float4x4
    /// Unmatched tracks for which the app has already proved the exact
    /// footprint is bare table. Membership is deliberately stronger than
    /// image coverage: off-screen, occluded, missing-depth, moving-camera,
    /// orientation-transition, and recognizer-failure cases must all be
    /// omitted so they cannot become retirement evidence.
    public var qualifiedEmptyTrackIDs: Set<CensusTrackID>

    public init(worldToTable: simd_float4x4,
                qualifiedEmptyTrackIDs: Set<CensusTrackID>) {
        self.worldToTable = worldToTable
        self.qualifiedEmptyTrackIDs = qualifiedEmptyTrackIDs
    }
}

public struct CensusTrackSnapshot: Sendable, Hashable {
    public var id: CensusTrackID
    public var worldPosition: SIMD3<Float>?
    public var tablePoint: SIMD2<Float>
    public var face: TileFace?
    /// Normalized 0...1 confidence for the currently published face.
    public var faceConfidence: Float
    public var faceSuggestion: CensusFaceSuggestion?
    public var strongFaceReadCount: Int
    public var faceIsUserPinned: Bool
    public var requiresManualFaceResolution: Bool
    public var semanticZone: SemanticZoneID
    public var semanticZoneIsUserOverridden: Bool
    public var lifecycle: TrackLifecycleState
    public var firstSeen: TimeInterval
    public var lastSeen: TimeInterval

    public init(id: CensusTrackID,
                worldPosition: SIMD3<Float>?,
                tablePoint: SIMD2<Float>,
                face: TileFace?,
                faceConfidence: Float,
                faceSuggestion: CensusFaceSuggestion? = nil,
                strongFaceReadCount: Int = 0,
                faceIsUserPinned: Bool = false,
                requiresManualFaceResolution: Bool = false,
                semanticZone: SemanticZoneID,
                semanticZoneIsUserOverridden: Bool = false,
                lifecycle: TrackLifecycleState,
                firstSeen: TimeInterval,
                lastSeen: TimeInterval) {
        self.id = id
        self.worldPosition = worldPosition
        self.tablePoint = tablePoint
        self.face = face
        self.faceConfidence = faceConfidence
        self.faceSuggestion = faceSuggestion
        self.strongFaceReadCount = strongFaceReadCount
        self.faceIsUserPinned = faceIsUserPinned
        self.requiresManualFaceResolution = requiresManualFaceResolution
        self.semanticZone = semanticZone
        self.semanticZoneIsUserOverridden = semanticZoneIsUserOverridden
        self.lifecycle = lifecycle
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
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
    public var tracks: [CensusTrackSnapshot]

    public init(mine: TileMultiset = TileMultiset(), table: TileMultiset = TileMultiset(),
                unresolved: [UnresolvedTile] = [], zoneFreshness: [SemanticZoneID: ZoneFreshness] = [:],
                coverage: [SemanticZoneID: Float] = [:], confidence: CensusConfidence = .low,
                generatedAt: TimeInterval, tracks: [CensusTrackSnapshot] = []) {
        self.mine = mine
        self.table = table
        self.unresolved = unresolved
        self.zoneFreshness = zoneFreshness
        self.coverage = coverage
        self.confidence = confidence
        self.generatedAt = generatedAt
        self.tracks = tracks
    }
}

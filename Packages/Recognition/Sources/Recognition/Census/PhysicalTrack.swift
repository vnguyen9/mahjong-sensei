import Foundation
import simd
import MahjongCore

/// Stable identity for one physical tile track across frames. A plain,
/// monotonically-assigned `Int` — never a `UUID` (census logic must be
/// reproducible in tests and logs, not randomness-derived, mirroring
/// ``FrameID``).
public struct CensusTrackID: Sendable, Hashable, Comparable, Codable {
    public var value: Int
    public init(_ value: Int) { self.value = value }
    public static func < (l: CensusTrackID, r: CensusTrackID) -> Bool { l.value < r.value }
}

/// Where a physical track sits in the §9.2 lifecycle.
///
/// ```
/// tentative --3 hits in 5 opportunities--> confirmed
/// tentative --window expires without 3 hits--> (dropped)
/// confirmed --qualified covered miss--> temporarilyMissing
/// temporarilyMissing --matched again--> confirmed
/// temporarilyMissing --5 qualified misses AND >=0.8s--> retired
/// confirmed --coverage lost (not a miss)--> stale
/// stale --reacquired--> confirmed
/// ```
///
/// Only `.confirmed` tracks ever contribute to `CensusSnapshot.mine`/`.table`.
public enum TrackLifecycleState: Sendable, Hashable, Codable {
    case tentative
    case confirmed
    case temporarilyMissing
    case stale
    case retired
}

/// One physical tile followed across frames: its position, accumulated face
/// evidence, and lifecycle bookkeeping. Internal — the outside world only
/// ever sees a ``CensusSnapshot``; nothing here is exposed as public API.
struct PhysicalTrack {
    let id: CensusTrackID

    // MARK: Geometry (anchor-local metres unless noted)
    var anchorCenter: SIMD2<Float>
    var worldPosition: SIMD3<Float>?
    var measuredSurfaceDepth: Float?
    var footprintRadius: Float
    /// Last known image-space box (whatever coordinate space `TileObservation.box`
    /// uses), kept only for the association cost's image-continuity term.
    var imageBox: TileBoundingBox

    // MARK: Face evidence (§9.3)
    var faceLogProbs: [TileFace: Float] = [:]
    var faceEvidenceCount: Int = 0
    var publishedFace: TileFace?
    /// Log-prob gap between the best and second-best face candidate the last
    /// time fusion ran; also doubles as this track's face-confidence signal
    /// for conservation (§10.3) tie-breaking.
    var publishedFaceMargin: Float = 0
    /// A pinned (user-corrected) face is never touched by fusion again until
    /// the track retires (§9.3).
    var isPinned: Bool = false

    // MARK: Ownership (§10.1) — geometric only, never touched by face fusion.
    var bucket: CensusBucket = .unresolved
    var semanticZone: SemanticZoneID = .boundaryUnresolved
    var semanticZoneOverride: SemanticZoneID?

    // MARK: Lifecycle (§9.2)
    var state: TrackLifecycleState = .tentative
    /// Rolling window of the last ≤`tentativeWindow` *qualified* opportunities
    /// (true = hit), used only to decide the tentative→confirmed transition.
    var recentOpportunities: [Bool] = []
    var qualifiedMissStreak: Int = 0
    var missStreakStartedAt: TimeInterval?
    var lastHitAt: TimeInterval
    var createdAt: TimeInterval

    init(id: CensusTrackID, anchorCenter: SIMD2<Float>, worldPosition: SIMD3<Float>? = nil,
         measuredSurfaceDepth: Float? = nil,
         footprintRadius: Float,
         imageBox: TileBoundingBox, at time: TimeInterval) {
        self.id = id
        self.anchorCenter = anchorCenter
        self.worldPosition = worldPosition
        self.measuredSurfaceDepth = measuredSurfaceDepth
        self.footprintRadius = footprintRadius
        self.imageBox = imageBox
        self.lastHitAt = time
        self.createdAt = time
    }
}

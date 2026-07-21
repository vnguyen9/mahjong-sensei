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
/// confirmed --depth-proven qualified-empty miss--> temporarilyMissing
/// temporarilyMissing --matched again--> confirmed
/// temporarilyMissing --5 qualified misses AND >=0.8s--> retired
/// confirmed --not explicitly proven empty--> stale
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
    struct FaceEvidenceSample {
        var face: TileFace
        var confidence: Float
    }

    /// Recent positive support, rebuilt from `recentFaceEvidence`. The
    /// detector currently returns one top class rather than a calibrated
    /// distribution, so treating absent classes as log-probabilities creates
    /// false infinite margins. Positive support keeps suggestion ranking
    /// honest while publication uses the separate strong-read rule below.
    var recentFaceEvidence: [FaceEvidenceSample] = []
    var faceSupport: [TileFace: Float] = [:]
    var faceSuggestion: CensusFaceSuggestion?
    var strongFaceCandidate: TileFace?
    var strongFaceReadCount: Int = 0
    var strongFaceConfidence: Float = 0
    var publishedFace: TileFace?
    /// Normalized detector confidence for the published face.
    var publishedFaceConfidence: Float = 0
    /// Set after two strong reads contradict an already-published face. The
    /// census stays unresolved until the user pins the correct answer.
    var requiresManualFaceResolution: Bool = false
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

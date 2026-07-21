import Foundation
import simd

/// One localized (and, once fused, classified) tile sighting in a single
/// frame — the atomic unit the (later) census consumes. Footprint fields are
/// deliberately lightweight (a center + radius, not a full covariance
/// matrix): §5.3 describes the richer footprint a geometry-aware locator can
/// fill in later without changing this contract.
public struct TileObservation: Sendable, Hashable {
    public var frameID: FrameID
    public var box: TileBoundingBox
    public var confidence: Float
    public var poseHint: TilePoseHint
    /// Filled in once the crop has been classified; nil for a locator-only observation.
    public var faceHypothesis: TileFaceHypothesis?
    /// Anchor-local metres plane-intersection estimate, once a projection exists.
    public var footprintCenter: SIMD2<Float>?
    /// Footprint uncertainty radius in metres, paired with `footprintCenter`.
    public var footprintRadius: Float?
    /// LiDAR-derived world position for this sighting. `nil` is deliberate:
    /// callers must not manufacture a guessed depth when the frame has no
    /// trustworthy medium/high-confidence sample.
    public var worldPosition: SIMD3<Float>?
    /// Median camera-axis depth at the detected tile surface. Identity uses
    /// `worldPosition`, which is projected onto the table plane.
    public var measuredSurfaceDepth: Float?
    /// Recognition provenance used to distinguish repeated boxes from
    /// genuinely independent, publication-quality detail reads. Broad
    /// discovery observations may still improve suggestions while setting
    /// `faceEvidenceQualifiesForPublication` to false.
    public var faceEvidencePassID: UInt64?
    public var faceEvidenceQualifiesForPublication: Bool
    public var faceEvidenceTimestamp: TimeInterval?

    public init(frameID: FrameID,
                box: TileBoundingBox,
                confidence: Float,
                poseHint: TilePoseHint = .unknown,
                faceHypothesis: TileFaceHypothesis? = nil,
                footprintCenter: SIMD2<Float>? = nil,
                footprintRadius: Float? = nil,
                worldPosition: SIMD3<Float>? = nil,
                measuredSurfaceDepth: Float? = nil,
                faceEvidencePassID: UInt64? = nil,
                faceEvidenceQualifiesForPublication: Bool = true,
                faceEvidenceTimestamp: TimeInterval? = nil) {
        self.frameID = frameID
        self.box = box
        self.confidence = confidence
        self.poseHint = poseHint
        self.faceHypothesis = faceHypothesis
        self.footprintCenter = footprintCenter
        self.footprintRadius = footprintRadius
        self.worldPosition = worldPosition
        self.measuredSurfaceDepth = measuredSurfaceDepth
        self.faceEvidencePassID = faceEvidencePassID
        self.faceEvidenceQualifiesForPublication = faceEvidenceQualifiesForPublication
        self.faceEvidenceTimestamp = faceEvidenceTimestamp
    }
}

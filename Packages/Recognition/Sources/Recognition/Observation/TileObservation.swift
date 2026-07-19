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

    public init(frameID: FrameID,
                box: TileBoundingBox,
                confidence: Float,
                poseHint: TilePoseHint = .unknown,
                faceHypothesis: TileFaceHypothesis? = nil,
                footprintCenter: SIMD2<Float>? = nil,
                footprintRadius: Float? = nil) {
        self.frameID = frameID
        self.box = box
        self.confidence = confidence
        self.poseHint = poseHint
        self.faceHypothesis = faceHypothesis
        self.footprintCenter = footprintCenter
        self.footprintRadius = footprintRadius
    }
}

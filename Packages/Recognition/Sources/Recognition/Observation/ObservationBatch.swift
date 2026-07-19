/// Everything one accepted, successfully-processed frame contributed: its
/// observations plus the exact coverage/quality they're valid within.
public struct ObservationBatch: Sendable {
    public var frameID: FrameID
    public var observations: [TileObservation]
    public var coverage: CoverageMask
    public var quality: FrameQuality

    public init(frameID: FrameID,
                observations: [TileObservation],
                coverage: CoverageMask,
                quality: FrameQuality) {
        self.frameID = frameID
        self.observations = observations
        self.coverage = coverage
        self.quality = quality
    }
}

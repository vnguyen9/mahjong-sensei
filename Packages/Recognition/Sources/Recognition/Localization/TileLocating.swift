/// Stage 1 of the two-stage recognizer (§7.1): finds every physical tile box
/// in a region, independent of what face it shows. Implementations must not
/// require a recognized face before emitting a box — a face-down (`back`)
/// tile is still a tile.
public protocol TileLocating: Sendable {
    func locate(in region: LocatorInput) async throws -> [TileLocalization]
}

/// One located tile: where it is and how confident the locator is that
/// *something* physical is there. No face identity — that's Stage 2's job.
public struct TileLocalization: Sendable, Hashable {
    public var box: TileBoundingBox
    public var confidence: Float
    public var poseHint: TilePoseHint

    public init(box: TileBoundingBox, confidence: Float, poseHint: TilePoseHint = .unknown) {
        self.box = box
        self.confidence = confidence
        self.poseHint = poseHint
    }
}

/// A coarse estimate of how a tile is sitting, used to decide whether its
/// footprint is safe for ownership/absence decisions (§5.3). The first
/// (one-class) locator can't predict this directly — heuristics fill it in
/// upstream — so `.unknown` is the correct default, not a fallback to avoid.
public enum TilePoseHint: Sendable, Hashable, CaseIterable {
    case flat
    case upright
    case stackedOrOccluded
    case unknown
}

/// One frame (or zone crop of a frame) handed to a locator, plus an optional
/// region of interest within it.
public struct LocatorInput: Sendable {
    public var frame: RecognizerFrame
    public var regionOfInterest: TileBoundingBox?

    public init(frame: RecognizerFrame, regionOfInterest: TileBoundingBox? = nil) {
        self.frame = frame
        self.regionOfInterest = regionOfInterest
    }
}

import Foundation

/// Why a frame (or a candidate crop within it) was not used as evidence.
/// Mirrors the deferral conditions in §6.2 plus the coarse AR-tracking gate.
public enum FrameRejectionReason: Sendable, Hashable, CaseIterable {
    case trackingNotNormal
    case belowSharpnessThreshold
    case exposureOutOfRange
    case excessiveClipping
    case tooFewProjectedPixelsPerTile
    case insufficientCoverage
    case substantiallyOccluded
    case cropMappingFailed
}

/// The frame-quality contract (§6.2): every field the capture loop needs to
/// decide whether a frame — or the candidates inside it — are usable
/// evidence. A frame is ineligible for spatial inference whenever
/// `trackingIsNormal` is false, independent of every other field.
public struct FrameQuality: Sendable, Hashable {
    public var trackingIsNormal: Bool
    public var sharpness: Float
    public var exposureScore: Float
    public var clippingFraction: Float
    public var projectedPixelsPerTile: Float
    public var coverageFraction: Float
    public var accepted: Bool
    public var rejectionReasons: Set<FrameRejectionReason>

    public init(trackingIsNormal: Bool,
                sharpness: Float,
                exposureScore: Float,
                clippingFraction: Float,
                projectedPixelsPerTile: Float,
                coverageFraction: Float,
                accepted: Bool,
                rejectionReasons: Set<FrameRejectionReason> = []) {
        self.trackingIsNormal = trackingIsNormal
        self.sharpness = sharpness
        self.exposureScore = exposureScore
        self.clippingFraction = clippingFraction
        self.projectedPixelsPerTile = projectedPixelsPerTile
        self.coverageFraction = coverageFraction
        self.accepted = accepted
        self.rejectionReasons = rejectionReasons
    }
}

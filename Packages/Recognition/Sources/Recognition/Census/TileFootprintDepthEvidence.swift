import Foundation

/// Conservative evidence for an unmatched census track's physical footprint.
/// Only `barePlane` may advance retirement; every other case must hold the
/// existing identity and count.
public enum TileFootprintDepthEvidence: String, Sendable, Equatable {
    case barePlane
    case occupied
    case occluded
    case unknown
}

/// Pure threshold policy used by the AR app after it has collected trustworthy
/// medium/high-confidence depth samples across a projected tile footprint.
public enum TileFootprintDepthClassifier {
    public static let minimumSampleCount = 3

    /// - Parameters:
    ///   - tableHeights: Sample positions relative to the locked table plane.
    ///   - cameraDepthDeltas: Sampled camera-axis depth minus the track's
    ///     expected camera-axis depth. Values below -40 mm are closer geometry.
    public static func classify(
        tableHeights: [Float],
        cameraDepthDeltas: [Float]
    ) -> TileFootprintDepthEvidence {
        let heights = tableHeights.filter(\.isFinite).sorted()
        let deltas = cameraDepthDeltas.filter(\.isFinite)
        guard heights.count >= minimumSampleCount,
              deltas.count >= minimumSampleCount else {
            return .unknown
        }

        if deltas.contains(where: { $0 < -0.040 }) {
            return .occluded
        }

        // A single trustworthy object-height sample is enough to hold a
        // narrow standing tile whose other samples may land on bare table.
        // Retirement intentionally prefers a false hold over a false removal.
        if heights.contains(where: { $0 >= 0.012 && $0 <= 0.040 }) {
            return .occupied
        }

        let median = percentile(heights, fraction: 0.5)
        let upper = percentile(heights, fraction: 0.8)
        if median >= -0.010, median <= 0.008, upper <= 0.012 {
            return .barePlane
        }

        return .unknown
    }

    private static func percentile(
        _ sortedValues: [Float],
        fraction: Float
    ) -> Float {
        let rawIndex = Int(ceil(Float(sortedValues.count) * fraction)) - 1
        return sortedValues[min(sortedValues.count - 1, max(0, rawIndex))]
    }
}

import Foundation

public struct TileSizeMeasurementSample: Sendable, Equatable {
    public let width: Float
    public let length: Float
    public let height: Float
    public let timestamp: TimeInterval

    public init(width: Float, length: Float, height: Float, timestamp: TimeInterval) {
        self.width = width
        self.length = length
        self.height = height
        self.timestamp = timestamp
    }
}

public struct TileSizeMeasurementAccumulator: Sendable {
    public static let requiredSampleCount = 5
    public static let minimumDuration: TimeInterval = 1
    public static let maximumRelativeVariation: Float = 0.10

    public enum Outcome: Sendable, Equatable {
        case collecting(sampleCount: Int)
        case accepted(TileSizeMeasurementSample)
        case rejected(Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case widthOutOfRange
        case lengthOutOfRange
        case heightOutOfRange
        case lengthMustExceedWidth
        case unstable

        public var userMessage: String {
            switch self {
            case .widthOutOfRange: return "Tile width was outside 16–32 mm."
            case .lengthOutOfRange: return "Tile length was outside 22–44 mm."
            case .heightOutOfRange: return "Tile height was outside 10–24 mm."
            case .lengthMustExceedWidth: return "Keep the tile’s long side aligned with the guide."
            case .unstable: return "Keep the iPad and tile still, then try again."
            }
        }
    }

    public private(set) var samples: [TileSizeMeasurementSample] = []

    public init() {}

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ sample: TileSizeMeasurementSample) -> Outcome {
        guard sample.width.isFinite, sample.length.isFinite, sample.height.isFinite,
              sample.width > 0, sample.length > 0, sample.height > 0 else {
            return .collecting(sampleCount: samples.count)
        }
        samples.append(sample)
        guard samples.count >= Self.requiredSampleCount,
              let first = samples.first,
              let last = samples.last,
              last.timestamp - first.timestamp >= Self.minimumDuration else {
            return .collecting(sampleCount: samples.count)
        }

        let median = TileSizeMeasurementSample(
            width: Self.median(samples.map(\.width)),
            length: Self.median(samples.map(\.length)),
            height: Self.median(samples.map(\.height)),
            timestamp: last.timestamp
        )
        if !(0.016...0.032).contains(median.width) { return .rejected(.widthOutOfRange) }
        if !(0.022...0.044).contains(median.length) { return .rejected(.lengthOutOfRange) }
        if !(0.010...0.024).contains(median.height) { return .rejected(.heightOutOfRange) }
        if median.length <= median.width { return .rejected(.lengthMustExceedWidth) }
        if !Self.isStable(samples.map(\.width), around: median.width)
            || !Self.isStable(samples.map(\.length), around: median.length)
            || !Self.isStable(samples.map(\.height), around: median.height) {
            return .rejected(.unstable)
        }
        return .accepted(median)
    }

    private static func isStable(_ values: [Float], around median: Float) -> Bool {
        guard median > 0 else { return false }
        let range = (values.max() ?? median) - (values.min() ?? median)
        return range / median <= maximumRelativeVariation
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }
}

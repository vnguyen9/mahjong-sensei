import Foundation
import MahjongCore

/// A tile bounding box in **normalized image coordinates**, origin top-left
/// (Vision reports bottom-left; convert when drawing over the preview layer).
public struct TileBoundingBox: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// One recognized tile: the predicted face, a confidence, and where it sits.
public struct DetectedTile: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var tile: Tile
    public var confidence: Double
    public var box: TileBoundingBox

    public init(id: UUID = UUID(), tile: Tile, confidence: Double, box: TileBoundingBox) {
        self.id = id; self.tile = tile; self.confidence = confidence; self.box = box
    }

    /// Confidence threshold below which the UI flags the tile amber for review (PRD).
    public static let lowConfidenceThreshold = 0.70
    public var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }
}

/// The result of recognizing a single frame / capture: tiles in left→right order.
public struct RecognitionResult: Sendable, Hashable, Codable {
    public var tiles: [DetectedTile]

    public init(tiles: [DetectedTile]) {
        self.tiles = tiles.sorted { $0.box.x < $1.box.x }
    }

    /// The predicted faces in hand order.
    public var faces: [Tile] { tiles.map(\.tile) }
    public var lowConfidenceCount: Int { tiles.filter(\.isLowConfidence).count }
    public var isEmpty: Bool { tiles.isEmpty }

    public static let empty = RecognitionResult(tiles: [])
}

public extension RecognitionResult {
    /// Builds a result by laying `faces` out in an evenly-spaced horizontal row —
    /// handy for mock data and previews. `lowConfidenceIndices` get a sub-0.7 score.
    static func row(_ faces: [Tile],
                    lowConfidenceIndices: Set<Int> = [],
                    baseConfidence: Double = 0.95) -> RecognitionResult {
        guard !faces.isEmpty else { return .empty }
        let n = Double(faces.count)
        let slot = 1.0 / n
        let tileW = slot * 0.86
        let detected = faces.enumerated().map { i, face in
            DetectedTile(
                tile: face,
                confidence: lowConfidenceIndices.contains(i) ? 0.58 : baseConfidence,
                box: TileBoundingBox(x: Double(i) * slot + (slot - tileW) / 2,
                                     y: 0.4, width: tileW, height: 0.2)
            )
        }
        return RecognitionResult(tiles: detected)
    }
}

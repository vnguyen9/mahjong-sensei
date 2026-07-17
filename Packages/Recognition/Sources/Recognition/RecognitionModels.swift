import Foundation
import MahjongCore

/// A tile bounding box in **normalized oriented-image coordinates**, origin top-left.
/// (The recognizer inverts Vision's letterbox so these map to the real photo/frame.)
public struct TileBoundingBox: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

/// One recognized tile: the predicted face, a confidence, where it sits, and
/// whether it fell inside the scan reticle (region of interest).
public struct DetectedTile: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var tile: Tile
    public var confidence: Double
    public var box: TileBoundingBox
    /// Kept for payload compatibility: detections outside the reticle are now
    /// dropped at capture (`keepingTiles(insideROI:)`), so this stays true.
    public var inReticle: Bool

    public init(id: UUID = UUID(), tile: Tile, confidence: Double,
                box: TileBoundingBox, inReticle: Bool = true) {
        self.id = id; self.tile = tile; self.confidence = confidence
        self.box = box; self.inReticle = inReticle
    }

    /// Confidence threshold below which the UI flags the tile amber for review (PRD).
    public static let lowConfidenceThreshold = 0.70
    public var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }

    // Hand-written Codable so payloads written before `inReticle` existed still decode.
    private enum CodingKeys: String, CodingKey { case id, tile, confidence, box, inReticle }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        tile = try c.decode(Tile.self, forKey: .tile)
        confidence = try c.decode(Double.self, forKey: .confidence)
        box = try c.decode(TileBoundingBox.self, forKey: .box)
        inReticle = try c.decodeIfPresent(Bool.self, forKey: .inReticle) ?? true
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tile, forKey: .tile)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(box, forKey: .box)
        try c.encode(inReticle, forKey: .inReticle)
    }
}

/// The result of recognizing a single frame / capture: tiles in reading order
/// (physical rows top→bottom, left→right within each row).
public struct RecognitionResult: Sendable, Hashable, Codable {
    public var tiles: [DetectedTile]

    public init(tiles: [DetectedTile]) {
        self.tiles = TileRowClusterer.readingOrder(tiles)
    }

    /// The predicted faces in hand order.
    public var faces: [Tile] { tiles.map(\.tile) }
    public var lowConfidenceCount: Int { tiles.filter(\.isLowConfidence).count }
    public var isEmpty: Bool { tiles.isEmpty }

    /// Tiles grouped into the physical rows the camera saw (top→bottom).
    public var rows: [[DetectedTile]] { TileRowClusterer.rows(tiles) }

    public static let empty = RecognitionResult(tiles: [])

    /// Strict reticle scope: keeps only tiles whose center falls inside `roi`
    /// (grown by a small `margin` in normalized-image units so edge-touching tiles
    /// survive). A nil ROI — photo picker, mock — keeps everything.
    public func keepingTiles(insideROI roi: TileBoundingBox?, margin: Double = 0.03) -> RecognitionResult {
        guard let roi else { return self }
        let minX = roi.x - margin, maxX = roi.x + roi.width + margin
        let minY = roi.y - margin, maxY = roi.y + roi.height + margin
        let kept = tiles.filter { tile in
            let cx = tile.box.centerX, cy = tile.box.centerY
            return cx >= minX && cx <= maxX && cy >= minY && cy <= maxY
        }
        return RecognitionResult(tiles: kept)
    }
}

/// Clusters detected tiles into physical rows by vertical position, then orders
/// rows top→bottom and tiles left→right. Pure and deterministic (testable).
public enum TileRowClusterer {
    /// Rows in top→bottom order; each row sorted left→right by box center-x.
    public static func rows(_ tiles: [DetectedTile]) -> [[DetectedTile]] {
        guard !tiles.isEmpty else { return [] }
        // A new row starts when the gap to the previous center-y exceeds half the
        // median tile height (with a small floor for degenerate boxes). Two touching
        // physical rows differ by ~1× height; within-row jitter is far smaller.
        let sortedHeights = tiles.map(\.box.height).sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]
        let tolerance = max(0.5 * medianHeight, 0.015)

        let byY = tiles.sorted { $0.box.centerY < $1.box.centerY }   // stable
        var clusters: [[DetectedTile]] = []
        var current: [DetectedTile] = []
        var lastY: Double?
        for tile in byY {
            let yc = tile.box.centerY
            if let last = lastY, yc - last > tolerance {
                clusters.append(current); current = []
            }
            current.append(tile)
            lastY = yc
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters.map { $0.sorted { $0.box.centerX < $1.box.centerX } }
    }

    /// Reading order: rows top→bottom flattened, each left→right.
    public static func readingOrder(_ tiles: [DetectedTile]) -> [DetectedTile] {
        rows(tiles).flatMap { $0 }
    }
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

    /// Builds a result laid out as multiple physical rows (top→bottom) — for
    /// previews/mocks that exercise the row-clustering path.
    static func rows(_ rows: [[Tile]], baseConfidence: Double = 0.95) -> RecognitionResult {
        let rowHeight = 0.16, vGap = 0.06
        var tiles: [DetectedTile] = []
        for (ri, row) in rows.enumerated() where !row.isEmpty {
            let n = Double(row.count)
            let slot = 1.0 / n
            let tileW = slot * 0.86
            let y = 0.28 + Double(ri) * (rowHeight + vGap)
            for (i, face) in row.enumerated() {
                tiles.append(DetectedTile(
                    tile: face, confidence: baseConfidence,
                    box: TileBoundingBox(x: Double(i) * slot + (slot - tileW) / 2,
                                         y: y, width: tileW, height: rowHeight)))
            }
        }
        return RecognitionResult(tiles: tiles)
    }
}

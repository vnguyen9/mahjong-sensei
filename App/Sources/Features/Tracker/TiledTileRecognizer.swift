import CoreGraphics
import CoreVideo
import Foundation
import MahjongCore
import Recognition

/// Tiles a captured image into an overlapping NATIVE-resolution grid,
/// recognizes each crop, maps boxes back to full-image coordinates, and
/// dedupes — the fix for feeding a whole frame to YOLO, which compresses
/// small/far tiles below the model's effective input resolution and wrecks
/// recall (Tracker plan §3, "the key requirement"). Reuses the exact crop
/// machinery Coach Live's ROI scheduler already built (`ROICropMapper`,
/// `PixelBufferCropper`) — this is a plain grid instead of AR zone rects, but
/// the same crop → recognize → map-back → dedupe chain.
enum TiledTileRecognizer {
    /// Grid dimensions — device-tunable constants (plan calls for real-device
    /// QA to retune these against a live discard pile; start 2×3).
    static let gridCols = 2
    static let gridRows = 3
    /// Fractional padding each grid cell is grown by (of its own width/height,
    /// on every side) before cropping — fed straight into `ROICropMapper
    /// .cropRect`'s own `padding` param, same convention it already uses for
    /// AR zone rects. This is what makes adjacent crops overlap, so a tile
    /// straddling a cell boundary still lands whole in at least one of them.
    static let overlap = 0.15

    /// Reused across calls — constructing a `CIContext` per crop is
    /// expensive (see `PixelBufferCropper`'s own doc).
    private static let cropper = PixelBufferCropper()

    /// Recognizes every tile in `buffer` within `roi` (or the whole frame if
    /// nil) by tiling into an overlapping native-resolution grid, running
    /// `recognize` per crop, and merging + deduping the results. `recognize`
    /// is injected so this file has no `VisionRecognizer`/loader dependency —
    /// `ScanCoordinator` supplies the shared recognizer.
    static func recognize(buffer: CVPixelBuffer, roi: TileBoundingBox?,
                           using recognize: (RecognizerFrame) async -> RecognitionResult) async -> [DetectedTile] {
        let orientedImageSize = RecognizerFrame.buffer(buffer, orientation: .right).orientedPixelSize
        let imageResolution = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard orientedImageSize.width > 0, orientedImageSize.height > 0 else { return [] }

        let region = roi ?? TileBoundingBox(x: 0, y: 0, width: 1, height: 1)
        var merged: [DetectedTile] = []
        var anyCropSucceeded = false

        for cell in gridCells(over: region) {
            let cropRect = ROICropMapper.cropRect(forZoneImageRect: cell, orientedImageSize: orientedImageSize,
                                                   imageResolution: imageResolution, padding: overlap)
            guard cropRect != .zero, let crop = cropper.crop(buffer, to: cropRect) else { continue }
            anyCropSucceeded = true
            let result = await recognize(RecognizerFrame.buffer(crop, orientation: .right))
            for det in result.tiles {
                let box = ROICropMapper.fullImageBox(fromCropNormalized: det.box, cropRect: cropRect,
                                                      imageResolution: imageResolution, orientedImageSize: orientedImageSize)
                merged.append(DetectedTile(tile: det.tile, confidence: det.confidence, box: box))
            }
        }

        guard anyCropSucceeded else {
            // Fallback: a single full-frame recognize, filtered to roi — never
            // worse than today's non-tiled path.
            let result = await recognize(RecognizerFrame.buffer(buffer, orientation: .right))
            return result.keepingTiles(insideROI: roi).tiles
        }

        return deduplicatingOverlaps(merged)
    }

    /// A plain, non-overlapping `gridCols`×`gridRows` partition of `region`
    /// (typically the ROI, or the full `[0,1]²` frame) in oriented-normalized
    /// coordinates. The actual overlap between adjacent crops comes from
    /// `overlap` being passed as `cropRect`'s padding, not from growing these
    /// cells themselves.
    private static func gridCells(over region: TileBoundingBox) -> [TileBoundingBox] {
        guard region.width > 0, region.height > 0 else { return [] }
        let cellW = region.width / Double(gridCols)
        let cellH = region.height / Double(gridRows)
        var cells: [TileBoundingBox] = []
        for row in 0..<gridRows {
            for col in 0..<gridCols {
                let x = region.x + Double(col) * cellW
                let y = region.y + Double(row) * cellH
                cells.append(TileBoundingBox(x: x, y: y, width: cellW, height: cellH))
            }
        }
        return cells
    }

    // MARK: - Dedupe (greedy class-agnostic NMS)

    /// De-duplicates detections that came from overlapping grid crops — the
    /// same physical tile can land in more than one crop's padded region.
    /// Greedy NMS: rank by confidence, keep a box only if it doesn't overlap
    /// (IoU ≥ 0.5) any box already kept. A small App-side reimplementation of
    /// `CoachLiveSession.deduplicatingOverlaps`/`boxIoU` (not shared/imported
    /// — Tracker doesn't depend on CoachLive).
    private static func deduplicatingOverlaps(_ tiles: [DetectedTile], iouThreshold: Double = 0.5) -> [DetectedTile] {
        let ranked = tiles.sorted { $0.confidence > $1.confidence }
        var kept: [DetectedTile] = []
        for tile in ranked where kept.allSatisfy({ boxIoU($0.box, tile.box) < iouThreshold }) {
            kept.append(tile)
        }
        return kept
    }

    private static func boxIoU(_ a: TileBoundingBox, _ b: TileBoundingBox) -> Double {
        let interW = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let interH = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let intersection = interW * interH
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }
}

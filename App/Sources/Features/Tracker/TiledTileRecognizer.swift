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
    /// QA to retune these against a live whole-table shot; 3×4 keeps far tiles
    /// sharp once the Tracker ROI grew to near full-frame).
    static let gridCols = 3
    static let gridRows = 4
    /// Fractional padding each grid cell is grown by (of its own width/height,
    /// on every side) before cropping — fed straight into `ROICropMapper
    /// .cropRect`'s own `padding` param, same convention it already uses for
    /// AR zone rects. This is what makes adjacent crops overlap, so a tile
    /// straddling a cell boundary still lands whole in at least one of them.
    static let overlap = 0.15
    /// Same bar as What’s-this? lookup — whole-table FOV + dense tiling needs
    /// a higher gate than the detector’s raw 0.30 default or wood/shadow FPs
    /// flood the count grid.
    static let confidenceThreshold = 0.5
    /// Normalized oriented-frame area band for a plausible single tile.
    static let minBoxArea = 0.0008
    static let maxBoxArea = 0.08
    /// Cross-crop NMS IoU — lower than the old 0.5 so the same physical tile
    /// seen in overlapping padded cells merges more aggressively.
    static let iouThreshold = 0.3
    /// Same-class near-duplicate: drop if centers are within this fraction of
    /// the larger box’s diagonal (catches IoU-just-under-threshold pairs).
    static let sameClassCenterFraction = 0.6

    /// Reused across calls — constructing a `CIContext` per crop is
    /// expensive (see `PixelBufferCropper`'s own doc).
    private static let cropper = PixelBufferCropper()

    /// Recognizes every tile in `buffer` within `roi` (or the whole frame if
    /// nil) by tiling into an overlapping native-resolution grid, running
    /// `recognize` per crop, and merging + deduping the results. `recognize`
    /// is injected so this file has no `VisionRecognizer`/loader dependency —
    /// `ScanCoordinator` supplies the shared recognizer.
    /// - Parameter minConfidence: acceptance floor for the final tiles. Defaults
    ///   to `confidenceThreshold` (0.5) for the Scan/Record photo path. Coach
    ///   Live passes the recognizer's own 0.30 so the tiled REFRESH pass gates
    ///   identically to its per-zone crop path (which passes raw 0.30) — a
    ///   mismatch there made the tiled pass return far fewer tiles, flipping
    ///   unmatched tracks live→missing and churning the count. The live
    ///   tracker's own birth/confirm gates reject wood/shadow FPs downstream.
    static func recognize(buffer: CVPixelBuffer, roi: TileBoundingBox?,
                           minConfidence: Double = confidenceThreshold,
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
            return accepting(result.keepingTiles(insideROI: roi).tiles, minConfidence: minConfidence)
        }

        return accepting(deduplicatingOverlaps(merged), minConfidence: minConfidence)
    }

    /// Confidence + box-area gate — used after tiled NMS and on the photo
    /// single-pass path so both Record entry points share the same bar.
    static func accepting(_ tiles: [DetectedTile], minConfidence: Double = confidenceThreshold) -> [DetectedTile] {
        tiles.filter { det in
            guard det.confidence >= minConfidence else { return false }
            let area = det.box.width * det.box.height
            return area >= minBoxArea && area <= maxBoxArea
        }
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

    // MARK: - Dedupe (greedy class-agnostic NMS + same-class center rule)

    /// De-duplicates detections that came from overlapping grid crops — the
    /// same physical tile can land in more than one crop's padded region.
    /// Greedy NMS by confidence, then a same-class center-distance rule for
    /// near-duplicates whose IoU sits just under `iouThreshold`.
    private static func deduplicatingOverlaps(_ tiles: [DetectedTile]) -> [DetectedTile] {
        let ranked = tiles.sorted { $0.confidence > $1.confidence }
        var kept: [DetectedTile] = []
        for tile in ranked {
            let isDuplicate = kept.contains { existing in
                if boxIoU(existing.box, tile.box) >= Self.iouThreshold { return true }
                guard existing.tile == tile.tile else { return false }
                return centersNear(existing.box, tile.box, fraction: sameClassCenterFraction)
            }
            if !isDuplicate { kept.append(tile) }
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

    /// True when box centers are within `fraction` of the larger box’s diagonal.
    private static func centersNear(_ a: TileBoundingBox, _ b: TileBoundingBox, fraction: Double) -> Bool {
        let dx = a.centerX - b.centerX
        let dy = a.centerY - b.centerY
        let dist = (dx * dx + dy * dy).squareRoot()
        let largerDiag = max(hypot(a.width, a.height), hypot(b.width, b.height))
        return largerDiag > 0 && dist <= fraction * largerDiag
    }
}

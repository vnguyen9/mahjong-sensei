import CoreGraphics
import ImageIO
import Recognition

/// Pure coordinate math between two spaces the AR ROI pipeline (Lane B
/// chunk E) has to cross every tick:
///
/// - **NATIVE captured-image pixel space** — the raw, un-rotated buffer
///   ARKit hands back (`ARTableFrame.pixelBuffer`, size `imageResolution`),
///   origin top-left, `+x` right, `+y` down. Exactly `TableProjection`'s own
///   "Captured-image pixel space" (see that type's doc) — this file reuses
///   its `.right`-rotation derivation, just as plain 2D point math with no
///   camera/plane involved.
/// - **Normalized ORIENTED-image space** — the captured buffer rotated
///   `.right` (90° clockwise) then normalized `[0,1]×[0,1]`, origin
///   top-left. This is `DetectedTile.box`'s space (`ZoneBoxes`,
///   `TrackedTile.box` in image-space mode, and — after
///   `CoachLiveSession.updateARZoneBoxes`'s own projection — the ROI
///   scheduler's zone rects too).
///
/// Two pure functions do the actual work the ROI loop needs:
/// `cropRect` (oriented zone rect → native pixel crop rect, what
/// `PixelBufferCropper` slices) and `fullImageBox` (a crop-relative
/// detection box → full-image oriented box, the exact inverse chain). A
/// third, `orientedNormalizedRect`, is the plain forward half of that same
/// relationship — used by `ROIScheduler` to place `MotionField` grid cells
/// (which live in the SAME native/raw space as the full buffer) into
/// oriented-image coordinates for the "did a changed cell land inside this
/// zone" test.
enum ROICropMapper {

    /// Normalized ORIENTED zone rect → NATIVE captured-image pixel crop
    /// rect, padded and clamped.
    ///
    /// Derivation: grow `zoneRect` by `padding` × its own width/height on
    /// each side (mirrors `ScanView.croppedFrame`'s reticle-margin
    /// convention — keeps a tile whose box straddles the zone edge whole),
    /// clamp to `[0,1]`, then map the two corners through
    /// `orientedNormalizedToRaw` (`TableProjection`'s `tablePoint` step 1,
    /// reused here as pure 2D math) to get a native pixel rect. Finally
    /// clamp to the buffer bounds and snap outward to even pixel
    /// coordinates/size — 420f's chroma planes are subsampled 2:1, so an odd
    /// crop origin or size would misalign the chroma plane when
    /// `PixelBufferCropper` slices it. Snapping OUTWARD (floor the min
    /// corner, ceil the max corner) means the returned rect is always a
    /// superset of the padded zone — recall never gets clipped by rounding.
    ///
    /// Returns `.zero` for degenerate input (a zero-size zone rect, an
    /// invalid buffer size, or a padded rect that clamps away to nothing) —
    /// callers treat that like any other crop failure.
    static func cropRect(forZoneImageRect zoneRect: TileBoundingBox,
                          orientedImageSize: CGSize,
                          imageResolution: CGSize,
                          imageOrientation: CGImagePropertyOrientation = .right,
                          padding: Double = 0.12) -> CGRect {
        guard imageResolution.width > 0, imageResolution.height > 0,
              orientedImageSize.width > 0, orientedImageSize.height > 0 else { return .zero }

        let pad = CGFloat(padding)
        let zx = CGFloat(zoneRect.x), zy = CGFloat(zoneRect.y)
        let zw = CGFloat(zoneRect.width), zh = CGFloat(zoneRect.height)
        let padX = zw * pad, padY = zh * pad
        let x0 = max(0, zx - padX)
        let y0 = max(0, zy - padY)
        let x1 = min(1, zx + zw + padX)
        let y1 = min(1, zy + zh + padY)
        guard x1 > x0, y1 > y0 else { return .zero }

        let transform = FrameImageTransform(
            imageOrientation: imageOrientation,
            imageResolution: imageResolution
        )
        let corners = [
            SIMD2<Double>(Double(x0), Double(y0)),
            SIMD2<Double>(Double(x1), Double(y0)),
            SIMD2<Double>(Double(x1), Double(y1)),
            SIMD2<Double>(Double(x0), Double(y1)),
        ].map { point -> CGPoint in
            let raw = transform.rawNormalized(fromOriented: point)
            return CGPoint(
                x: raw.x * imageResolution.width,
                y: raw.y * imageResolution.height
            )
        }
        let rawMinX = corners.map(\.x).min()!
        let rawMaxX = corners.map(\.x).max()!
        let rawMinY = corners.map(\.y).min()!
        let rawMaxY = corners.map(\.y).max()!

        let clampedMinX = max(0, min(rawMinX, imageResolution.width))
        let clampedMinY = max(0, min(rawMinY, imageResolution.height))
        let clampedMaxX = max(0, min(rawMaxX, imageResolution.width))
        let clampedMaxY = max(0, min(rawMaxY, imageResolution.height))
        guard clampedMaxX > clampedMinX, clampedMaxY > clampedMinY else { return .zero }

        let evenMinX = floorEven(clampedMinX)
        let evenMinY = floorEven(clampedMinY)
        let evenMaxX = min(ceilEven(clampedMaxX), floorEven(imageResolution.width))
        let evenMaxY = min(ceilEven(clampedMaxY), floorEven(imageResolution.height))
        guard evenMaxX > evenMinX, evenMaxY > evenMinY else { return .zero }

        return CGRect(x: evenMinX, y: evenMinY, width: evenMaxX - evenMinX, height: evenMaxY - evenMinY)
    }

    /// A detection box normalized to a CROP's own oriented image → the
    /// full-image normalized ORIENTED box — the exact inverse of the chain
    /// `cropRect` half-describes, run one level deeper.
    ///
    /// Why this is safe: `PixelBufferCropper` crops the NATIVE (un-rotated)
    /// buffer, so `RecognizerFrame.buffer(crop, orientation: .right)` rotates
    /// the crop exactly the same way the full frame is rotated — Vision's
    /// own `orientedPixelSize` (see `RecognizerFrame`) guarantees the crop's
    /// oriented size is the swap of its native pixel size
    /// (`(cropRect.height, cropRect.width)`), never something the app has to
    /// assume independently. So `tile.box` (the recognizer's output for a
    /// crop) is normalized to THAT swapped size, not the full image's.
    ///
    /// The chain back: (1) crop-oriented-normalized → crop-local NATIVE
    /// pixel coordinates, via the crop's own native/oriented sizes; (2) add
    /// `cropRect`'s own native-pixel origin to land in the FULL buffer's
    /// native pixel space; (3) full native pixel → full-image
    /// oriented-normalized, the plain forward direction. Each step reuses
    /// the same `.right`-rotation point math `cropRect` uses in reverse.
    static func fullImageBox(fromCropNormalized cropNormalized: TileBoundingBox,
                              cropRect: CGRect,
                              imageResolution: CGSize,
                              orientedImageSize: CGSize,
                              imageOrientation: CGImagePropertyOrientation = .right) -> TileBoundingBox {
        guard cropRect.width > 0, cropRect.height > 0,
              imageResolution.width > 0, imageResolution.height > 0,
              orientedImageSize.width > 0, orientedImageSize.height > 0 else {
            return TileBoundingBox(x: 0, y: 0, width: 0, height: 0)
        }

        let cropRawSize = CGSize(width: cropRect.width, height: cropRect.height)
        let cropTransform = FrameImageTransform(
            imageOrientation: imageOrientation,
            imageResolution: cropRawSize
        )
        let fullTransform = FrameImageTransform(
            imageOrientation: imageOrientation,
            imageResolution: imageResolution
        )
        let x0 = cropNormalized.x
        let y0 = cropNormalized.y
        let x1 = cropNormalized.x + cropNormalized.width
        let y1 = cropNormalized.y + cropNormalized.height
        let corners = [
            SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1),
        ].map { oriented -> SIMD2<Double> in
            let localRaw = cropTransform.rawNormalized(fromOriented: oriented)
            let fullRaw = SIMD2<Double>(
                (cropRect.minX + localRaw.x * cropRect.width) / imageResolution.width,
                (cropRect.minY + localRaw.y * cropRect.height) / imageResolution.height
            )
            return fullTransform.orientedNormalized(fromRaw: fullRaw)
        }
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        return TileBoundingBox(x: Double(minX), y: Double(minY), width: Double(maxX - minX), height: Double(maxY - minY))
    }

    /// A rect in NATIVE (raw, un-rotated) pixel space — for a buffer whose
    /// own native/oriented sizes are `rawSize`/`orientedSize` — mapped
    /// forward into normalized ORIENTED-image space. The plain forward half
    /// of the same relationship `cropRect` inverts; used by `ROIScheduler`
    /// to place `MotionField` grid cells (native/raw space, same buffer as
    /// the full frame) against zone rects (oriented space).
    static func orientedNormalizedRect(fromRawRect rawRect: CGRect, rawSize: CGSize,
                                       orientedSize: CGSize,
                                       imageOrientation: CGImagePropertyOrientation = .right) -> TileBoundingBox {
        let transform = FrameImageTransform(
            imageOrientation: imageOrientation,
            imageResolution: rawSize
        )
        let corners = [
            CGPoint(x: rawRect.minX, y: rawRect.minY),
            CGPoint(x: rawRect.maxX, y: rawRect.minY),
            CGPoint(x: rawRect.maxX, y: rawRect.maxY),
            CGPoint(x: rawRect.minX, y: rawRect.maxY),
        ].map {
            transform.orientedNormalized(fromRaw: SIMD2<Double>(
                Double($0.x / rawSize.width),
                Double($0.y / rawSize.height)
            ))
        }
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        return TileBoundingBox(x: Double(minX), y: Double(minY), width: Double(maxX - minX), height: Double(maxY - minY))
    }

    private static func floorEven(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
    private static func ceilEven(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.up) * 2 }
}

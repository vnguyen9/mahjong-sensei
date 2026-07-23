import CoreGraphics
import ImageIO

/// Converts a rectangle normalized to the **oriented** image — the space
/// `VisionRecognizer.detectRawBoxes`/`recognize(_:)` return boxes in, i.e. the
/// sensor-native buffer with `camera.imageOrientation` already applied — back
/// into the **native** (unrotated, landscape sensor) buffer's normalized
/// space. That native space is exactly what `AVCaptureConnection`'s metadata
/// coordinate space uses, so the result here is what
/// `AVCaptureVideoPreviewLayer.layerRectConverted(fromMetadataOutputRect:)`
/// (and `AVCapturePhotoOutput.outputRectConverted(fromMetadataOutputRect:)`,
/// already used by the Tracker still-capture ROI path) expects as input.
///
/// ## Convention verified against the existing working code
/// `TrackerLiveDetector.captureHandSnapshot`/`ScanView.shutterTapped` treat
/// `AVCaptureVideoPreviewLayer.metadataOutputRectConverted(fromLayerRect:)`'s
/// output as a rect on the *native* (unrotated) buffer: it is fed straight
/// into `photoOutput.outputRectConverted(fromMetadataOutputRect:)` and into
/// pixel math against `CVPixelBufferGetWidth/Height` of the raw buffer
/// (`CameraPreview.swift` `updateTrackerReticle`, `TrackerLiveDetector.swift`
/// `captureHandSnapshot`) — never against `orientedPixelSize`. Meanwhile
/// `ScanView.croppedFrame`/`scoreGuideROI` work in **oriented** image space
/// (they pass `orientation:` to `CIImage.oriented(_:)` and crop the result).
/// These two parallel, already-correct paths pin down the two coordinate
/// spaces this type bridges.
///
/// `CGImagePropertyOrientation` describes the clockwise rotation applied to
/// the native buffer to produce the oriented image
/// (`ScanCameraOrientation.imageOrientation`: portrait → `.right`, i.e. the
/// landscape sensor buffer is rotated 90° clockwise to stand up). Inverting
/// that rotation for a rectangle (not just a point) requires remapping all
/// four corners, which is what the per-case math below does.
public enum NormalizedRectOrientation {
    /// - Parameters:
    ///   - box: A box normalized to the oriented image (top-left origin).
    ///   - orientation: The orientation that was applied to the native buffer
    ///     to produce that oriented image (e.g. the `imageOrientation` the
    ///     detection frame was run with).
    /// - Returns: The equivalent box normalized to the native (unrotated)
    ///   buffer — metadata-output space.
    public static func metadataRect(fromOriented box: TileBoundingBox,
                                    orientation: CGImagePropertyOrientation) -> TileBoundingBox {
        switch orientation {
        case .up, .upMirrored:
            // No rotation: oriented image == native buffer.
            return box

        case .down, .downMirrored:
            // 180° rotation is its own inverse; width/height are unchanged,
            // only the origin corner flips to the opposite corner.
            return TileBoundingBox(
                x: 1 - box.x - box.width,
                y: 1 - box.y - box.height,
                width: box.width,
                height: box.height
            )

        case .right, .rightMirrored:
            // Oriented image = native buffer rotated 90° clockwise, so the
            // inverse rotates the box 90° counterclockwise back to native
            // space (dimensions swap: native width == oriented height).
            return TileBoundingBox(
                x: box.y,
                y: 1 - box.x - box.width,
                width: box.height,
                height: box.width
            )

        case .left, .leftMirrored:
            // Oriented image = native buffer rotated 90° counterclockwise, so
            // the inverse rotates the box 90° clockwise back to native space.
            return TileBoundingBox(
                x: 1 - box.y - box.height,
                y: box.x,
                width: box.height,
                height: box.width
            )

        @unknown default:
            return box
        }
    }
}

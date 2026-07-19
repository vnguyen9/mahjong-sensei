import CoreVideo
import Vision
import simd

/// Calibration-only index-fingertip detection on top of Vision's
/// `VNDetectHumanHandPoseRequest`.
///
/// This is invoked ONLY during the brief table-calibration phase (the user
/// pointing at the table to mark a zone), never during live play tracking —
/// so its per-call Vision cost (a full hand-pose inference on a captured
/// frame) is bounded to a short, low-cadence window and is not a concern for
/// the always-on recognition pipeline.
///
/// The returned point is a normalized ORIENTED point in exactly the space
/// `Recognition.TableProjection.tablePoint(ofNormalizedOrientedPoint:orientedImageSize:)`
/// consumes — feed it straight in (together with the same frame's
/// `orientedImageSize`) to raycast the fingertip onto the locked table
/// plane, the same way `TableCalibrationView.handleDrag` raycasts a
/// finger-drag screen location.
enum HandPoseFingertip {
    /// Detects a single hand in `pixelBuffer` (a landscape ARKit
    /// `capturedImage`, biplanar YCbCr, camera treated as `.right`-oriented
    /// throughout the app) and returns its index-finger tip as a normalized
    /// oriented point — portrait, as-viewed, top-left origin, `x` horizontal
    /// `0...1` left-to-right, `y` vertical `0...1` top-to-bottom.
    ///
    /// Returns `nil` when no hand is found, the index-tip landmark is
    /// missing, or its confidence is below `minimumConfidence`.
    ///
    /// ## Coordinate derivation
    ///
    /// `VNImageRequestHandler` is given `orientation: .right` — the same
    /// "raw landscape buffer needs a 90° clockwise turn to appear upright"
    /// convention `TableProjection`'s doc comment describes and
    /// `ARTableFrame.orientedImageSize` assumes everywhere else in this
    /// pipeline. With that orientation, Vision already returns landmark
    /// locations relative to the *rotated, upright (portrait)* image — so no
    /// manual `.right` rotation math is needed here, only Vision's own
    /// normalized-coordinate convention needs converting:
    ///
    /// Vision's `VNRecognizedPoint.location` is normalized with a
    /// **bottom-left** origin, `+x` right, `+y` up (the standard Vision/CI
    /// convention, independent of the `orientation` passed to the request —
    /// that parameter only corrects *which way is up*, not the origin/axis
    /// sense of the reported coordinates). The rest of this pipeline's
    /// "oriented-normalized" `p` — see `TableProjection` — instead uses a
    /// **top-left** origin, `+x` right, `+y` down (ordinary image/screen
    /// convention; this is also exactly what
    /// `AspectFillMapping.normalizedImageRect` and
    /// `TableCalibrationView.handleDrag` produce from a screen touch).
    ///
    /// The horizontal axis needs no flip (both conventions put `x = 0` at
    /// the left edge, `x = 1` at the right edge), so:
    ///
    ///     p.x = point.location.x
    ///     p.y = 1 - point.location.y
    ///
    /// which is the only adjustment required to land in `tablePoint`'s
    /// input space.
    static func indexFingertipOrientedPoint(in pixelBuffer: CVPixelBuffer,
                                             minimumConfidence: Float = 0.5) -> SIMD2<Double>? {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first else { return nil }

        let indexTipPoint: VNRecognizedPoint
        do {
            indexTipPoint = try observation.recognizedPoint(.indexTip)
        } catch {
            return nil
        }

        guard indexTipPoint.confidence >= minimumConfidence else { return nil }

        let orientedX = Double(indexTipPoint.location.x)
        let orientedY = 1 - Double(indexTipPoint.location.y)
        return SIMD2<Double>(orientedX, orientedY)
    }
}

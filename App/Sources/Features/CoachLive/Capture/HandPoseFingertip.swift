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
        return orientedPoint(indexTipPoint)
    }

    /// One pinch reading: the thumb+index midpoint (in `tablePoint` input
    /// space), whether the two tips are close enough to count as an active
    /// pinch, and their normalized gap (for a light hysteresis in the caller).
    struct PinchSample {
        /// Midpoint of the thumb and index tips — a normalized ORIENTED point,
        /// feed straight into `TableProjection.tablePoint(...)`.
        let point: SIMD2<Double>
        /// True when the tips are within `pinchThreshold` of each other.
        let isPinching: Bool
        /// Thumb↔index distance in oriented-normalized units.
        let gap: Double
    }

    /// Detects a thumb+index **pinch** — the primary calibration gesture
    /// (drop a post where thumb and index meet). Returns `nil` when a hand or
    /// either tip is missing / low-confidence; otherwise reports the midpoint
    /// and whether it's an active pinch (`gap <= pinchThreshold`). The caller
    /// places a post on the pinch-close edge and keeps `tap` as a fallback.
    ///
    /// `pinchThreshold` is in the same oriented-normalized units as `point`
    /// (fraction of the portrait frame's larger dimension); ~0.045 ≈ tips
    /// nearly touching. Calibration-only, same bounded Vision cost as the
    /// index-tip path.
    static func pinch(in pixelBuffer: CVPixelBuffer,
                      pinchThreshold: Double = 0.045,
                      minimumConfidence: Float = 0.3) -> PinchSample? {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first else { return nil }

        let thumb: VNRecognizedPoint
        let index: VNRecognizedPoint
        do {
            thumb = try observation.recognizedPoint(.thumbTip)
            index = try observation.recognizedPoint(.indexTip)
        } catch { return nil }
        guard thumb.confidence >= minimumConfidence, index.confidence >= minimumConfidence else { return nil }

        let t = orientedPoint(thumb), i = orientedPoint(index)
        let mid = SIMD2<Double>((t.x + i.x) / 2, (t.y + i.y) / 2)
        let gap = (SIMD2<Double>(t.x - i.x, t.y - i.y)).gapLength
        return PinchSample(point: mid, isPinching: gap <= pinchThreshold, gap: gap)
    }

    /// Converts a Vision landmark (bottom-left origin, +y up) into the
    /// pipeline's oriented-normalized point (top-left origin, +y down) — the
    /// only adjustment `tablePoint`'s input space needs (see the doc above).
    private static func orientedPoint(_ p: VNRecognizedPoint) -> SIMD2<Double> {
        SIMD2<Double>(Double(p.location.x), 1 - Double(p.location.y))
    }
}

private extension SIMD2 where Scalar == Double {
    var gapLength: Double { (x * x + y * y).squareRoot() }
}

import CoreGraphics
import CoreVideo
import ImageIO
import Recognition
import simd

/// One ARKit-captured frame's data, trimmed to exactly what the projection
/// and tracking pipeline need — a plain value-type snapshot so
/// `ARTableCapture` can cache/publish it without holding onto a live
/// `ARFrame` (a heavier, session-owned object) past the delegate callback
/// that produced it.
///
/// `cameraTransform` and `intrinsics` are handed to
/// `Recognition.TableProjection`'s `Float` initializer completely
/// unmodified — they are ARKit-native, in the **captured-image (always
/// landscape) pixel space** that type's doc comment describes:
/// `cameraTransform` is `ARCamera.transform` (camera-local → world,
/// column-major `simd`, right-handed, camera looks down its local -Z), and
/// `intrinsics` is `ARCamera.intrinsics` (`fx 0 cx / 0 fy cy / 0 0 1`, in
/// landscape captured-image pixels, `+x` right / `+y` down). Do not rotate
/// or otherwise adjust either value before handing it to `TableProjection`
/// — that type performs the landscape → oriented-portrait conversion
/// internally, from `imageResolution`/`orientedImageSize` alone.
public struct ARTableFrame {
    /// The raw captured-image pixel buffer (`ARFrame.capturedImage`) —
    /// always landscape. Callers that need it in the app's usual BGRA shape
    /// for `RecognizerFrame` convert as needed (ARKit's default capture
    /// format is biplanar YCbCr, not BGRA).
    public let pixelBuffer: CVPixelBuffer
    /// `ARCamera.transform` — camera-local → world.
    public let cameraTransform: simd_float4x4
    /// `ARCamera.intrinsics` — captured-image (landscape) pixel intrinsics.
    public let intrinsics: simd_float3x3
    /// `ARFrame.camera.imageResolution` — captured (landscape) pixel size,
    /// `(width, height)`.
    public let imageResolution: CGSize
    public let imageTransform: FrameImageTransform
    /// `ARFrame.lightEstimate?.ambientIntensity` (lumens/lux-scaled 0–2000
    /// per ARKit's convention), when the session supplies one. `nil` when
    /// no light estimate is available yet (e.g. the very first frames),
    /// matching the `ARFrame` API's own optionality.
    public let lightLux: Double?
    /// LiDAR scene depth captured for this exact camera frame. The buffer is
    /// lower-resolution than `pixelBuffer` and stores metres as Float32.
    /// `nil` on unsupported devices and frames where ARKit has no estimate.
    public let depthMap: CVPixelBuffer?
    /// Per-depth-pixel `ARConfidenceLevel` values for `depthMap`. Kept
    /// optional independently because a depth estimate without confidence
    /// is not trustworthy enough to create a spatial census observation.
    public let depthConfidence: CVPixelBuffer?
    /// `ARFrame.timestamp` — monotonic seconds, NOT wall-clock (the same
    /// `CACurrentMediaTime()`-comparable epoch the rest of the tracking
    /// pipeline uses for `TableTracker.ingest(at:)`).
    public let timestamp: TimeInterval

    public init(pixelBuffer: CVPixelBuffer,
                cameraTransform: simd_float4x4,
                intrinsics: simd_float3x3,
                imageResolution: CGSize,
                imageOrientation: CGImagePropertyOrientation = .right,
                lightLux: Double?,
                depthMap: CVPixelBuffer? = nil,
                depthConfidence: CVPixelBuffer? = nil,
                timestamp: TimeInterval) {
        self.pixelBuffer = pixelBuffer
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
        self.imageResolution = imageResolution
        self.imageTransform = FrameImageTransform(
            imageOrientation: imageOrientation,
            imageResolution: imageResolution
        )
        self.lightLux = lightLux
        self.depthMap = depthMap
        self.depthConfidence = depthConfidence
        self.timestamp = timestamp
    }

    /// The oriented (portrait) image's pixel size — a pure width/height
    /// swap of `imageResolution`, matching `TableProjection`'s
    /// "oriented-image normalized space" convention: the app always rotates
    /// a captured-landscape buffer `.right` (90° clockwise) to portrait
    /// before detection, and `DetectedTile.box` lives in that rotated,
    /// normalized frame.
    public var orientedImageSize: CGSize {
        imageTransform.orientedImageSize
    }

    public var imageOrientation: CGImagePropertyOrientation {
        imageTransform.imageOrientation
    }
}

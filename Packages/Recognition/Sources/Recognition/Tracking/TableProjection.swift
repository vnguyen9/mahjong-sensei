import simd
import Foundation

/// Projects between the app's normalized, oriented-image pixel space (the
/// space `DetectedTile.box` lives in) and a locked ARKit table-plane
/// anchor's local `(x, z)` coordinates.
///
/// Pure math, no ARKit/UIKit dependency — every matrix is injected by the
/// caller (the app owns the `ARSession`/`ARFrame`/`ARPlaneAnchor` reads and
/// hands the raw numbers in here), which is what keeps this fully
/// CI-testable with synthetic matrices and keeps the `Recognition` package
/// platform-pure.
///
/// ## Coordinate conventions (all ARKit-standard)
///
/// - **World / camera space**: right-handed, ARKit's convention — the camera
///   looks down its local **-Z** axis, **+Y** is up, **+X** is right. All the
///   4x4 transforms here are **column-major `simd` matrices** that map a
///   point/vector *from* the named local space *into* world space — exactly
///   ARKit's own `transform` convention (`ARCamera.transform`,
///   `ARAnchor.transform` are both local→world).
/// - **Captured-image pixel space**: the raw sensor buffer ARKit hands back
///   (`ARFrame.capturedImage`), always **landscape**, standard image
///   convention — origin top-left, `+x` right, `+y` down. `intrinsics` and
///   `imageResolution` are both in this space.
/// - **Oriented-image normalized space**: the app's UI/detector space — the
///   captured (landscape) buffer rotated `.right` (90° clockwise) to
///   portrait, then normalized to `[0,1] x [0,1]`, origin top-left. This is
///   *exactly* the space `DetectedTile.box` uses (see `RecognizerFrame` /
///   `VisionRecognizer`, which build `TileBoundingBox`es by inverting the
///   detector's letterbox back into this same oriented, normalized frame).
///   `orientedImageSize` is that portrait image's pixel size — for a pure
///   90° rotation of `imageResolution` it equals
///   `(imageResolution.y, imageResolution.x)`, but callers pass it
///   explicitly rather than have this type assume the relationship holds
///   exactly.
/// - **Plane / anchor-local space**: an `ARPlaneAnchor`'s local frame — the
///   plane surface is **y = 0**, extending in local **x/z**; local **+y** is
///   the plane's outward normal. `planeTransform` is that anchor's
///   `transform` (anchor-local → world). Anchor-local `(x, z)` points are
///   passed around this type packed into a `SIMD2<Double>` as
///   `(x: local x, y: local z)` — i.e. the `SIMD2`'s `.y` component holds the
///   plane's local **z** axis, not its (always ~0 on-plane) vertical axis.
///
/// ## The `.right` rotation (captured landscape → oriented portrait)
///
/// `CGImagePropertyOrientation.right` (EXIF tag 6) means the raw buffer must
/// be rotated **90° clockwise** to display upright — the convention the app
/// uses everywhere it builds a `RecognizerFrame` from a live capture buffer.
/// For a captured pixel `(xr, yr)` in an `imageResolution = (Wr, Hr)` buffer,
/// the corresponding oriented pixel `(xo, yo)` in an
/// `orientedImageSize = (Wo, Ho)` image is:
///
///     xo = Hr - yr
///     yo = xr
///
/// (raw top-left → oriented top-right; raw bottom-left → oriented top-left —
/// exactly a 90°-clockwise turn: the raw left edge becomes the oriented top
/// edge, the raw top edge becomes the oriented right edge.) Inverting:
///
///     xr = yo
///     yr = Hr - xo
///
/// This type works entirely in *normalized* coordinates (`u = x/W, v = y/H`),
/// so with normalized oriented `(uo, vo)` and captured pixel `(xr, yr)` the
/// same relationship becomes:
///
///     xr = vo * Ho
///     yr = Hr - uo * Wo
///
/// and inverting (captured pixel → oriented normalized):
///
///     uo = (Hr - yr) / Wo
///     vo = xr / Ho
///
/// ## Pinhole (un)projection
///
/// `intrinsics` follows the standard "computer-vision" pixel convention
/// (`+x` right, `+y` down, camera looks down `+z`). ARKit's *camera space*,
/// by contrast, looks down **-z** with **+y up** — the same axis flip as
/// OpenGL vs. OpenCV. So unprojecting a captured pixel to a camera-space ray
/// direction requires flipping `y` and `z` after the usual
/// `((x - cx)/fx, (y - cy)/fy, 1)` unprojection:
///
///     d_cam = ( (xr - cx)/fx, -(yr - cy)/fy, -1 )
///
/// and projecting a camera-space point `(Xc, Yc, Zc)` (with `Zc < 0` in
/// front of the camera) back to a captured pixel reverses that flip before
/// the perspective divide:
///
///     x_cv = Xc,  y_cv = -Yc,  z_cv = -Zc   (> 0 in front of the camera)
///     xr = fx * (x_cv / z_cv) + cx
///     yr = fy * (y_cv / z_cv) + cy
public struct TableProjection: Sendable {
    /// Camera-local → world (ARKit `ARCamera.transform` convention).
    public let cameraTransform: simd_double4x4
    /// `fx 0 cx / 0 fy cy / 0 0 1`, in captured-image (landscape) pixels.
    public let intrinsics: simd_double3x3
    /// Captured (landscape) image pixel size, `(width, height)`.
    public let imageResolution: SIMD2<Double>
    /// Table-plane anchor-local → world (ARKit `ARPlaneAnchor.transform`
    /// convention: plane surface is local `y = 0`, local `+y` is the normal).
    public let planeTransform: simd_double4x4

    public init(cameraTransform: simd_double4x4,
                intrinsics: simd_double3x3,
                imageResolution: SIMD2<Double>,
                planeTransform: simd_double4x4) {
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
        self.imageResolution = imageResolution
        self.planeTransform = planeTransform
    }

    /// Ergonomic entry point for call sites holding ARKit's native `Float`
    /// types (`ARCamera.transform`/`.intrinsics`, `ARAnchor.transform`) —
    /// converts once to `Double` here so the projection math itself never has
    /// to think about precision.
    public init(cameraTransform: simd_float4x4,
                intrinsics: simd_float3x3,
                imageResolution: SIMD2<Float>,
                planeTransform: simd_float4x4) {
        self.init(
            cameraTransform: Self.double4x4(cameraTransform),
            intrinsics: Self.double3x3(intrinsics),
            imageResolution: SIMD2<Double>(Double(imageResolution.x), Double(imageResolution.y)),
            planeTransform: Self.double4x4(planeTransform)
        )
    }

    /// `simd` has no built-in `Float` → `Double` matrix conversion
    /// initializer, so these convert column-by-column.
    private static func double4x4(_ m: simd_float4x4) -> simd_double4x4 {
        simd_double4x4(
            SIMD4<Double>(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z), Double(m.columns.0.w)),
            SIMD4<Double>(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z), Double(m.columns.1.w)),
            SIMD4<Double>(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z), Double(m.columns.2.w)),
            SIMD4<Double>(Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z), Double(m.columns.3.w))
        )
    }

    private static func double3x3(_ m: simd_float3x3) -> simd_double3x3 {
        simd_double3x3(
            SIMD3<Double>(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
            SIMD3<Double>(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
            SIMD3<Double>(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z))
        )
    }

    // MARK: - Oriented-normalized → table (anchor-local x, z)

    /// Unprojects a normalized oriented-image point into a camera ray and
    /// intersects it with the locked table plane, returning the hit in
    /// anchor-local `(x, z)` (packed as `SIMD2(x: local x, y: local z)`).
    ///
    /// Returns `nil` when the ray is parallel to the plane (never hits) or
    /// the hit falls behind the camera (the table plane isn't actually
    /// visible along that ray — e.g. a horizon-level pixel with a plane the
    /// camera is looking away from).
    public func tablePoint(ofNormalizedOrientedPoint p: SIMD2<Double>,
                           orientedImageSize: SIMD2<Double>) -> SIMD2<Double>? {
        tablePoint(
            ofNormalizedOrientedPoint: p,
            imageTransform: legacyRightTransform
        )
    }

    public func tablePoint(
        ofNormalizedOrientedPoint p: SIMD2<Double>,
        imageTransform: FrameImageTransform
    ) -> SIMD2<Double>? {
        guard let rawPixel = rawPixel(
            fromOrientedNormalized: p,
            imageTransform: imageTransform
        ) else { return nil }

        let xr = rawPixel.x
        let yr = rawPixel.y

        // 2. Captured pixel → camera-space ray direction: pinhole
        //    unprojection, then the CV→ARKit axis flip (+y down/+z forward
        //    → +y up/-z forward).
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        guard fx != 0, fy != 0 else { return nil }
        let dCam = SIMD4<Double>((xr - cx) / fx, -(yr - cy) / fy, -1, 0)

        // 3. Camera-space ray → world-space ray. `w = 0` on a direction drops
        //    the matrix's translation column, leaving only the rotation;
        //    `w = 1` on the origin point picks the translation up.
        let direction4 = cameraTransform * dCam
        let direction = SIMD3<Double>(direction4.x, direction4.y, direction4.z)
        let origin4 = cameraTransform * SIMD4<Double>(0, 0, 0, 1)
        let origin = SIMD3<Double>(origin4.x, origin4.y, origin4.z)

        // 4. Intersect with the plane: anchor-local y = 0 ⇒ world normal is
        //    the plane transform's local +y column, world point-on-plane is
        //    the plane transform's translation.
        let normal4 = planeTransform * SIMD4<Double>(0, 1, 0, 0)
        let normal = SIMD3<Double>(normal4.x, normal4.y, normal4.z)
        let planeOrigin4 = planeTransform * SIMD4<Double>(0, 0, 0, 1)
        let planeOrigin = SIMD3<Double>(planeOrigin4.x, planeOrigin4.y, planeOrigin4.z)

        let denom = simd_dot(direction, normal)
        guard abs(denom) > 1e-9 else { return nil }   // ray parallel to the plane
        let t = simd_dot(planeOrigin - origin, normal) / denom
        guard t > 1e-9 else { return nil }   // plane is behind the camera along this ray

        let worldHit = origin + t * direction

        // 5. World → anchor-local; (x, z) is the table point (y ≈ 0 by
        //    construction — the ray was solved to land exactly on the plane).
        let local4 = simd_inverse(planeTransform) * SIMD4<Double>(worldHit.x, worldHit.y, worldHit.z, 1)
        return SIMD2<Double>(local4.x, local4.z)
    }

    // MARK: - Oriented-normalized + depth → world

    /// Unprojects a detector point using a measured camera-axis depth.
    /// `depthMeters` is the positive `-Z` distance used by ARKit scene depth,
    /// not Euclidean distance along the oblique ray.
    public func worldPoint(ofNormalizedOrientedPoint p: SIMD2<Double>,
                           orientedImageSize: SIMD2<Double>,
                           depthMeters: Double) -> SIMD3<Double>? {
        worldPoint(
            ofNormalizedOrientedPoint: p,
            imageTransform: legacyRightTransform,
            depthMeters: depthMeters
        )
    }

    public func worldPoint(
        ofNormalizedOrientedPoint p: SIMD2<Double>,
        imageTransform: FrameImageTransform,
        depthMeters: Double
    ) -> SIMD3<Double>? {
        guard depthMeters.isFinite, depthMeters > 0,
              let rawPixel = rawPixel(
                fromOrientedNormalized: p,
                imageTransform: imageTransform
              ) else { return nil }

        let xr = rawPixel.x
        let yr = rawPixel.y
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        guard fx != 0, fy != 0 else { return nil }

        let cameraPoint = SIMD4<Double>(
            (xr - cx) / fx * depthMeters,
            -(yr - cy) / fy * depthMeters,
            -depthMeters,
            1
        )
        let world = cameraTransform * cameraPoint
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
        return SIMD3<Double>(world.x, world.y, world.z)
    }

    /// Projects an arbitrary world point into detector coordinates.
    public func normalizedOrientedPoint(ofWorldPoint worldPoint: SIMD3<Double>,
                                        orientedImageSize: SIMD2<Double>) -> SIMD2<Double>? {
        normalizedOrientedPoint(
            ofWorldPoint: worldPoint,
            imageTransform: legacyRightTransform
        )
    }

    public func normalizedOrientedPoint(
        ofWorldPoint worldPoint: SIMD3<Double>,
        imageTransform: FrameImageTransform
    ) -> SIMD2<Double>? {
        guard imageResolution.x > 0, imageResolution.y > 0 else { return nil }
        let cameraLocal = simd_inverse(cameraTransform)
            * SIMD4<Double>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
        guard cameraLocal.z < -1e-9 else { return nil }
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        let depth = -cameraLocal.z
        let xr = fx * (cameraLocal.x / depth) + cx
        let yr = fy * (-cameraLocal.y / depth) + cy
        return imageTransform.orientedNormalized(
            fromRaw: SIMD2(
                xr / imageResolution.x,
                yr / imageResolution.y
            )
        )
    }

    /// Positive scene-depth value expected for a world point in this frame.
    public func cameraAxisDepth(ofWorldPoint worldPoint: SIMD3<Double>) -> Double? {
        let cameraLocal = simd_inverse(cameraTransform)
            * SIMD4<Double>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
        let depth = -cameraLocal.z
        return depth.isFinite && depth > 1e-9 ? depth : nil
    }

    // MARK: - Table (anchor-local x, z) → oriented-normalized

    /// The exact inverse of `tablePoint(ofNormalizedOrientedPoint:orientedImageSize:)`:
    /// anchor-local `(x, z)` (packed as `SIMD2(x: local x, y: local z)`) →
    /// world → camera → captured pixel → oriented-normalized.
    ///
    /// Returns `nil` when the table point is behind the camera (not
    /// projectable into this frame at all).
    public func normalizedOrientedPoint(ofTablePoint t: SIMD2<Double>,
                                        orientedImageSize: SIMD2<Double>) -> SIMD2<Double>? {
        normalizedOrientedPoint(
            ofTablePoint: t,
            imageTransform: legacyRightTransform
        )
    }

    public func normalizedOrientedPoint(
        ofTablePoint t: SIMD2<Double>,
        imageTransform: FrameImageTransform
    ) -> SIMD2<Double>? {
        let worldPoint4 = planeTransform * SIMD4<Double>(t.x, 0, t.y, 1)
        return normalizedOrientedPoint(
            ofWorldPoint: SIMD3<Double>(worldPoint4.x, worldPoint4.y, worldPoint4.z),
            imageTransform: imageTransform
        )
    }

    private var legacyRightTransform: FrameImageTransform {
        FrameImageTransform(
            imageOrientation: .right,
            imageResolution: CGSize(
                width: imageResolution.x,
                height: imageResolution.y
            )
        )
    }

    private func rawPixel(
        fromOrientedNormalized point: SIMD2<Double>,
        imageTransform: FrameImageTransform
    ) -> SIMD2<Double>? {
        guard imageResolution.x > 0, imageResolution.y > 0,
              imageTransform.orientedImageSize.width > 0,
              imageTransform.orientedImageSize.height > 0,
              point.x.isFinite, point.y.isFinite else { return nil }
        let raw = imageTransform.rawNormalized(fromOriented: point)
        return SIMD2(
            raw.x * imageResolution.x,
            raw.y * imageResolution.y
        )
    }
}

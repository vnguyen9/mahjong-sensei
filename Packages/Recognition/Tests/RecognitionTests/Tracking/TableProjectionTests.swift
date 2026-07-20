import XCTest
import ImageIO
import simd
@testable import Recognition

/// Lane B chunk A coverage: `TableProjection` (pixel-ray ↔ table-plane
/// projection math) and `DetectionProjector` (wiring detections through it
/// into synthetic table-space `DetectedTile`s). All matrices are synthetic —
/// no ARKit dependency, fully CI-testable.
///
/// Every camera pose below is built from an explicit, hand-verified
/// orthonormal basis (`ARCamera.transform` convention: columns 0/1/2 are the
/// camera's local X/Y/Z axes *in world space*, column 3 is its world
/// position) so the expected numbers in the "known position" tests can be
/// derived by hand and cross-checked against the implementation.
final class TableProjectionTests: XCTestCase {

    // MARK: - Test fixtures

    /// A camera looking straight down at a horizontal plane below it: local
    /// `+X` (right) → world `+X`, local `+Y` (up) → world `+Z`, local `+Z`
    /// (backward, i.e. `-forward`) → world `+Y`. Forward (`-Z_cam`) is then
    /// world `(0, -1, 0)` — straight down. Right-handedness check:
    /// `X × Y = (1,0,0) × (0,0,1) = (0,-1,0)`... — see `overheadCamera(at:)`
    /// for the verified basis actually used.
    private static func overheadCamera(at position: SIMD3<Double>) -> simd_double4x4 {
        // X_cam→world X, Y_cam→world Z, Z_cam→world Y. Right-handedness
        // (X × Y = Z, checked by hand): (1,0,0) × (0,0,1) = (0·1−0·0,
        // 0·0−1·1, 1·0−0·0) = (0,−1,0) ≠ (0,1,0) — so instead use
        // Y_cam = (0,0,−1): (1,0,0) × (0,0,−1) = (0·−1−0·0, 0·0−1·−1,
        // 1·0−0·0) = (0,1,0) = Z_cam ✓.
        var m = matrix_identity_double4x4
        m.columns.0 = SIMD4<Double>(1, 0, 0, 0)     // local X (right)  → world +X
        m.columns.1 = SIMD4<Double>(0, 0, -1, 0)    // local Y (up)     → world -Z
        m.columns.2 = SIMD4<Double>(0, 1, 0, 0)     // local Z (behind) → world +Y
        m.columns.3 = SIMD4<Double>(position.x, position.y, position.z, 1)
        return m
    }

    /// A camera looking horizontally (forward = world `+X`), level (up =
    /// world `+Y`). Used to exercise "ray parallel to the plane" (the
    /// exact-center pixel looks dead level) and "ray meets the plane only
    /// for pixels tilted downward" cases. Right-handedness: `X_cam × Y_cam
    /// = (0,0,1) × (0,1,0) = (0·0−1·1, 1·0−0·0, 0·1−0·0) = (−1,0,0) = Z_cam` ✓.
    private static func horizontalCamera(at position: SIMD3<Double>) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.0 = SIMD4<Double>(0, 0, 1, 0)     // local X (right)  → world +Z
        m.columns.1 = SIMD4<Double>(0, 1, 0, 0)     // local Y (up)     → world +Y
        m.columns.2 = SIMD4<Double>(-1, 0, 0, 0)    // local Z (behind) → world -X
        m.columns.3 = SIMD4<Double>(position.x, position.y, position.z, 1)
        return m
    }

    private static func plane(atHeight y: Double) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4<Double>(0, y, 0, 1)
        return m
    }

    private static let identityPlane = matrix_identity_double4x4

    private static func intrinsics(fx: Double = 1000, fy: Double = 1000,
                                   cx: Double = 500, cy: Double = 500) -> simd_double3x3 {
        simd_double3x3(SIMD3(fx, 0, 0), SIMD3(0, fy, 0), SIMD3(cx, cy, 1))
    }

    private static let squareResolution = SIMD2<Double>(1000, 1000)

    func testSameRawRayProducesSameTableAnchorInAllIPadOrientations() throws {
        let projection = TableProjection(
            cameraTransform: Self.overheadCamera(at: SIMD3(0, 1, 0)),
            intrinsics: Self.intrinsics(),
            imageResolution: Self.squareResolution,
            planeTransform: Self.identityPlane
        )
        let raw = SIMD2<Double>(0.61, 0.54)
        var anchors: [SIMD2<Double>] = []
        for orientation: CGImagePropertyOrientation in [.right, .left, .up, .down] {
            let transform = FrameImageTransform(
                imageOrientation: orientation,
                imageResolution: CGSize(width: 1000, height: 1000)
            )
            let oriented = transform.orientedNormalized(fromRaw: raw)
            anchors.append(try XCTUnwrap(projection.tablePoint(
                ofNormalizedOrientedPoint: oriented,
                imageTransform: transform
            )))
        }
        for anchor in anchors.dropFirst() {
            XCTAssertEqual(anchor.x, anchors[0].x, accuracy: 1e-9)
            XCTAssertEqual(anchor.y, anchors[0].y, accuracy: 1e-9)
        }
    }

    /// Rodrigues' rotation formula for a rotation of `angleRadians` about
    /// unit-normalized `axis`, written out by hand — used only to build
    /// synthetic tilted-camera poses for the round-trip test, so these
    /// tests don't depend on any quaternion API surface beyond simd's basic
    /// matrix/vector arithmetic (already exercised by the production code).
    private static func rotation(angleRadians: Double, axis: SIMD3<Double>) -> simd_double3x3 {
        let a = simd_normalize(axis)
        let c = cos(angleRadians), s = sin(angleRadians), t = 1 - c
        let x = a.x, y = a.y, z = a.z
        return simd_double3x3(
            SIMD3(t * x * x + c, t * x * y + s * z, t * x * z - s * y),
            SIMD3(t * x * y - s * z, t * y * y + c, t * y * z + s * x),
            SIMD3(t * x * z + s * y, t * y * z - s * x, t * z * z + c)
        )
    }

    private static func makeTransform(rotation: simd_double3x3, translation: SIMD3<Double>) -> simd_double4x4 {
        simd_double4x4(
            SIMD4<Double>(rotation[0].x, rotation[0].y, rotation[0].z, 0),
            SIMD4<Double>(rotation[1].x, rotation[1].y, rotation[1].z, 0),
            SIMD4<Double>(rotation[2].x, rotation[2].y, rotation[2].z, 0),
            SIMD4<Double>(translation.x, translation.y, translation.z, 1)
        )
    }

    // MARK: - 1. Overhead camera, hand-derived expectations

    func test_overheadCamera_imageCenter_projectsToAnchorOrigin() {
        let projection = TableProjection(
            cameraTransform: Self.overheadCamera(at: SIMD3(0, 1, 0)),
            intrinsics: Self.intrinsics(),
            imageResolution: Self.squareResolution,
            planeTransform: Self.identityPlane)

        // Center pixel (xr=cx, yr=cy) → dCam=(0,0,-1) → straight down →
        // hits the plane directly below the camera, i.e. the anchor origin.
        let result = projection.tablePoint(ofNormalizedOrientedPoint: SIMD2(0.5, 0.5),
                                           orientedImageSize: Self.squareResolution)
        let table = try! XCTUnwrap(result)
        XCTAssertEqual(table.x, 0, accuracy: 1e-9)
        XCTAssertEqual(table.y, 0, accuracy: 1e-9)
    }

    func test_overheadCamera_offsetPoint_projectsToExpectedTableX() {
        let projection = TableProjection(
            cameraTransform: Self.overheadCamera(at: SIMD3(0, 1, 0)),
            intrinsics: Self.intrinsics(),
            imageResolution: Self.squareResolution,
            planeTransform: Self.identityPlane)

        // Hand derivation (Wr=Hr=Wo=Ho=1000, fx=fy=1000, cx=cy=500):
        // p = (0.5, 0.6) → xr = p.y*Ho = 600, yr = Hr - p.x*Wo = 500 (=cy).
        // dCam = ((600-500)/1000, -(500-500)/1000, -1) = (0.1, 0, -1).
        // direction = col0*0.1 + col2*(-1) = (0.1,0,0) - (0,1,0) = (0.1,-1,0).
        // origin = (0,1,0); denom = dot(direction,(0,1,0)) = -1;
        // t = dot((0,-1,0),(0,1,0)) / -1 = 1 (in front of the camera).
        // worldHit = origin + 1*direction = (0.1, 0, 0) ⇒ table = (0.1, 0).
        let result = projection.tablePoint(ofNormalizedOrientedPoint: SIMD2(0.5, 0.6),
                                           orientedImageSize: Self.squareResolution)
        let table = try! XCTUnwrap(result)
        XCTAssertEqual(table.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(table.y, 0, accuracy: 1e-9)
    }

    // MARK: - 2. Round trip: tablePoint → normalizedOrientedPoint recovers the original

    func test_roundTrip_recoversOriginalPoint_acrossTiltedTranslatedPoses() {
        let baseRotation = simd_double3x3(
            SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)   // the overhead-camera basis
        )
        let poses: [(rotation: simd_double3x3, position: SIMD3<Double>)] = [
            (Self.rotation(angleRadians: .pi / 6, axis: SIMD3(1, 0, 0)) * baseRotation,
             SIMD3(0.3, 1.2, 0.1)),                                          // 30° tilt about X
            (Self.rotation(angleRadians: .pi / 4, axis: SIMD3(0, 0, 1)) * baseRotation,
             SIMD3(-0.2, 0.8, 0.4)),                                         // 45° tilt about Z
            (Self.rotation(angleRadians: .pi / 4, axis: SIMD3(1, 0, 0))
                * Self.rotation(angleRadians: .pi / 6, axis: SIMD3(0, 1, 0)) * baseRotation,
             SIMD3(0.5, 1.5, -0.3)),                                         // combined 45°+30° tilt
        ]
        // Realistic (non-square) landscape/portrait pair — the .right
        // rotation math must hold when Wr≠Hr, not just in the degenerate
        // square case the hand-derived tests above use.
        let imageResolution = SIMD2<Double>(1920, 1440)
        let orientedImageSize = SIMD2<Double>(1440, 1920)
        let intrinsics = Self.intrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720)
        let candidatePoints: [SIMD2<Double>] = [
            SIMD2(0.5, 0.5), SIMD2(0.4, 0.45), SIMD2(0.6, 0.55), SIMD2(0.45, 0.65),
        ]

        var checkedAtLeastOne = false
        for pose in poses {
            let projection = TableProjection(
                cameraTransform: Self.makeTransform(rotation: pose.rotation, translation: pose.position),
                intrinsics: intrinsics,
                imageResolution: imageResolution,
                planeTransform: Self.identityPlane)

            for original in candidatePoints {
                guard let table = projection.tablePoint(ofNormalizedOrientedPoint: original,
                                                         orientedImageSize: orientedImageSize) else {
                    continue   // this pose/point doesn't hit the plane in front of the camera; skip
                }
                guard let recovered = projection.normalizedOrientedPoint(ofTablePoint: table,
                                                                         orientedImageSize: orientedImageSize) else {
                    XCTFail("forward projection succeeded but the inverse returned nil for \(original) under pose \(pose.position)")
                    continue
                }
                XCTAssertEqual(recovered.x, original.x, accuracy: 1e-6)
                XCTAssertEqual(recovered.y, original.y, accuracy: 1e-6)
                checkedAtLeastOne = true
            }
        }
        XCTAssertTrue(checkedAtLeastOne, "no pose/point combination hit the plane — test fixtures need adjusting")
    }

    // MARK: - 3. Ray misses → nil

    func test_horizonPixel_underLevelCamera_isNil() {
        // Camera looking dead-level (forward = world +X): the exact-center
        // pixel's ray is exactly horizontal, i.e. parallel to the y=0 plane.
        let projection = TableProjection(
            cameraTransform: Self.horizontalCamera(at: SIMD3(0, 1, 0)),
            intrinsics: Self.intrinsics(),
            imageResolution: Self.squareResolution,
            planeTransform: Self.identityPlane)

        let result = projection.tablePoint(ofNormalizedOrientedPoint: SIMD2(0.5, 0.5),
                                           orientedImageSize: Self.squareResolution)
        XCTAssertNil(result)
    }

    func test_planeAboveCamera_isNil() {
        // Overhead camera at y=1 looking straight down, but the "table"
        // plane is at y=5 — straight down from y=1 never reaches y=5, so
        // the mathematical intersection lies behind the camera (t < 0).
        let projection = TableProjection(
            cameraTransform: Self.overheadCamera(at: SIMD3(0, 1, 0)),
            intrinsics: Self.intrinsics(),
            imageResolution: Self.squareResolution,
            planeTransform: Self.plane(atHeight: 5))

        let result = projection.tablePoint(ofNormalizedOrientedPoint: SIMD2(0.5, 0.5),
                                           orientedImageSize: Self.squareResolution)
        XCTAssertNil(result)
    }

    func test_tablePointBehindCamera_normalizedOrientedPointIsNil() {
        // A table point directly *behind* the overhead camera (camera at
        // y=1 looking down; a point at y=2, i.e. above the camera, world
        // z=0, x=0 sits behind the camera along its -Z-forward axis).
        let projection = TableProjection(
            cameraTransform: Self.overheadCamera(at: SIMD3(0, 1, 0)),
            intrinsics: Self.intrinsics(),
            imageResolution: Self.squareResolution,
            planeTransform: Self.identityPlane)

        // anchor-local (x=0, z=0) under a plane at y=2 is world (0,2,0) —
        // above and thus behind this downward-looking camera.
        let elevatedPlane = Self.plane(atHeight: 2)
        let projectionWithElevatedPlane = TableProjection(
            cameraTransform: projection.cameraTransform,
            intrinsics: projection.intrinsics,
            imageResolution: projection.imageResolution,
            planeTransform: elevatedPlane)
        let result = projectionWithElevatedPlane.normalizedOrientedPoint(ofTablePoint: SIMD2(0, 0),
                                                                          orientedImageSize: Self.squareResolution)
        XCTAssertNil(result)
    }

    // MARK: - 4. DetectionProjector

    func test_detectionProjector_knownPosition_dropsMisses_preservesCount() {
        // Level (horizontal-look) camera: the exact-center pixel misses
        // (parallel ray); pixels tilted downward hit. This lets one shared
        // projection produce both a hit and a miss in the same batch.
        let projection = TableProjection(
            cameraTransform: Self.horizontalCamera(at: SIMD3(0, 1, 0)),
            intrinsics: Self.intrinsics(),
            imageResolution: Self.squareResolution,
            planeTransform: Self.identityPlane)
        let orientedImageSize = Self.squareResolution
        let tableExtent = 8.0
        let tileSize = SIMD2<Double>(0.02, 0.02)

        // Miss: bottom-center = (0.5, 0.5), the exact image center (parallel
        // ray under the level camera, verified in test 3 above).
        let missTile = DetectedTile(tile: .p(1), confidence: 0.9,
                                    box: TileBoundingBox(x: 0.45, y: 0.4, width: 0.1, height: 0.1))

        // Hit 1: bottom-center = (0.0, 0.5). Hand derivation: dx=0 ⇒ xr=cx=500
        // ⇒ p.y = xr/Ho = 0.5. dCam.y=-0.5 ⇒ yr=cy+0.5*fy=1000 ⇒
        // p.x=(Hr-yr)/Wo=0. direction=(1,-0.5,0), t=2, worldHit=(2,0,0) ⇒
        // table=(2,0) ⇒ nx=2/8+0.5=0.75, nz=0.5 ⇒ box centered at
        // (0.75, 0.5) with w=h=0.02/8=0.0025.
        let hit1 = DetectedTile(tile: .p(2), confidence: 0.8,
                                box: TileBoundingBox(x: -0.05, y: 0.4, width: 0.1, height: 0.1))

        // Hit 2: bottom-center = (0.25, 0.5). Same derivation with dCam.y=-0.25
        // ⇒ yr=750 ⇒ p.x=0.25; direction=(1,-0.25,0), t=4,
        // worldHit=(4,0,0) ⇒ table=(4,0) ⇒ nx=4/8+0.5=1.0, nz=0.5.
        let hit2 = DetectedTile(tile: .p(3), confidence: 0.7,
                                box: TileBoundingBox(x: 0.2, y: 0.4, width: 0.1, height: 0.1))

        let result = DetectionProjector.projectToTableSpace(
            [hit1, missTile, hit2], projection: projection,
            orientedImageSize: orientedImageSize, tableExtent: tableExtent, tileSize: tileSize)

        XCTAssertEqual(result.count, 2, "the parallel-ray tile should be dropped, the two hits kept")
        XCTAssertFalse(result.contains { $0.id == missTile.id })

        let projectedHit1 = try! XCTUnwrap(result.first { $0.id == hit1.id })
        XCTAssertEqual(projectedHit1.tile, hit1.tile)
        XCTAssertEqual(projectedHit1.confidence, hit1.confidence)
        XCTAssertEqual(projectedHit1.box.x, 0.75 - 0.00125, accuracy: 1e-9)
        XCTAssertEqual(projectedHit1.box.y, 0.5 - 0.00125, accuracy: 1e-9)
        XCTAssertEqual(projectedHit1.box.width, 0.0025, accuracy: 1e-9)
        XCTAssertEqual(projectedHit1.box.height, 0.0025, accuracy: 1e-9)

        let projectedHit2 = try! XCTUnwrap(result.first { $0.id == hit2.id })
        XCTAssertEqual(projectedHit2.tile, hit2.tile)
        XCTAssertEqual(projectedHit2.confidence, hit2.confidence)
        XCTAssertEqual(projectedHit2.box.x, 1.0 - 0.00125, accuracy: 1e-9)
        XCTAssertEqual(projectedHit2.box.y, 0.5 - 0.00125, accuracy: 1e-9)

        // Count preserved when nothing misses.
        let onlyHits = DetectionProjector.projectToTableSpace(
            [hit1, hit2], projection: projection,
            orientedImageSize: orientedImageSize, tableExtent: tableExtent, tileSize: tileSize)
        XCTAssertEqual(onlyHits.count, 2)
    }

    // MARK: - 5. Determinism

    func test_tablePoint_isDeterministic() {
        let projection = TableProjection(
            cameraTransform: Self.overheadCamera(at: SIMD3(0.2, 1.3, -0.1)),
            intrinsics: Self.intrinsics(fx: 1100, fy: 1050, cx: 520, cy: 480),
            imageResolution: Self.squareResolution,
            planeTransform: Self.identityPlane)
        let p = SIMD2<Double>(0.42, 0.58)

        let a = projection.tablePoint(ofNormalizedOrientedPoint: p, orientedImageSize: Self.squareResolution)
        let b = projection.tablePoint(ofNormalizedOrientedPoint: p, orientedImageSize: Self.squareResolution)
        XCTAssertEqual(a, b)

        let table = try! XCTUnwrap(a)
        let back1 = projection.normalizedOrientedPoint(ofTablePoint: table, orientedImageSize: Self.squareResolution)
        let back2 = projection.normalizedOrientedPoint(ofTablePoint: table, orientedImageSize: Self.squareResolution)
        XCTAssertEqual(back1, back2)
    }

    func test_detectionProjector_isDeterministic() {
        let projection = TableProjection(
            cameraTransform: Self.overheadCamera(at: SIMD3(0, 1, 0)),
            intrinsics: Self.intrinsics(),
            imageResolution: Self.squareResolution,
            planeTransform: Self.identityPlane)
        let tiles = [
            DetectedTile(tile: .p(4), confidence: 0.9,
                        box: TileBoundingBox(x: 0.4, y: 0.5, width: 0.1, height: 0.15)),
            DetectedTile(tile: .p(5), confidence: 0.6,
                        box: TileBoundingBox(x: 0.2, y: 0.3, width: 0.1, height: 0.1)),
        ]

        let a = DetectionProjector.projectToTableSpace(tiles, projection: projection,
                                                        orientedImageSize: Self.squareResolution,
                                                        tableExtent: 0.9, tileSize: SIMD2(0.024, 0.032))
        let b = DetectionProjector.projectToTableSpace(tiles, projection: projection,
                                                        orientedImageSize: Self.squareResolution,
                                                        tableExtent: 0.9, tileSize: SIMD2(0.024, 0.032))
        XCTAssertEqual(a, b)
    }
}

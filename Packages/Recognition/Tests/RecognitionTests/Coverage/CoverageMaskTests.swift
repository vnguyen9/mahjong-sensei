import XCTest
import simd
@testable import Recognition

/// Chunk A coverage tests (§5.2): coverage is a *set* of independent
/// polygons, never a bounding-box union — a gap between two observed crops
/// must stay unobserved.
final class CoverageMaskTests: XCTestCase {

    private static func quality() -> FrameQuality {
        FrameQuality(trackingIsNormal: true, sharpness: 1, exposureScore: 1,
                     clippingFraction: 0, projectedPixelsPerTile: 100,
                     coverageFraction: 1, accepted: true)
    }

    private func polygon(_ zoneID: SemanticZoneID, _ vertices: [SIMD2<Float>]) -> ObservedPolygon {
        ObservedPolygon(zoneID: zoneID, vertices: vertices, frameID: FrameID(0),
                        observedAt: 0, quality: Self.quality())
    }

    // MARK: - Two disjoint polygons keep a gap

    func testTwoDisjointPolygonsDoNotBridgeTheGap() {
        let left = polygon(.tablePond, [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
        ])
        let right = polygon(.tablePond, [
            SIMD2(3, 0), SIMD2(4, 0), SIMD2(4, 1), SIMD2(3, 1),
        ])
        let mask = CoverageMask(regions: [left, right])

        XCTAssertTrue(mask.covers(SIMD2(0.5, 0.5)), "inside the left crop")
        XCTAssertTrue(mask.covers(SIMD2(3.5, 0.5)), "inside the right crop")
        XCTAssertFalse(mask.covers(SIMD2(2.0, 0.5)), "the gap between the two crops must not be covered")
        XCTAssertEqual(mask.regionsCovering(SIMD2(2.0, 0.5)).count, 0)
        XCTAssertEqual(mask.regionsCovering(SIMD2(0.5, 0.5)).count, 1)
    }

    func testEmptyMaskCoversNothing() {
        XCTAssertFalse(CoverageMask().covers(SIMD2(0, 0)))
    }

    // MARK: - Point-in-polygon on a convex quad

    func testPointInPolygonAxisAlignedRectangle() {
        let quad = polygon(.mineHand, [
            SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 2), SIMD2(0, 2),
        ])
        XCTAssertTrue(quad.contains(SIMD2(2, 1)), "center")
        XCTAssertTrue(quad.contains(SIMD2(0.001, 1)), "just inside the left edge")
        XCTAssertFalse(quad.contains(SIMD2(-0.001, 1)), "just outside the left edge")
        XCTAssertFalse(quad.contains(SIMD2(5, 1)), "well outside, to the right")
        XCTAssertFalse(quad.contains(SIMD2(2, -1)), "well outside, below")
        XCTAssertFalse(quad.contains(SIMD2(2, 3)), "well outside, above")
    }

    func testPointInPolygonSlantedTrapezoid() {
        // A(0,0) B(4,0) C(3,2) D(1,2): right edge slants x = 4 - 0.5y (x=3.5 at
        // y=1); left edge slants x = 0.5y (x=0.5 at y=1).
        let quad = polygon(.tableRevealedFar, [
            SIMD2(0, 0), SIMD2(4, 0), SIMD2(3, 2), SIMD2(1, 2),
        ])
        XCTAssertTrue(quad.contains(SIMD2(2, 1)), "center")
        XCTAssertTrue(quad.contains(SIMD2(3.4, 1)), "just inside the slanted right edge")
        XCTAssertFalse(quad.contains(SIMD2(3.6, 1)), "just outside the slanted right edge")
        XCTAssertTrue(quad.contains(SIMD2(0.7, 1)), "just inside the slanted left edge")
        XCTAssertFalse(quad.contains(SIMD2(0.3, 1)), "just outside the slanted left edge")
    }

    func testDegeneratePolygonContainsNothing() {
        let line = polygon(.boundaryUnresolved, [SIMD2(0, 0), SIMD2(1, 0)])
        XCTAssertFalse(line.contains(SIMD2(0.5, 0)))
    }
}

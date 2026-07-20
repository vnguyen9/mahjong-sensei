import XCTest
import simd
@testable import Recognition

final class TableCalibrationGeometryTests: XCTestCase {

    func testDefaultsWhenNoMarks() {
        let g = TableCalibrationGeometry.geometry(extentMetres: 0, handBandInnerEdge: nil, pondEdge: nil)
        let d = TrackerConfig.TableGeometry()
        XCTAssertEqual(g.extent, d.extent, accuracy: 1e-9)
        XCTAssertEqual(g.handBandDepth, d.handBandDepth, accuracy: 1e-9)
        XCTAssertEqual(g.pondRadius, d.pondRadius, accuracy: 1e-9)
    }

    func testHandBandDepthFromInnerEdge() {
        // extent 1.0 → user edge at z = +0.5. An inner-edge mark at z = 0.35
        // is 0.15 m inward → handBandDepth = 0.15 fraction of extent.
        let g = TableCalibrationGeometry.geometry(extentMetres: 1.0,
                                                  handBandInnerEdge: SIMD2(0.0, 0.35),
                                                  pondEdge: nil)
        XCTAssertEqual(g.extent, 1.0, accuracy: 1e-9)
        XCTAssertEqual(g.handBandDepth, 0.15, accuracy: 1e-9)
    }

    func testPondRadiusFromEdge() {
        // extent 1.0 → a pond-rim mark 0.3 m from centre gives radius 0.3.
        let g = TableCalibrationGeometry.geometry(extentMetres: 1.0,
                                                  handBandInnerEdge: nil,
                                                  pondEdge: SIMD2(0.3, 0.0))
        XCTAssertEqual(g.pondRadius, 0.3, accuracy: 1e-9)
        // Off-axis rim mark: hypot(0.18, 0.24) = 0.30.
        let g2 = TableCalibrationGeometry.geometry(extentMetres: 1.0,
                                                   handBandInnerEdge: nil,
                                                   pondEdge: SIMD2(0.18, 0.24))
        XCTAssertEqual(g2.pondRadius, 0.30, accuracy: 1e-9)
    }

    func testPondRectFromTwoCorners() {
        // extent 1.0 → local metres map as n = local + 0.5. Two opposite
        // corners at local (0.1, 0.05) and (-0.1, -0.15) → an off-centre rect
        // spanning normalized x[0.4,0.6], y[0.35,0.55].
        let g = TableCalibrationGeometry.geometry(
            extentMetres: 1.0,
            handPostA: nil, handPostB: nil,
            pondCornerA: SIMD2(0.1, 0.05), pondCornerB: SIMD2(-0.1, -0.15))
        guard case let .rect(mn, mx) = g.pond else { return XCTFail("expected a rect pond") }
        XCTAssertEqual(mn.x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(mx.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(mn.y, 0.35, accuracy: 1e-9)
        XCTAssertEqual(mx.y, 0.55, accuracy: 1e-9)
        // Membership: a point inside the rect is pond; one just outside isn't.
        XCTAssertTrue(g.pond.contains(SIMD2(0.5, 0.45)))
        XCTAssertFalse(g.pond.contains(SIMD2(0.5, 0.7)))
    }

    func testPondRectEnforcesMinimumSize() {
        // A near-zero drag collapses to a point; the producer floors the box to
        // a sane footprint around its centre instead of a degenerate line.
        let g = TableCalibrationGeometry.geometry(
            extentMetres: 1.0,
            handPostA: nil, handPostB: nil,
            pondCornerA: SIMD2(0.0, 0.0), pondCornerB: SIMD2(0.001, 0.001))
        guard case let .rect(mn, mx) = g.pond else { return XCTFail("expected a rect pond") }
        XCTAssertGreaterThanOrEqual(mx.x - mn.x, 0.2 - 1e-9)
        XCTAssertGreaterThanOrEqual(mx.y - mn.y, 0.2 - 1e-9)
    }

    func testPondQuadOverridesRectAndContains() {
        // A refined quad (4 local corners) overrides the 2-corner rect and
        // yields a `.quad` whose containment respects the rotated shape.
        let quad = [SIMD2(-0.1, -0.1), SIMD2(0.1, -0.05), SIMD2(0.12, 0.12), SIMD2(-0.08, 0.1)]
        let g = TableCalibrationGeometry.geometry(
            extentMetres: 1.0,
            handPostA: nil, handPostB: nil,
            pondCornerA: SIMD2(0.0, 0.0), pondCornerB: SIMD2(0.02, 0.02),
            pondQuad: quad)
        guard case let .quad(corners) = g.pond else { return XCTFail("expected a quad pond") }
        XCTAssertEqual(corners.count, 4)
        // The quad centre (≈0.5,0.5 normalized) is inside; a far point isn't.
        XCTAssertTrue(g.pond.contains(g.pond.center))
        XCTAssertFalse(g.pond.contains(SIMD2(0.95, 0.95)))
    }

    func testSinglePondCornerStaysDisk() {
        // Only one corner given → legacy centred disk (radius = its distance
        // from centre), so old single-mark calibrations still behave.
        let g = TableCalibrationGeometry.geometry(
            extentMetres: 1.0,
            handPostA: nil, handPostB: nil,
            pondCornerA: SIMD2(0.3, 0.0), pondCornerB: nil)
        guard case let .disk(center, radius) = g.pond else { return XCTFail("expected a disk pond") }
        XCTAssertEqual(center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(radius, 0.3, accuracy: 1e-9)
    }

    func testExtentClampedToTableRange() {
        let tiny = TableCalibrationGeometry.geometry(extentMetres: 0.05, handBandInnerEdge: nil, pondEdge: nil)
        XCTAssertEqual(tiny.extent, TableCalibrationGeometry.extentRange.lowerBound, accuracy: 1e-9)
        let huge = TableCalibrationGeometry.geometry(extentMetres: 5.0, handBandInnerEdge: nil, pondEdge: nil)
        XCTAssertEqual(huge.extent, TableCalibrationGeometry.extentRange.upperBound, accuracy: 1e-9)
    }

    func testSeatMidpointRepositionsMeldBand() {
        // extent 1.0, .left dragged to local (-0.1, 0.0) → normalized (0.4, 0.5).
        let g = TableCalibrationGeometry.geometry(
            extentMetres: 1.0,
            handPostA: nil, handPostB: nil,
            pondCornerA: nil, pondCornerB: nil,
            seatMidpoints: [.left: SIMD2(-0.1, 0.0)])
        guard let band = g.meldBands[.left] else { return XCTFail("expected a repositioned .left meld band") }
        // The band's own centre (near the dragged midpoint) must be inside it.
        XCTAssertTrue(band.contains(band.center))
        guard let seat = g.seats.first(where: { $0.seat == .left }) else { return XCTFail("expected a .left seat slot") }
        XCTAssertEqual(seat.edgeMidpoint.x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(seat.edgeMidpoint.y, 0.5, accuracy: 1e-9)
    }

    func testDepthAndRadiusClampedToSaneBounds() {
        // A mark essentially at the user edge → ~zero depth → clamps up.
        let shallow = TableCalibrationGeometry.geometry(extentMetres: 1.0,
                                                        handBandInnerEdge: SIMD2(0.0, 0.49),
                                                        pondEdge: SIMD2(2.0, 0.0))
        XCTAssertEqual(shallow.handBandDepth, TableCalibrationGeometry.handBandDepthRange.lowerBound, accuracy: 1e-9)
        // A pond mark way past the rim clamps to the max fraction.
        XCTAssertEqual(shallow.pondRadius, TableCalibrationGeometry.pondRadiusRange.upperBound, accuracy: 1e-9)
    }

    func testAutoPartitionIsWholeTableWithCentralPond() {
        // No marks: a gapless whole-table partition generated purely in
        // normalized space (central pond rect [0.28, 0.72]² + player regions).
        let g = TableCalibrationGeometry.autoPartition(extentMetres: 1.0, mySeatWind: .south)
        XCTAssertEqual(g.layout, .partition)
        XCTAssertEqual(g.extent, 1.0, accuracy: 1e-9)
        guard case let .rect(mn, mx) = g.pond else { return XCTFail("expected a rect pond") }
        XCTAssertEqual(mn.x, 0.28, accuracy: 1e-9)
        XCTAssertEqual(mn.y, 0.28, accuracy: 1e-9)
        XCTAssertEqual(mx.x, 0.72, accuracy: 1e-9)
        XCTAssertEqual(mx.y, 0.72, accuracy: 1e-9)
        XCTAssertTrue(g.pond.contains(SIMD2(0.5, 0.5)))
        XCTAssertFalse(g.pond.contains(SIMD2(0.1, 0.5)))
        // Seats + the three opponent meld bands exist (used by the overlay).
        XCTAssertEqual(g.seats.count, 4)
        XCTAssertNotNil(g.meldBands[.left])
        XCTAssertNotNil(g.meldBands[.right])
        XCTAssertNotNil(g.meldBands[.across])
        // The bottom "you" band and the opponent bands reach in to meet the
        // pond (depth = 0.5 − half-size = 0.28), closing the old moat.
        XCTAssertEqual(g.handBand.depth, 0.28, accuracy: 1e-9)
    }

    func testAutoPartitionClampsPondHalfSizes() {
        // A wildly large half-size is clamped so the pond never swallows an edge.
        let g = TableCalibrationGeometry.autoPartition(extentMetres: 1.0, mySeatWind: .east,
                                                       pondHalfWidth: 0.9, pondHalfDepth: 0.9)
        guard case let .rect(mn, mx) = g.pond else { return XCTFail("expected a rect pond") }
        XCTAssertEqual(mx.x - mn.x, 0.80, accuracy: 1e-9)   // 2 × 0.40 clamp
        XCTAssertEqual(mx.y - mn.y, 0.80, accuracy: 1e-9)
    }
}

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

    func testExtentClampedToTableRange() {
        let tiny = TableCalibrationGeometry.geometry(extentMetres: 0.05, handBandInnerEdge: nil, pondEdge: nil)
        XCTAssertEqual(tiny.extent, TableCalibrationGeometry.extentRange.lowerBound, accuracy: 1e-9)
        let huge = TableCalibrationGeometry.geometry(extentMetres: 5.0, handBandInnerEdge: nil, pondEdge: nil)
        XCTAssertEqual(huge.extent, TableCalibrationGeometry.extentRange.upperBound, accuracy: 1e-9)
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
}

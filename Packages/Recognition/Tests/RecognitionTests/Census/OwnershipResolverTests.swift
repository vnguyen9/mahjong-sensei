import XCTest
import simd
@testable import Recognition

/// Chunk B ownership tests (§10.1): a pure function of (position, calibrated
/// zone geometry) — no `TileFace` parameter exists on `OwnershipResolver` at
/// all, so "face identity never decides ownership" is enforced structurally,
/// not just by convention. These tests cover the geometric routing itself.
final class OwnershipResolverTests: XCTestCase {

    private let mineHand: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(2, 0), SIMD2(2, 2), SIMD2(0, 2)]
    private let tablePond: [SIMD2<Float>] = [SIMD2(5, 0), SIMD2(7, 0), SIMD2(7, 2), SIMD2(5, 2)]
    private let ignoredWall: [SIMD2<Float>] = [SIMD2(10, 0), SIMD2(12, 0), SIMD2(12, 2), SIMD2(10, 2)]

    private var zones: [SemanticZoneID: [SIMD2<Float>]] {
        [.mineHand: mineHand, .tablePond: tablePond, .ignoredWall: ignoredWall]
    }

    func testCenterInsideMineHandIsMine() {
        let bucket = OwnershipResolver.resolve(center: SIMD2(1, 1), footprintRadius: 0, zones: zones)
        XCTAssertEqual(bucket, .mine)
    }

    func testCenterInsidePondIsTable() {
        let bucket = OwnershipResolver.resolve(center: SIMD2(6, 1), footprintRadius: 0, zones: zones)
        XCTAssertEqual(bucket, .table)
    }

    func testCenterInsideWallIsIgnored() {
        let bucket = OwnershipResolver.resolve(center: SIMD2(11, 1), footprintRadius: 0, zones: zones)
        XCTAssertEqual(bucket, .ignored)
    }

    func testCenterOutsideEveryZoneIsUnresolved() {
        let bucket = OwnershipResolver.resolve(center: SIMD2(50, 50), footprintRadius: 0, zones: zones)
        XCTAssertEqual(bucket, .unresolved)
    }

    func testFootprintStraddlingTwoDifferentBucketZonesIsUnresolved() {
        // Center sits exactly on the mineHand/tablePond gap; a wide-enough
        // footprint radius pokes a sample point into tablePond.
        let bucket = OwnershipResolver.resolve(center: SIMD2(3.5, 1), footprintRadius: 2.0, zones: zones)
        XCTAssertEqual(bucket, .unresolved, "a footprint that reaches into a different-bucket zone must not be guessed")
    }

    func testSmallFootprintFullyInsideOneZoneStaysResolved() {
        let bucket = OwnershipResolver.resolve(center: SIMD2(1, 1), footprintRadius: 0.05, zones: zones)
        XCTAssertEqual(bucket, .mine, "a small footprint entirely inside one zone is not a boundary case")
    }
}

import XCTest
@testable import Recognition
import MahjongCore

final class CensusGameplayInventoryTests: XCTestCase {
    func testProjectsEveryHeldLifecycleIntoItsGameplayGroup() {
        let snapshot = CensusSnapshot(generatedAt: 1, tracks: [
            track(1, .confirmed, .tablePond, .m(1)),
            track(2, .stale, .tableRevealedLeft, .m(1)),
            track(3, .temporarilyMissing, .mineHand, .p(2)),
            track(4, .confirmed, .mineMeld, .p(2)),
            track(5, .confirmed, .boundaryUnresolved, .s(3)),
        ])

        let inventory = CensusGameplayInventory(snapshot: snapshot)

        XCTAssertEqual(inventory.tableCount(for: .m(1)), 2)
        XCTAssertEqual(inventory.yoursCount(for: .p(2)), 2)
        XCTAssertEqual(inventory.unassignedCount(for: .s(3)), 1)
        XCTAssertEqual(inventory.resolvedCount(for: .m(1)), 2)
        XCTAssertEqual(inventory.liveCount(for: .m(1)), 2)
    }

    func testExcludesTentativeRetiredAndIgnoredTracksAndDisclosesUnknownFaces() {
        let snapshot = CensusSnapshot(generatedAt: 1, tracks: [
            track(1, .tentative, .tablePond, .m(1)),
            track(2, .retired, .mineHand, .p(2)),
            track(3, .confirmed, .ignoredWall, .s(3)),
            track(4, .confirmed, .ignoredWall, nil),
            track(5, .confirmed, .mineHand, nil),
            track(6, .stale, .tablePond, nil),
            track(7, .temporarilyMissing, .boundaryUnresolved, nil),
        ])

        let inventory = CensusGameplayInventory(snapshot: snapshot)

        XCTAssertTrue(inventory.resolvedCounts.isEmpty)
        XCTAssertEqual(inventory.unknownFaceTrackCount, 3)
    }

    func testBonusTilesHaveOnePhysicalCopy() {
        let snapshot = CensusSnapshot(generatedAt: 1, tracks: [
            track(1, .confirmed, .mineHand, .flower(.plum)),
            track(2, .confirmed, .tablePond, .east),
        ])

        let inventory = CensusGameplayInventory(snapshot: snapshot)

        XCTAssertEqual(inventory.liveCount(for: .flower(.plum)), 0)
        XCTAssertEqual(inventory.liveCount(for: .flower(.orchid)), 1)
        XCTAssertEqual(inventory.liveCount(for: .east), 3)
    }

    func testEverySemanticZoneMapsToItsDeclaredInventoryGroup() {
        let snapshot = CensusSnapshot(generatedAt: 1, tracks: [
            track(1, .confirmed, .tablePond, .m(1)),
            track(2, .confirmed, .tableRevealedLeft, .m(1)),
            track(3, .confirmed, .tableRevealedFar, .m(1)),
            track(4, .confirmed, .tableRevealedRight, .m(1)),
            track(5, .confirmed, .mineHand, .p(2)),
            track(6, .confirmed, .mineMeld, .p(2)),
            track(7, .confirmed, .boundaryUnresolved, .s(3)),
            track(8, .confirmed, .ignoredWall, .east),
        ])

        let inventory = CensusGameplayInventory(snapshot: snapshot)

        XCTAssertEqual(inventory.tableCount(for: .m(1)), 4)
        XCTAssertEqual(inventory.yoursCount(for: .p(2)), 2)
        XCTAssertEqual(inventory.unassignedCount(for: .s(3)), 1)
        XCTAssertEqual(inventory.resolvedCount(for: .east), 0)
    }

    func testDraftReplacesFaceAndZoneWithoutDoubleCountingOrMutation() {
        let sourceTrack = track(1, .confirmed, .tablePond, .m(1))
        let snapshot = CensusSnapshot(generatedAt: 1, tracks: [
            sourceTrack,
            track(2, .confirmed, .mineHand, .p(2)),
        ])
        let draft = CensusTrackCorrectionDraft(
            trackID: CensusTrackID(1),
            face: .s(3),
            semanticZone: .mineMeld
        )

        let preview = CensusGameplayInventory(snapshot: snapshot, applying: draft)

        XCTAssertEqual(preview.tableCount(for: .m(1)), 0)
        XCTAssertEqual(preview.yoursCount(for: .s(3)), 1)
        XCTAssertEqual(preview.yoursCount(for: .p(2)), 1)
        XCTAssertEqual(preview.resolvedCounts.values.reduce(0, +), 2)
        XCTAssertEqual(snapshot.tracks.first, sourceTrack)
    }

    func testDraftCanChangeOnlyRegionOrMakeFaceUnknown() {
        let snapshot = CensusSnapshot(generatedAt: 1, tracks: [
            track(1, .confirmed, .tablePond, .m(1)),
        ])

        let moved = CensusGameplayInventory(
            snapshot: snapshot,
            applying: CensusTrackCorrectionDraft(
                trackID: CensusTrackID(1),
                face: .m(1),
                semanticZone: .boundaryUnresolved
            )
        )
        let unresolved = CensusGameplayInventory(
            snapshot: snapshot,
            applying: CensusTrackCorrectionDraft(
                trackID: CensusTrackID(1),
                face: nil,
                semanticZone: .mineHand
            )
        )

        XCTAssertEqual(moved.tableCount(for: .m(1)), 0)
        XCTAssertEqual(moved.unassignedCount(for: .m(1)), 1)
        XCTAssertEqual(unresolved.unknownFaceTrackCount, 1)
        XCTAssertTrue(unresolved.resolvedCounts.isEmpty)
    }

    private func track(
        _ id: Int,
        _ lifecycle: TrackLifecycleState,
        _ zone: SemanticZoneID,
        _ tile: Tile?
    ) -> CensusTrackSnapshot {
        CensusTrackSnapshot(
            id: CensusTrackID(id),
            worldPosition: SIMD3(Float(id), 0, 0),
            tablePoint: SIMD2(Float(id), 0),
            face: tile.map(TileFace.tile),
            faceConfidence: tile == nil ? 0 : 0.9,
            semanticZone: zone,
            lifecycle: lifecycle,
            firstSeen: 0,
            lastSeen: 1
        )
    }
}

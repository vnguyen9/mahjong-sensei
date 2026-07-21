import XCTest
@testable import Recognition

final class CensusPhysicalPresentationTests: XCTestCase {
    func testUnknownFacesRemainInPhysicalTotalsButAreSeparatelyPresented() {
        let snapshot = CensusSnapshot(generatedAt: 1, tracks: [
            track(id: 2, zone: .mineHand, lifecycle: .temporarilyMissing, face: nil),
            track(id: 1, zone: .mineHand, lifecycle: .confirmed, face: .tile(.s(1))),
            track(id: 3, zone: .tablePond, lifecycle: .stale, face: nil),
        ])

        let result = CensusPhysicalPresentation.make(snapshot: snapshot)

        XCTAssertEqual(result.zoneCounts[.mineHand], 2)
        XCTAssertEqual(result.zoneCounts[.tablePond], 1)
        XCTAssertEqual(result.unknownTracks.map(\.id.raw), [2, 3])
    }

    func testTentativeRetiredAndWallsNeverEnterDisplayedPhysicalCounts() {
        let snapshot = CensusSnapshot(generatedAt: 1, tracks: [
            track(id: 1, zone: .tablePond, lifecycle: .tentative, face: nil),
            track(id: 2, zone: .tablePond, lifecycle: .retired, face: nil),
            track(id: 3, zone: .ignoredWall, lifecycle: .confirmed, face: nil),
            track(id: 4, zone: .boundaryUnresolved, lifecycle: .confirmed, face: nil),
        ])

        let result = CensusPhysicalPresentation.make(snapshot: snapshot)

        XCTAssertEqual(result.zoneCounts, [.boundaryUnresolved: 1])
        XCTAssertEqual(result.unknownTracks.map(\.id.raw), [4])
    }

    private func track(
        id: Int,
        zone: SemanticZoneID,
        lifecycle: TrackLifecycleState,
        face: TileFace?
    ) -> CensusTrackSnapshot {
        CensusTrackSnapshot(
            id: CensusTrackID(id),
            worldPosition: SIMD3(Float(id), 0, 0),
            tablePoint: SIMD2(Float(id), 0),
            face: face,
            faceConfidence: face == nil ? 0 : 0.9,
            semanticZone: zone,
            lifecycle: lifecycle,
            firstSeen: 0,
            lastSeen: 1
        )
    }
}

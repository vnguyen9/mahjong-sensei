import XCTest
@testable import Recognition
import MahjongCore

final class CensusEventAdapterTests: XCTestCase {
    func testAdapterIncludesHeldTracksAndExcludesTentativeAndRetired() {
        let tracks = [
            track(0, .confirmed, .m(1), SIMD2(-0.12, 0.30)),
            track(1, .stale, .p(2), SIMD2(0.02, 0.00)),
            track(2, .temporarilyMissing, .s(3), SIMD2(0.15, -0.20)),
            track(3, .tentative, .east, SIMD2.zero),
            track(4, .retired, .south, SIMD2.zero),
        ]
        let snapshot = CensusSnapshot(generatedAt: 4, tracks: tracks)

        let eventTracks = CensusEventAdapter.tracks(
            from: snapshot,
            tableExtent: SIMD2(0.80, 1.00)
        )

        XCTAssertEqual(eventTracks.map(\.face), [.s(3), .p(2), .m(1)])
        XCTAssertEqual(Set(eventTracks.map(\.id)).count, 3)
    }

    func testAdapterIsDeterministicAndPreservesRectangularAxes() {
        let snapshot = CensusSnapshot(
            generatedAt: 1,
            tracks: [track(7, .confirmed, .m(9), SIMD2(0.20, -0.25))]
        )

        let first = CensusEventAdapter.tracks(
            from: snapshot,
            tableExtent: SIMD2(0.80, 1.00)
        )
        let second = CensusEventAdapter.tracks(
            from: snapshot,
            tableExtent: SIMD2(0.80, 1.00)
        )

        XCTAssertEqual(first, second)
        let detection = try? XCTUnwrap(first.first)
        XCTAssertEqual(detection?.box.centerX ?? 0, 0.75, accuracy: 1e-6)
        XCTAssertEqual(detection?.box.centerY ?? 0, 0.25, accuracy: 1e-6)
        XCTAssertEqual(detection?.box.width ?? 0, 0.03, accuracy: 1e-6)
        XCTAssertEqual(detection?.box.height ?? 0, 0.032, accuracy: 1e-6)
    }

    func testAdapterUsesMeasuredTileDimensionsForEventGeometry() throws {
        let snapshot = CensusSnapshot(
            generatedAt: 1,
            tracks: [track(8, .confirmed, .p(5), .zero)]
        )
        let dimensions = PhysicalTileDimensions(
            width: 0.030,
            length: 0.040,
            height: 0.018
        )

        let eventTrack = try XCTUnwrap(CensusEventAdapter.tracks(
            from: snapshot,
            tableExtent: SIMD2(0.75, 1.00),
            tileDimensions: dimensions
        ).first)

        XCTAssertEqual(eventTrack.box.width, 0.04, accuracy: 1e-6)
        XCTAssertEqual(eventTrack.box.height, 0.04, accuracy: 1e-6)
    }

    func testCensusObservationStreamPreservesLegacyEventKinds() {
        var game = ScriptedGame(seed: 2_026)
        game.deal(myHand: [
            .m(1), .m(2), .m(3), .m(4), .m(5), .p(2), .p(3),
            .p(4), .s(6), .s(7), .s(8), .east, .west,
        ])
        game.myDiscard(.m(1), at: 1)
        game.discard(.right, .s(1), at: 3)
        game.claim(
            .pung,
            by: .across,
            tiles: [.s(1), .s(1), .s(1)],
            at: 5
        )
        game.discard(.across, .p(9), at: 7)
        let legacyFrames = game.frames(
            noise: NoiseModel(
                boxJitter: 0,
                dropoutIdle: 0,
                dropoutAction: 0,
                faceFlicker: 0,
                confidenceRange: 0.9 ... 0.9
            )
        )
        let legacyHarness = TrackerHarness()
        let censusTracker = TableTracker()
        var censusEvents: [GameEvent] = []
        for frame in legacyFrames {
            legacyHarness.step(frame)
            let exactTracks = legacyHarness.store.tracks.map {
                CensusTrackSnapshot(
                    id: CensusTrackID($0.id.raw),
                    worldPosition: nil,
                    tablePoint: SIMD2(
                        Float($0.box.centerX - 0.5),
                        Float($0.box.centerY - 0.5)
                    ),
                    face: .tile($0.face),
                    faceConfidence: 0.9,
                    semanticZone: semanticZone(
                        for: $0.zone,
                        seat: $0.seat
                    ),
                    lifecycle: lifecycle(for: $0.state),
                    firstSeen: $0.firstSeen,
                    lastSeen: $0.lastSeen
                )
            }
            let outcome = censusTracker.ingestCensus(
                CensusSnapshot(
                    generatedAt: frame.t,
                    tracks: exactTracks
                ),
                tableExtent: SIMD2(1, 1),
                at: frame.t,
                motion: frame.motion
            )
            censusEvents += outcome.newEvents
        }

        let legacyKinds = legacyHarness.events.map(\.kind)
        let censusKinds = censusEvents.map(\.kind)
        XCTAssertEqual(censusKinds, legacyKinds)
    }

    func testSemanticOwnershipIsNotReconstructedFromGeometry() throws {
        let point = SIMD2<Float>(0.32, -0.27)
        let tracks = CensusEventAdapter.tracks(
            from: CensusSnapshot(
                generatedAt: 1,
                tracks: [
                    track(1, .confirmed, .m(1), point, zone: .mineHand),
                    track(2, .confirmed, .p(2), point, zone: .tablePond),
                    track(3, .confirmed, .s(3), point, zone: .tableRevealedLeft),
                ]
            ),
            tableExtent: SIMD2(0.8, 1)
        )

        XCTAssertEqual(tracks.map(\.zone), [.myHand, .pond, .opponentMeld])
        XCTAssertEqual(tracks.map(\.seat), [nil, nil, .left])
        XCTAssertEqual(tracks.map(\.id), [
            TrackID(raw: 1),
            TrackID(raw: 2),
            TrackID(raw: 3),
        ])
    }

    func testCensusSynchronizationReplacesLegacyTracksInsteadOfMixingSources() {
        let tracker = TableTracker()
        let legacy = DetectedTile(
            tile: .m(1),
            confidence: 0.95,
            box: TileBoundingBox(
                x: 0.45,
                y: 0.82,
                width: 0.04,
                height: 0.08
            )
        )
        for time in 0 ... 3 {
            _ = tracker.ingest([legacy], at: TimeInterval(time))
        }
        XCTAssertFalse(tracker.store.tracks.isEmpty)

        _ = tracker.ingestCensus(
            CensusSnapshot(
                generatedAt: 5,
                tracks: [
                    track(
                        99,
                        .confirmed,
                        .p(9),
                        SIMD2.zero,
                        zone: .tablePond
                    ),
                ]
            ),
            tableExtent: SIMD2(0.8, 1),
            at: 5
        )

        XCTAssertEqual(tracker.store.tracks.map(\.id), [TrackID(raw: 99)])
        XCTAssertEqual(tracker.store.tracks.map(\.zone), [.pond])
    }

    private func track(
        _ id: Int,
        _ lifecycle: TrackLifecycleState,
        _ tile: Tile,
        _ point: SIMD2<Float>,
        zone: SemanticZoneID = .tablePond
    ) -> CensusTrackSnapshot {
        CensusTrackSnapshot(
            id: CensusTrackID(id),
            worldPosition: nil,
            tablePoint: point,
            face: .tile(tile),
            faceConfidence: 0.9,
            semanticZone: zone,
            lifecycle: lifecycle,
            firstSeen: 0,
            lastSeen: 1
        )
    }

    private func semanticZone(
        for zone: TileZone,
        seat: RelativeSeat?
    ) -> SemanticZoneID {
        switch zone {
        case .myHand, .myBonus:
            return .mineHand
        case .myMeld:
            return .mineMeld
        case .pond:
            return .tablePond
        case .opponentMeld:
            switch seat {
            case .left:
                return .tableRevealedLeft
            case .right:
                return .tableRevealedRight
            case .across, .me, nil:
                return .tableRevealedFar
            }
        case .unresolved:
            return .boundaryUnresolved
        }
    }

    private func lifecycle(
        for life: TrackedTile.Life
    ) -> TrackLifecycleState {
        switch life {
        case .tentative:
            return .tentative
        case .live:
            return .confirmed
        case .missing:
            return .temporarilyMissing
        case .retired:
            return .retired
        }
    }
}

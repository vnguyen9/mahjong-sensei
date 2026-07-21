import XCTest
import simd
@testable import Recognition
import MahjongCore

final class WorldPhysicalCensusTests: XCTestCase {
    private static let quality = FrameQuality(
        trackingIsNormal: true,
        sharpness: 1,
        exposureScore: 1,
        clippingFraction: 0,
        projectedPixelsPerTile: 100,
        coverageFraction: 1,
        accepted: true
    )

    private func observation(_ world: SIMD3<Float>, frame: Int,
                             x: Double = 0.4) -> TileObservation {
        TileObservation(
            frameID: FrameID(frame),
            box: TileBoundingBox(x: x, y: 0.4, width: 0.05, height: 0.08),
            confidence: 0.9,
            poseHint: .flat,
            footprintCenter: SIMD2(world.x, world.z),
            footprintRadius: 0.012,
            worldPosition: world
        )
    }

    private func ingest(_ observations: [TileObservation],
                        into census: PhysicalCensus,
                        qualifiedEmpty: Set<CensusTrackID> = [],
                        frame: Int,
                        time: TimeInterval) {
        let batch = ObservationBatch(
            frameID: FrameID(frame),
            observations: observations,
            coverage: CoverageMask(),
            quality: Self.quality
        )
        census.ingest(
            .success(batch),
            zones: [.tablePond: [
                SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1),
            ]],
            context: CensusFrameContext(
                worldToTable: matrix_identity_float4x4,
                qualifiedEmptyTrackIDs: qualifiedEmpty
            ),
            at: time
        )
    }

    func test_worldJitterMatchesOneStableIdentity() {
        let census = PhysicalCensus()
        let points: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(0.006, 0.001, -0.003),
            SIMD3(-0.004, -0.001, 0.004),
            SIMD3(0.003, 0, 0.002),
        ]
        for (frame, point) in points.enumerated() {
            ingest([observation(point, frame: frame)], into: census, frame: frame, time: Double(frame) * 0.1)
        }

        let snapshot = census.snapshot(at: 1)
        XCTAssertEqual(snapshot.tracks.count, 1)
        XCTAssertEqual(snapshot.tracks.first?.id, CensusTrackID(0))
        XCTAssertEqual(snapshot.tracks.first?.lifecycle, .confirmed)
        XCTAssertEqual(census.anchors.count, 1)
        XCTAssertEqual(census.diagnostics.births, 1)
        XCTAssertEqual(census.diagnostics.matches, 3)
    }

    func testSplitThresholdRequiresPoint45ForBirthButAllowsPoint30ToConfirmExistingTrack() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.45
        let census = PhysicalCensus(config: config)
        let point = SIMD3<Float>(0, 0, 0)

        ingest([
            TileObservation(
                frameID: FrameID(0),
                box: TileBoundingBox(x: 0.4, y: 0.4, width: 0.05, height: 0.08),
                confidence: 0.30,
                poseHint: .flat,
                footprintCenter: SIMD2(0, 0),
                footprintRadius: 0.012,
                worldPosition: point
            ),
        ], into: census, frame: 0, time: 0)
        XCTAssertTrue(census.tracks.isEmpty)

        ingest([observation(point, frame: 1)], into: census, frame: 1, time: 0.1)
        for frame in 2...3 {
            ingest([
                TileObservation(
                    frameID: FrameID(frame),
                    box: TileBoundingBox(x: 0.4, y: 0.4, width: 0.05, height: 0.08),
                    confidence: 0.30,
                    poseHint: .flat,
                    footprintCenter: SIMD2(0, 0),
                    footprintRadius: 0.012,
                    worldPosition: point
                ),
            ], into: census, frame: frame, time: Double(frame) * 0.1)
        }

        XCTAssertEqual(census.tracks.count, 1)
        XCTAssertEqual(census.tracks.first?.state, .confirmed)
        XCTAssertEqual(census.diagnostics.births, 1)
        XCTAssertEqual(census.diagnostics.matches, 2)
    }

    func testStaleTrackReacquiresWithinDimensionDerivedRecoveryRadiusWithoutReplacementBirth() {
        let census = PhysicalCensus()
        let original = SIMD3<Float>(0, 0, 0)
        for frame in 0..<3 {
            ingest([observation(original, frame: frame)], into: census, frame: frame, time: Double(frame) * 0.1)
        }
        let id = CensusTrackID(0)
        ingest([], into: census, frame: 3, time: 0.3)
        XCTAssertEqual(census.tracks.first?.state, .stale)

        // 20 mm is beyond the primary 18 mm gate, but within the bounded
        // 22 mm stale recovery gate for standard 24 mm tiles.
        ingest([observation(SIMD3(0.020, 0, 0), frame: 4)], into: census, frame: 4, time: 0.4)

        XCTAssertEqual(census.tracks.count, 1)
        XCTAssertEqual(census.tracks.first?.id, id)
        XCTAssertEqual(census.tracks.first?.state, .confirmed)
        XCTAssertEqual(census.diagnostics.staleWorldReacquisitions, 1)
        XCTAssertEqual(census.diagnostics.births, 1)
    }

    func testObservationNearAmbiguousStaleTrackDoesNotBirthReplacementIdentity() {
        let census = PhysicalCensus()
        for frame in 0..<3 {
            ingest(
                [
                    observation(SIMD3(0, 0, 0), frame: frame, x: 0.4),
                    observation(SIMD3(0.030, 0, 0), frame: frame, x: 0.5),
                ],
                into: census,
                frame: frame,
                time: Double(frame) * 0.1
            )
        }

        // Keep the right-hand track observed while the left-hand track goes
        // stale. This models panning/reprojection noise rather than a known
        // empty location.
        ingest([observation(SIMD3(0.030, 0, 0), frame: 3, x: 0.5)], into: census, frame: 3, time: 0.3)
        XCTAssertEqual(census.tracks.first?.state, .stale)

        // The 19 mm observation is viable for the stale left track but a
        // better primary match for the right track. The global solver assigns
        // the right track to the 21 mm observation, leaving this one
        // ambiguous; it must wait, not create a third physical identity.
        ingest(
            [
                observation(SIMD3(0.019, 0, 0), frame: 4, x: 0.4),
                observation(SIMD3(0.021, 0, 0), frame: 4, x: 0.5),
            ],
            into: census,
            frame: 4,
            time: 0.4
        )

        XCTAssertEqual(census.tracks.count, 2)
        XCTAssertEqual(census.diagnostics.births, 2)
        XCTAssertEqual(census.diagnostics.suppressedReplacementBirths, 1)
    }

    func testCustomTileDimensionsDriveFootprintAndKeepTwentyFourMillimeterNeighborsDistinct() {
        var config = CensusConfig()
        config.tileDimensions = PhysicalTileDimensions(width: 0.030, length: 0.040, height: 0.018)
        let census = PhysicalCensus(config: config)
        let unsizedObservation = TileObservation(
            frameID: FrameID(-1),
            box: TileBoundingBox(x: 0.2, y: 0.2, width: 0.05, height: 0.08),
            confidence: 0.9,
            poseHint: .flat,
            footprintCenter: SIMD2(-0.10, 0),
            worldPosition: SIMD3(-0.10, 0, 0)
        )
        ingest([unsizedObservation], into: census, frame: -1, time: -0.1)
        XCTAssertEqual(census.tracks.first?.footprintRadius, 0.015)

        census.resetTiles()
        for frame in 0..<3 {
            ingest(
                [
                    observation(SIMD3(0, 0, 0), frame: frame, x: 0.4),
                    observation(SIMD3(0.024, 0, 0), frame: frame, x: 0.5),
                ],
                into: census,
                frame: frame,
                time: Double(frame) * 0.1
            )
        }

        XCTAssertEqual(census.tracks.count, 2)
        XCTAssertEqual(config.tileDimensions.footprintRadius, 0.015)
    }

    func testGlobalAssignmentAvoidsGreedyCrossPairingInDenseImageSpace() {
        let track0 = PhysicalTrack(
            id: CensusTrackID(0),
            anchorCenter: .zero,
            footprintRadius: 0.012,
            imageBox: TileBoundingBox(x: 0, y: 0, width: 14, height: 10),
            at: 0
        )
        let track1 = PhysicalTrack(
            id: CensusTrackID(1),
            anchorCenter: .zero,
            footprintRadius: 0.012,
            imageBox: TileBoundingBox(x: 0, y: 0, width: 6.1, height: 10),
            at: 0
        )
        let observations = [
            TileObservation(
                frameID: FrameID(1),
                box: TileBoundingBox(x: 0, y: 0, width: 10, height: 10),
                confidence: 0.9
            ),
            TileObservation(
                frameID: FrameID(1),
                box: TileBoundingBox(x: 6, y: 0, width: 10, height: 10),
                confidence: 0.9
            ),
        ]
        var config = CensusConfig()
        config.centerCostWeight = 0
        config.footprintCostWeight = 0
        config.imageCostWeight = 1
        config.faceCostWeight = 0

        let result = TrackAssociator.associate(
            tracks: [track0, track1],
            observations: observations,
            config: config
        )

        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual(result.matches.first?.trackIndex, 0)
        XCTAssertEqual(result.matches.first?.observationIndex, 1)
        XCTAssertEqual(result.matches.last?.trackIndex, 1)
        XCTAssertEqual(result.matches.last?.observationIndex, 0)
    }

    func test_adjacentTilesOutsideWorldGateStayDistinct() {
        let census = PhysicalCensus()
        for frame in 0..<3 {
            ingest(
                [
                    observation(SIMD3(0, 0, 0), frame: frame, x: 0.4),
                    observation(SIMD3(0.025, 0, 0), frame: frame, x: 0.5),
                ],
                into: census,
                frame: frame,
                time: Double(frame) * 0.1
            )
        }

        let tracks = census.snapshot(at: 1).tracks
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(Set(tracks.map(\.id)), Set([CensusTrackID(0), CensusTrackID(1)]))
        XCTAssertTrue(tracks.allSatisfy { $0.lifecycle == .confirmed })
    }

    func test_outOfViewOrOccludedTrackNeverAccumulatesMisses() {
        let census = PhysicalCensus()
        for frame in 0..<3 {
            ingest(
                [observation(SIMD3(0, 0, 0), frame: frame)],
                into: census,
                frame: frame,
                time: Double(frame) * 0.1
            )
        }

        // The app omits IDs from `qualifiedEmptyTrackIDs` for offscreen
        // tracks, missing depth, and closer occluding geometry.
        for frame in 3..<20 {
            ingest([], into: census, qualifiedEmpty: [], frame: frame, time: Double(frame))
        }

        let track = census.snapshot(at: 20).tracks.first
        XCTAssertEqual(track?.id, CensusTrackID(0))
        XCTAssertEqual(track?.lifecycle, .stale)
        XCTAssertEqual(census.diagnostics.qualifiedMisses, 0)
        XCTAssertEqual(census.diagnostics.retirements, 0)
    }

    func test_visibleEmptyRetiresOnFifthQualifiedMissAtMinimumDuration() {
        let census = PhysicalCensus()
        for frame in 0..<3 {
            ingest(
                [observation(SIMD3(0, 0, 0), frame: frame)],
                into: census,
                frame: frame,
                time: Double(frame) * 0.1
            )
        }
        let id = CensusTrackID(0)
        let missTimes: [TimeInterval] = [1.0, 1.2, 1.4, 1.6]
        for (offset, time) in missTimes.enumerated() {
            ingest([], into: census, qualifiedEmpty: [id], frame: 10 + offset, time: time)
        }
        XCTAssertEqual(census.snapshot(at: 1.6).tracks.first?.lifecycle, .temporarilyMissing)

        ingest([], into: census, qualifiedEmpty: [id], frame: 20, time: 1.8)
        XCTAssertTrue(census.snapshot(at: 1.8).tracks.isEmpty)
        XCTAssertEqual(census.diagnostics.qualifiedMisses, 5)
        XCTAssertEqual(census.diagnostics.retirements, 1)
    }

    func test_snapshotAndCorrectionsAreDeterministic() {
        let census = PhysicalCensus()
        for frame in 0..<3 {
            ingest(
                [observation(SIMD3(0.2, 0, 0.1), frame: frame)],
                into: census,
                frame: frame,
                time: Double(frame) * 0.1
            )
        }
        census.pinFace(.tile(.m(1)), trackID: CensusTrackID(0))
        census.overrideSemanticZone(.mineHand, trackID: CensusTrackID(0))

        let first = census.snapshot(at: 1)
        let second = census.snapshot(at: 1)
        XCTAssertEqual(first.tracks, second.tracks)
        XCTAssertEqual(first.mine[.m(1)], 1)
        XCTAssertEqual(first.tracks.first?.semanticZone, .mineHand)

        census.removeTrack(id: CensusTrackID(0))
        XCTAssertTrue(census.snapshot(at: 2).tracks.isEmpty)
    }

    func testCombinedFaceAndZoneCorrectionSupportsIgnoredAndUnresolvedDestinations() throws {
        let census = PhysicalCensus()
        for frame in 0..<3 {
            ingest(
                [observation(SIMD3(0.1, 0, 0.1), frame: frame)],
                into: census,
                frame: frame,
                time: Double(frame) * 0.1
            )
        }

        let id = CensusTrackID(0)
        census.correct(
            trackID: id,
            face: .tile(.p(7)),
            semanticZone: .ignoredWall
        )
        var track = try XCTUnwrap(census.snapshot(at: 1).tracks.first)
        XCTAssertEqual(track.face, .tile(.p(7)))
        XCTAssertEqual(track.semanticZone, .ignoredWall)

        census.correct(trackID: id, semanticZone: .boundaryUnresolved)
        track = try XCTUnwrap(census.snapshot(at: 1).tracks.first)
        XCTAssertEqual(track.face, .tile(.p(7)), "A zone-only edit must retain the pinned face")
        XCTAssertEqual(track.semanticZone, .boundaryUnresolved)
    }

    /// `WorldCensusController.apply` is intentionally a thin app-side
    /// wrapper over this operation. Keep this characterization here, where it
    /// can run without ARKit: accepting a new calibration must re-zone the
    /// same physical identity, never reset or duplicate the census.
    func test_reassigningCalibrationZonesPreservesConfirmedWorldTrackIdentity() throws {
        let census = PhysicalCensus()
        for frame in 0..<3 {
            ingest(
                [observation(SIMD3(0, 0, 0), frame: frame)],
                into: census,
                frame: frame,
                time: Double(frame) * 0.1
            )
        }

        let before = census.snapshot(at: 1)
        let beforeTrack = try XCTUnwrap(before.tracks.first)
        XCTAssertEqual(beforeTrack.id, CensusTrackID(0))
        XCTAssertEqual(beforeTrack.lifecycle, .confirmed)
        XCTAssertEqual(beforeTrack.semanticZone, .tablePond)

        census.reassignZones(
            [.mineHand: [
                SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1),
            ]],
            worldToTable: matrix_identity_float4x4
        )

        let after = census.snapshot(at: 1)
        let afterTrack = try XCTUnwrap(after.tracks.first)
        XCTAssertEqual(after.tracks.count, 1)
        XCTAssertEqual(afterTrack.id, beforeTrack.id)
        XCTAssertEqual(afterTrack.lifecycle, beforeTrack.lifecycle)
        XCTAssertEqual(afterTrack.worldPosition, beforeTrack.worldPosition)
        XCTAssertEqual(afterTrack.firstSeen, beforeTrack.firstSeen)
        XCTAssertEqual(afterTrack.lastSeen, beforeTrack.lastSeen)
        XCTAssertEqual(afterTrack.semanticZone, .mineHand)
        XCTAssertEqual(census.diagnostics.births, 1)
        XCTAssertEqual(census.diagnostics.retirements, 0)
    }
}

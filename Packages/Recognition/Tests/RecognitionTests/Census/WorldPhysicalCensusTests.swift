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
                        visible: Set<CensusTrackID> = [],
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
                visibleTrackIDs: visible
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

        // The app omits IDs from `visibleTrackIDs` for offscreen tracks,
        // missing depth, and closer occluding geometry.
        for frame in 3..<20 {
            ingest([], into: census, visible: [], frame: frame, time: Double(frame))
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
            ingest([], into: census, visible: [id], frame: 10 + offset, time: time)
        }
        XCTAssertEqual(census.snapshot(at: 1.6).tracks.first?.lifecycle, .temporarilyMissing)

        ingest([], into: census, visible: [id], frame: 20, time: 1.8)
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
}

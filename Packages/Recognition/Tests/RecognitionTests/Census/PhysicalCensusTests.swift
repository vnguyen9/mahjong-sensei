import XCTest
import simd
@testable import Recognition
import MahjongCore

/// Chunk B census tests (§9, §10) driven through the public facade
/// (`PhysicalCensus.ingest`/`.snapshot`), reading `PhysicalCensus.tracks`
/// (internal, visible here via `@testable`) for assertions the public
/// `CensusSnapshot` alone can't express (e.g. a single track's state).
final class PhysicalCensusTests: XCTestCase {

    // MARK: - Fixtures

    private static func acceptedQuality() -> FrameQuality {
        FrameQuality(trackingIsNormal: true, sharpness: 1, exposureScore: 1,
                     clippingFraction: 0, projectedPixelsPerTile: 100,
                     coverageFraction: 1, accepted: true)
    }

    private static func polygon(_ zoneID: SemanticZoneID, _ vertices: [SIMD2<Float>],
                                frame: Int = 0, at time: TimeInterval = 0) -> ObservedPolygon {
        ObservedPolygon(zoneID: zoneID, vertices: vertices, frameID: FrameID(frame),
                        observedAt: time, quality: acceptedQuality())
    }

    private static func observation(center: SIMD2<Float>, radius: Float = 0.02,
                                    box: TileBoundingBox = TileBoundingBox(x: 0.1, y: 0.1, width: 0.05, height: 0.08),
                                    face: TileFaceHypothesis? = nil, confidence: Float = 0.9,
                                    frame: Int = 0,
                                    passID: UInt64? = nil,
                                    qualifies: Bool = true,
                                    observedAt: TimeInterval? = nil) -> TileObservation {
        TileObservation(frameID: FrameID(frame), box: box, confidence: confidence, poseHint: .flat,
                        faceHypothesis: face, footprintCenter: center, footprintRadius: radius,
                        faceEvidencePassID: passID,
                        faceEvidenceQualifiesForPublication: qualifies,
                        faceEvidenceTimestamp: observedAt)
    }

    private static func hypothesis(top: TileFace, topProb: Float, alt: TileFace,
                                   altProb: Float, confidence: Float? = nil) -> TileFaceHypothesis {
        TileFaceHypothesis(probabilities: [top: topProb, alt: altProb], topFace: top,
                           confidence: confidence ?? topProb,
                           margin: topProb - altProb, rejectionScore: 1 - topProb)
    }

    /// A 5×1m mineHand strip so several well-separated tracks can live in
    /// the same bucket without their gates ever overlapping.
    private static let mineHandStrip: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(5, 0), SIMD2(5, 1), SIMD2(0, 1),
    ]
    private static let tablePondSquare: [SIMD2<Float>] = [
        SIMD2(10, 0), SIMD2(12, 0), SIMD2(12, 2), SIMD2(10, 2),
    ]

    /// Ingests `hits` consecutive successful single-observation batches at
    /// `center`, all carrying the same `hypothesis` — enough (with default
    /// config) to confirm the track after the 3rd hit and, once evidence and
    /// margin clear their thresholds, publish `hypothesis`'s top face.
    ///
    /// Every batch here carries empty coverage, so any *other already-live*
    /// track this census is tracking counts as a coverage loss, not a hit —
    /// fine for a single isolated track, but callers juggling several
    /// simultaneously-live tracks must use `confirmTracks` instead so nobody
    /// goes stale between rounds.
    @discardableResult
    private func ingestRepeatedHits(_ census: PhysicalCensus, center: SIMD2<Float>, hits: Int,
                                    hypothesis: TileFaceHypothesis?, zones: [SemanticZoneID: [SIMD2<Float>]],
                                    startFrame: Int, startTime: TimeInterval) -> TimeInterval {
        confirmTracks(census, targets: [(center, hypothesis)], rounds: hits, zones: zones,
                     startFrame: startFrame, startTime: startTime)
    }

    /// Ingests `rounds` successful batches, each containing one observation
    /// per target *in the same batch* — so several tracks can be confirmed
    /// side by side without any of them appearing to lose coverage while
    /// another is still accumulating hits.
    @discardableResult
    private func confirmTracks(_ census: PhysicalCensus,
                               targets: [(center: SIMD2<Float>, hypothesis: TileFaceHypothesis?)],
                               rounds: Int, zones: [SemanticZoneID: [SIMD2<Float>]],
                               startFrame: Int, startTime: TimeInterval, dt: TimeInterval = 0.1) -> TimeInterval {
        var time = startTime
        for round in 0..<rounds {
            let observations = targets.map { target in
                Self.observation(center: target.center, face: target.hypothesis, frame: startFrame + round)
            }
            let batch = ObservationBatch(frameID: FrameID(startFrame + round), observations: observations,
                                         coverage: CoverageMask(), quality: Self.acceptedQuality())
            census.ingest(.success(batch), zones: zones, at: time)
            time += dt
        }
        return time
    }

    private func ingest(
        _ census: PhysicalCensus,
        center: SIMD2<Float> = SIMD2(2, 0.5),
        detectionConfidence: Float,
        face: TileFace,
        alternate: TileFace,
        frame: Int,
        at time: TimeInterval
    ) {
        let hypothesis = Self.hypothesis(
            top: face,
            topProb: detectionConfidence,
            alt: alternate,
            altProb: max(0, 1 - detectionConfidence),
            confidence: detectionConfidence
        )
        let batch = ObservationBatch(
            frameID: FrameID(frame),
            observations: [
                Self.observation(
                    center: center,
                    face: hypothesis,
                    confidence: detectionConfidence,
                    frame: frame
                ),
            ],
            coverage: CoverageMask(),
            quality: Self.acceptedQuality()
        )
        census.ingest(.success(batch), zones: [:], at: time)
    }

    // MARK: - Physical recall is separate from face certainty

    func testCoachCandidateThresholdRejectsPoint29ButConfirmsPoint30AsUnknown() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.30
        let census = PhysicalCensus(config: config)
        let faceA = TileFace.tile(.m(1))
        let faceB = TileFace.tile(.p(1))

        ingest(census, detectionConfidence: 0.29, face: faceA, alternate: faceB, frame: 0, at: 0)
        XCTAssertTrue(census.tracks.isEmpty)

        for frame in 1 ... 3 {
            ingest(
                census,
                detectionConfidence: 0.30,
                face: faceA,
                alternate: faceB,
                frame: frame,
                at: Double(frame) * 0.1
            )
        }

        XCTAssertEqual(census.tracks.count, 1)
        XCTAssertEqual(census.tracks.first?.state, .confirmed)
        XCTAssertNil(census.tracks.first?.publishedFace)
        XCTAssertEqual(census.tracks.first?.faceSuggestion?.face, faceA)
        XCTAssertEqual(census.diagnostics.lowConfidenceFaceCandidates, 3)
    }

    func testTwoPoint79ReadsNeverPublishAFace() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.30
        let census = PhysicalCensus(config: config)
        let faceA = TileFace.tile(.m(2))
        let faceB = TileFace.tile(.p(2))

        ingest(census, detectionConfidence: 0.79, face: faceA, alternate: faceB, frame: 0, at: 0)
        ingest(census, detectionConfidence: 0.79, face: faceA, alternate: faceB, frame: 1, at: 0.1)

        XCTAssertNil(census.tracks.first?.publishedFace)
        XCTAssertEqual(census.tracks.first?.strongFaceReadCount, 0)
        XCTAssertEqual(census.tracks.first?.faceSuggestion?.face, faceA)
    }

    func testBroadStrongReadsSuggestButNeverPublish() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.45
        let census = PhysicalCensus(config: config)
        let faceA = TileFace.tile(.m(2))
        let faceB = TileFace.tile(.p(2))
        let hypothesis = Self.hypothesis(
            top: faceA, topProb: 0.95, alt: faceB, altProb: 0.05
        )
        for frame in 0..<3 {
            let observation = Self.observation(
                center: SIMD2(2, 0.5), face: hypothesis, confidence: 0.95,
                frame: frame, passID: UInt64(frame), qualifies: false,
                observedAt: Double(frame)
            )
            census.ingest(.success(ObservationBatch(
                frameID: FrameID(frame), observations: [observation],
                coverage: CoverageMask(), quality: Self.acceptedQuality()
            )), zones: [:], at: Double(frame))
        }
        XCTAssertEqual(census.tracks.first?.faceSuggestion?.face, faceA)
        XCTAssertNil(census.tracks.first?.publishedFace)
        XCTAssertEqual(census.tracks.first?.strongFaceReadCount, 0)
    }

    func testIndependentDetailPassesNeedHalfSecondSeparation() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.45
        let census = PhysicalCensus(config: config)
        let faceA = TileFace.tile(.m(3))
        let faceB = TileFace.tile(.p(3))
        let hypothesis = Self.hypothesis(
            top: faceA, topProb: 0.90, alt: faceB, altProb: 0.10
        )
        func read(frame: Int, pass: UInt64, time: TimeInterval) {
            let observation = Self.observation(
                center: SIMD2(2, 0.5), face: hypothesis, confidence: 0.90,
                frame: frame, passID: pass, qualifies: true,
                observedAt: time
            )
            census.ingest(.success(ObservationBatch(
                frameID: FrameID(frame), observations: [observation],
                coverage: CoverageMask(), quality: Self.acceptedQuality()
            )), zones: [:], at: time)
        }
        read(frame: 0, pass: 10, time: 0)
        read(frame: 1, pass: 10, time: 0.6)
        XCTAssertEqual(census.tracks.first?.strongFaceReadCount, 1)
        read(frame: 2, pass: 11, time: 0.4)
        XCTAssertEqual(census.tracks.first?.strongFaceReadCount, 1)
        read(frame: 3, pass: 12, time: 0.6)
        XCTAssertEqual(census.tracks.first?.publishedFace, faceA)
    }

    func testAutomaticOwnershipNeedsThreeObservedVotesToCrossBoundary() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.45
        let census = PhysicalCensus(config: config)
        let left: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(0.5, 1), SIMD2(0, 1),
        ]
        let right: [SIMD2<Float>] = [
            SIMD2(0.5, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0.5, 1),
        ]
        let zones: [SemanticZoneID: [SIMD2<Float>]] = [
            .tablePond: left,
            .mineHand: right,
        ]
        _ = ingestRepeatedHits(
            census, center: SIMD2(0.45, 0.5), hits: 3,
            hypothesis: nil, zones: zones, startFrame: 0, startTime: 0
        )
        XCTAssertEqual(census.tracks.first?.semanticZone, .tablePond)

        for vote in 1...2 {
            let observation = Self.observation(
                center: SIMD2(0.55, 0.5), confidence: 0.9,
                frame: 10 + vote
            )
            census.ingest(.success(ObservationBatch(
                frameID: FrameID(10 + vote), observations: [observation],
                coverage: CoverageMask(), quality: Self.acceptedQuality()
            )), zones: zones, at: 1 + Double(vote) * 0.1)
            XCTAssertEqual(census.tracks.first?.semanticZone, .tablePond)
        }
        let third = Self.observation(
            center: SIMD2(0.55, 0.5), confidence: 0.9, frame: 13
        )
        census.ingest(.success(ObservationBatch(
            frameID: FrameID(13), observations: [third],
            coverage: CoverageMask(), quality: Self.acceptedQuality()
        )), zones: zones, at: 1.3)
        XCTAssertEqual(census.tracks.first?.semanticZone, .mineHand)
    }

    func testSecondMatchingPoint80ReadPublishesFace() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.30
        let census = PhysicalCensus(config: config)
        let faceA = TileFace.tile(.m(3))
        let faceB = TileFace.tile(.p(3))

        ingest(census, detectionConfidence: 0.80, face: faceA, alternate: faceB, frame: 0, at: 0)
        XCTAssertNil(census.tracks.first?.publishedFace)
        XCTAssertEqual(census.tracks.first?.strongFaceReadCount, 1)

        ingest(census, detectionConfidence: 0.80, face: faceA, alternate: faceB, frame: 1, at: 0.1)
        XCTAssertEqual(census.tracks.first?.publishedFace, faceA)
        XCTAssertEqual(census.tracks.first?.publishedFaceConfidence, 0.80)
        XCTAssertEqual(census.diagnostics.facePublications, 1)
    }

    func testStrongDisagreementResetsPrePublicationAgreement() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.30
        let census = PhysicalCensus(config: config)
        let faceA = TileFace.tile(.m(4))
        let faceB = TileFace.tile(.p(4))

        ingest(census, detectionConfidence: 0.85, face: faceA, alternate: faceB, frame: 0, at: 0)
        ingest(census, detectionConfidence: 0.86, face: faceB, alternate: faceA, frame: 1, at: 0.1)
        XCTAssertNil(census.tracks.first?.publishedFace)
        XCTAssertEqual(census.tracks.first?.strongFaceReadCount, 1)

        ingest(census, detectionConfidence: 0.87, face: faceB, alternate: faceA, frame: 2, at: 0.2)
        XCTAssertEqual(census.tracks.first?.publishedFace, faceB)
    }

    func testLowConfidenceDisagreementCannotClearPublishedFace() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.30
        let census = PhysicalCensus(config: config)
        let faceA = TileFace.tile(.m(5))
        let faceB = TileFace.tile(.p(5))

        ingest(census, detectionConfidence: 0.90, face: faceA, alternate: faceB, frame: 0, at: 0)
        ingest(census, detectionConfidence: 0.90, face: faceA, alternate: faceB, frame: 1, at: 0.1)
        for frame in 2 ... 6 {
            ingest(
                census,
                detectionConfidence: 0.79,
                face: faceB,
                alternate: faceA,
                frame: frame,
                at: Double(frame) * 0.1
            )
        }

        XCTAssertEqual(census.tracks.first?.publishedFace, faceA)
        XCTAssertFalse(census.tracks.first?.requiresManualFaceResolution == true)
    }

    func testPinnedFaceIgnoresSubsequentAutomaticEvidence() throws {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.30
        let census = PhysicalCensus(config: config)
        let automatic = TileFace.tile(.m(6))
        let correction = TileFace.tile(.p(6))

        ingest(census, detectionConfidence: 0.90, face: automatic, alternate: correction, frame: 0, at: 0)
        let trackID = try XCTUnwrap(census.tracks.first?.id)
        census.pinFace(correction, trackID: trackID)
        for frame in 1 ... 4 {
            ingest(
                census,
                detectionConfidence: 0.99,
                face: automatic,
                alternate: correction,
                frame: frame,
                at: Double(frame) * 0.1
            )
        }

        XCTAssertEqual(census.tracks.first?.publishedFace, correction)
        XCTAssertTrue(census.tracks.first?.isPinned == true)
        XCTAssertEqual(census.tracks.first?.publishedFaceConfidence, 1)
    }

    func testFaceSuggestionUsesOnlyTheLastFiveObservations() {
        var config = CensusConfig()
        config.birthConfidenceThreshold = 0.30
        config.faceSuggestionWindow = 5
        let census = PhysicalCensus(config: config)
        let oldFace = TileFace.tile(.m(7))
        let recentFace = TileFace.tile(.p(7))

        for frame in 0 ..< 5 {
            ingest(census, detectionConfidence: 0.70, face: oldFace, alternate: recentFace,
                   frame: frame, at: Double(frame) * 0.1)
        }
        for frame in 5 ..< 10 {
            ingest(census, detectionConfidence: 0.70, face: recentFace, alternate: oldFace,
                   frame: frame, at: Double(frame) * 0.1)
        }

        XCTAssertEqual(census.tracks.first?.faceSuggestion?.face, recentFace)
        XCTAssertEqual(census.tracks.first?.recentFaceEvidence.count, 5)
        XCTAssertEqual(
            Set(census.tracks.first?.faceSupport.keys.map { $0 } ?? []),
            Set([recentFace])
        )
    }

    // MARK: - Ownership is independent of the published face (§10.1)

    func testConfirmedCorrectionIsImmediatelyAuthoritativeAndDeterministic() {
        let census = PhysicalCensus()
        let first = census.insertConfirmedTrack(
            face: .tile(.m(1)),
            semanticZone: .tablePond,
            tablePoint: SIMD2(0.10, -0.05),
            worldPosition: SIMD3(1, 2, 3),
            at: 10
        )
        let second = census.insertConfirmedTrack(
            face: .tile(.p(9)),
            semanticZone: .mineHand,
            tablePoint: SIMD2(-0.20, 0.30),
            at: 11
        )

        XCTAssertEqual(first, CensusTrackID(0))
        XCTAssertEqual(second, CensusTrackID(1))
        XCTAssertEqual(census.diagnostics.births, 2)

        let snapshot = census.snapshot(at: 12)
        XCTAssertEqual(snapshot.table[.m(1)], 1)
        XCTAssertEqual(snapshot.mine[.p(9)], 1)
        XCTAssertEqual(snapshot.tracks.map(\.id), [first, second])
        XCTAssertEqual(snapshot.tracks.map(\.lifecycle), [.confirmed, .confirmed])
        XCTAssertEqual(snapshot.tracks.first?.worldPosition, SIMD3(1, 2, 3))
    }

    func testBucketStaysPutWhenPublishedFaceBecomesConflicted() {
        let census = PhysicalCensus()
        let zones: [SemanticZoneID: [SIMD2<Float>]] = [.mineHand: Self.mineHandStrip]
        let center = SIMD2<Float>(2, 0.5) // inside mineHandStrip

        let faceA = TileFace.tile(.m(1))
        let faceC = TileFace.tile(.p(9))

        // Two strong reads publish A; the third also confirms the identity.
        var time = ingestRepeatedHits(census, center: center, hits: 3,
                                      hypothesis: Self.hypothesis(top: faceA, topProb: 0.9, alt: faceC, altProb: 0.1),
                                      zones: zones, startFrame: 0, startTime: 0)
        guard let track = census.tracks.first else { return XCTFail("expected a track to have been born") }
        XCTAssertEqual(track.state, .confirmed)
        XCTAssertEqual(track.publishedFace, faceA)
        XCTAssertEqual(track.bucket, .mine, "center sits inside mineHand")

        // Two strong contradictory reads deliberately return the face to ?.
        time = ingestRepeatedHits(census, center: center, hits: 2,
                                  hypothesis: Self.hypothesis(top: faceC, topProb: 0.9, alt: faceA, altProb: 0.1),
                                  zones: zones, startFrame: 10, startTime: time)

        guard let flipped = census.tracks.first(where: { $0.id == track.id }) else {
            return XCTFail("same physical track should persist")
        }
        XCTAssertNil(flipped.publishedFace)
        XCTAssertTrue(flipped.requiresManualFaceResolution)
        XCTAssertEqual(flipped.bucket, .mine, "ownership must not move just because face certainty changed")
    }

    // MARK: - Published faces require explicit conflict resolution (§9.3)

    func testTwoStrongConflictingReadsReturnPublishedFaceToUnknown() {
        let census = PhysicalCensus()
        let center = SIMD2<Float>(2, 0.5)
        let faceA = TileFace.tile(.m(1))
        let faceB = TileFace.tile(.s(5))

        var time = ingestRepeatedHits(census, center: center, hits: 3,
                                      hypothesis: Self.hypothesis(top: faceA, topProb: 0.9, alt: faceB, altProb: 0.1),
                                      zones: [:], startFrame: 0, startTime: 0)
        XCTAssertEqual(census.tracks.first?.publishedFace, faceA)

        // One strong disagreement is insufficient to clear a published face.
        time = ingestRepeatedHits(census, center: center, hits: 1,
                                  hypothesis: Self.hypothesis(top: faceB, topProb: 0.9, alt: faceA, altProb: 0.1),
                                  zones: [:], startFrame: 10, startTime: time)
        XCTAssertEqual(census.tracks.first?.publishedFace, faceA,
                       "one conflicting view must not clear an authoritative face")

        // A low-confidence disagreement is suggestion evidence only and does
        // not interrupt the qualifying B agreement.
        _ = ingestRepeatedHits(census, center: center, hits: 1,
                               hypothesis: Self.hypothesis(top: faceA, topProb: 0.79, alt: faceB, altProb: 0.21),
                               zones: [:], startFrame: 20, startTime: time)
        XCTAssertEqual(census.tracks.first?.publishedFace, faceA)

        // The second strong B read makes the conflict explicit instead of
        // silently replacing a gameplay face.
        _ = ingestRepeatedHits(census, center: center, hits: 1,
                               hypothesis: Self.hypothesis(top: faceB, topProb: 0.9, alt: faceA, altProb: 0.1),
                               zones: [:], startFrame: 21, startTime: time + 0.1)
        XCTAssertNil(census.tracks.first?.publishedFace)
        XCTAssertTrue(census.tracks.first?.requiresManualFaceResolution == true)
        XCTAssertEqual(census.diagnostics.confidentFaceConflicts, 1)
    }

    // MARK: - Depth-proven empty misses (§9.2, §5.2)

    func testCoverageAloneNeverQualifiesAMiss() {
        let census = PhysicalCensus()
        let covered = SIMD2<Float>(1, 0.5)   // inside the polygon in the empty batch below
        let uncovered = SIMD2<Float>(4, 0.5) // outside it

        // Confirm both side by side (same batches each round) so neither
        // appears to lose coverage while the other is still accumulating hits.
        let time = confirmTracks(census, targets: [(covered, nil), (uncovered, nil)], rounds: 3,
                                 zones: [:], startFrame: 0, startTime: 0)
        XCTAssertEqual(census.tracks.filter { $0.state == .confirmed }.count, 2)

        // A zero-detection frame whose coverage reaches `covered` is still
        // not retirement evidence without app-side depth proof.
        let coverage = CoverageMask(regions: [Self.polygon(.mineHand, [
            SIMD2(0, 0), SIMD2(2, 0), SIMD2(2, 1), SIMD2(0, 1),
        ])])
        let batch = ObservationBatch(frameID: FrameID(99), observations: [], coverage: coverage, quality: Self.acceptedQuality())
        for offset in 0..<20 {
            census.ingest(.success(batch), zones: [:], at: time + Double(offset) * 0.2)
        }

        let coveredTrack = census.tracks.first { simd_distance($0.anchorCenter, covered) < 0.01 }
        let uncoveredTrack = census.tracks.first { simd_distance($0.anchorCenter, uncovered) < 0.01 }
        XCTAssertEqual(coveredTrack?.state, .stale)
        XCTAssertEqual(coveredTrack?.qualifiedMissStreak, 0)
        XCTAssertEqual(uncoveredTrack?.state, .stale, "outside this batch's coverage: we simply didn't look there")
        XCTAssertEqual(uncoveredTrack?.qualifiedMissStreak, 0, "coverage loss must never count as a miss")
        XCTAssertEqual(census.diagnostics.qualifiedMisses, 0)
        XCTAssertEqual(census.diagnostics.retirements, 0)
        XCTAssertEqual(census.snapshot(at: time + 4).tracks.count, 2,
                       "repeated covered frames without depth proof must never retire either track")
    }

    func testExplicitDepthProvenEmptyTrackAloneAccruesMiss() throws {
        let census = PhysicalCensus()
        let provenEmpty = SIMD2<Float>(1, 0.5)
        let unknown = SIMD2<Float>(4, 0.5)
        let time = confirmTracks(census, targets: [(provenEmpty, nil), (unknown, nil)], rounds: 3,
                                 zones: [:], startFrame: 0, startTime: 0)

        let provenEmptyID = try XCTUnwrap(census.tracks.first {
            simd_distance($0.anchorCenter, provenEmpty) < 0.01
        }?.id)
        let batch = ObservationBatch(frameID: FrameID(99), observations: [], coverage: CoverageMask(), quality: Self.acceptedQuality())
        census.ingest(
            .success(batch),
            zones: [:],
            context: CensusFrameContext(
                worldToTable: matrix_identity_float4x4,
                qualifiedEmptyTrackIDs: [provenEmptyID]
            ),
            at: time
        )

        let emptyTrack = census.tracks.first { simd_distance($0.anchorCenter, provenEmpty) < 0.01 }
        let unknownTrack = census.tracks.first { simd_distance($0.anchorCenter, unknown) < 0.01 }
        XCTAssertEqual(emptyTrack?.state, .temporarilyMissing)
        XCTAssertEqual(emptyTrack?.qualifiedMissStreak, 1)
        XCTAssertEqual(unknownTrack?.state, .stale)
        XCTAssertEqual(unknownTrack?.qualifiedMissStreak, 0)
        XCTAssertEqual(census.diagnostics.qualifiedMisses, 1)
    }

    // MARK: - failed/skipped add zero hits and zero misses (§8)

    func testFailedAndSkippedOutcomesNeverMutateTracks() {
        let census = PhysicalCensus()
        let center = SIMD2<Float>(1, 0.5)
        let time = ingestRepeatedHits(census, center: center, hits: 3, hypothesis: nil, zones: [:],
                                      startFrame: 0, startTime: 0)
        guard let before = census.tracks.first else { return XCTFail("expected a confirmed track") }
        XCTAssertEqual(before.state, .confirmed)

        census.ingest(.failed(.locatorThrew("boom")), zones: [:], at: time + 1)
        census.ingest(.skipped(.trackingNotNormal), zones: [:], at: time + 2)
        census.ingest(.skipped(.zoneOffScreen), zones: [:], at: time + 3)

        XCTAssertEqual(census.tracks.count, 1, "no births from failed/skipped outcomes")
        let after = census.tracks[0]
        XCTAssertEqual(after.state, .confirmed, "failed/skipped must not push a confirmed track toward temporarilyMissing/stale")
        XCTAssertEqual(after.qualifiedMissStreak, 0)
        XCTAssertEqual(after.recentOpportunities, before.recentOpportunities)
        XCTAssertEqual(after.lastHitAt, before.lastHitAt, "no hit was recorded either")
    }

    // MARK: - Snapshot excludes tentative and unresolved tracks from mine/table (§10.2)

    func testSnapshotExcludesTentativeAndUnresolvedFromCounts() {
        let census = PhysicalCensus()
        let zones: [SemanticZoneID: [SIMD2<Float>]] = [.mineHand: Self.mineHandStrip]
        let face = TileFace.tile(.m(3))
        let alt = TileFace.tile(.p(3))

        // Only 2 hits: enough face evidence to publish, but not enough (3) to confirm.
        let stillTentativeCenter = SIMD2<Float>(1, 0.5)
        _ = ingestRepeatedHits(census, center: stillTentativeCenter, hits: 2,
                               hypothesis: Self.hypothesis(top: face, topProb: 0.9, alt: alt, altProb: 0.1),
                               zones: zones, startFrame: 0, startTime: 0)
        let tentative = census.tracks.first { simd_distance($0.anchorCenter, stillTentativeCenter) < 0.01 }
        XCTAssertEqual(tentative?.state, .tentative)
        XCTAssertNotNil(tentative?.publishedFace, "face fusion doesn't care about lifecycle state")

        // Confirmed, but outside every calibrated zone: bucket is .unresolved.
        let outsideCenter = SIMD2<Float>(50, 50)
        _ = ingestRepeatedHits(census, center: outsideCenter, hits: 3,
                               hypothesis: Self.hypothesis(top: face, topProb: 0.9, alt: alt, altProb: 0.1),
                               zones: zones, startFrame: 10, startTime: 1)
        let outsideTrack = census.tracks.first { simd_distance($0.anchorCenter, outsideCenter) < 0.01 }
        XCTAssertEqual(outsideTrack?.state, .confirmed)
        XCTAssertEqual(outsideTrack?.bucket, .unresolved)

        let snapshot = census.snapshot(at: 2)
        XCTAssertEqual(snapshot.mine.total, 0)
        XCTAssertEqual(snapshot.table.total, 0)
        XCTAssertTrue(snapshot.unresolved.contains { $0.trackID == outsideTrack?.id && $0.reason == .ownershipUnresolved })
        XCTAssertFalse(snapshot.unresolved.contains { $0.trackID == tentative?.id },
                       "a still-tentative track must not appear anywhere in the snapshot")
    }

    // MARK: - Conservation downgrades the lowest-confidence conflicting track (§10.3, integration)

    func testConservationDowngradesLowestConfidenceTrackThroughTheFacade() {
        let census = PhysicalCensus()
        let zones: [SemanticZoneID: [SIMD2<Float>]] = [.mineHand: Self.mineHandStrip]
        let face = TileFace.tile(.m(1))
        let alt = TileFace.tile(.p(1))
        let strongHypothesis = Self.hypothesis(top: face, topProb: 0.95, alt: alt, altProb: 0.05)
        let weakHypothesis = Self.hypothesis(top: face, topProb: 0.82, alt: alt, altProb: 0.18)

        // 5 well-separated tracks confirmed side by side, all published as
        // the same tile (1m) — one copy over the ≤4-per-suited-tile cap
        // (§10.3). Track 3 gets a deliberately weaker hypothesis every
        // round, so its normalized publication confidence is unambiguously
        // the lowest
        // of the five once all are confirmed.
        let targets: [(center: SIMD2<Float>, hypothesis: TileFaceHypothesis?)] = (0..<5).map { i in
            (SIMD2<Float>(0.5 + Float(i), 0.5), i == 3 ? weakHypothesis : strongHypothesis)
        }
        let time = confirmTracks(census, targets: targets, rounds: 3, zones: zones, startFrame: 0, startTime: 0)

        XCTAssertEqual(census.tracks.filter { $0.state == .confirmed }.count, 5)
        guard let weakestID = census.tracks.first(where: { simd_distance($0.anchorCenter, targets[3].center) < 0.01 })?.id
        else { return XCTFail("expected to identify the weak-evidence track") }

        let snapshot = census.snapshot(at: time + 1)
        XCTAssertEqual(snapshot.mine[.m(1)], 4, "the cap must hold even though 5 physical tracks claim this tile")
        XCTAssertEqual(snapshot.mine.total, 4)
        XCTAssertTrue(snapshot.unresolved.contains { $0.trackID == weakestID && $0.reason == .conservationConflict },
                     "the lowest-confidence conflicting track must be the one downgraded")
    }
}

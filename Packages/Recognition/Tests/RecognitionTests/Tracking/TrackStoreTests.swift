import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Chunk-3 coverage: `TrackStore`, the association/lifecycle/voting/rebirth
/// core (the tracker plan's §3.1/§3.2/§3.5 and the TrackStore subset of its §9
/// test list). Two styles are used deliberately:
///
/// - **Hand-built detection frames** where the point is a precise threshold
///   (vote margins, grace timing, the association gate vs the rebirth radius) —
///   noise would only obscure the boundary under test.
/// - **`ScriptedGame` streams** for the emergent properties (stable ids under
///   jitter, end-to-end determinism) where realistic detector noise is exactly
///   what must be survived.
///
/// The first birth in a fresh store always mints `TrackID(raw: 0)` (ids are
/// monotonic from 0), so tests reference ids by their known raw value.
final class TrackStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// A hand-sized box centered at (cx, cy). Defaults roughly match a
    /// player's-seat rank tile (~0.05 × 0.08 normalized).
    private func box(_ cx: Double, _ cy: Double, w: Double = 0.05, h: Double = 0.08) -> TileBoundingBox {
        TileBoundingBox(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func det(_ tile: Tile, _ confidence: Double, _ box: TileBoundingBox) -> DetectedTile {
        DetectedTile(tile: tile, confidence: confidence, box: box)
    }

    private let id0 = TrackID(raw: 0)
    private let id1 = TrackID(raw: 1)

    /// Feeds a live, confirmed single-tile track and returns the store. The
    /// tile sits at `box(0.5, 0.5)`; three high-confidence frames promote it.
    private func liveSingle(_ face: Tile = .m(1)) -> TrackStore {
        let store = TrackStore()
        let b = box(0.5, 0.5)
        for i in 0..<3 { store.associate([det(face, 0.9, b)], at: Double(i) * 0.2) }
        return store
    }

    // MARK: - Position smoothing (Session-4 count-stability)

    func testPositionSmoothingEasesTheBoxCenter() {
        // Smoothing 0.5: a track settled at x=0.5, then a detection jumps to
        // x=0.6, publishes a HALF-eased center (0.55), not the raw 0.6.
        var config = TrackerConfig()
        config.positionSmoothing = 0.5
        let store = TrackStore(config: config)
        let settled = box(0.5, 0.5)
        for i in 0..<3 { store.associate([det(.m(1), 0.9, settled)], at: Double(i) * 0.2) }
        XCTAssertEqual(store.track(id0)?.box.centerX ?? 0, 0.5, accuracy: 1e-9)

        store.associate([det(.m(1), 0.9, box(0.6, 0.5))], at: 0.8)
        XCTAssertEqual(store.track(id0)?.box.centerX ?? 0, 0.55, accuracy: 1e-9,
                       "EMA(0.5) of 0.5→0.6 is 0.55, not the raw jump")
        XCTAssertEqual(store.track(id0)?.box.centerY ?? 0, 0.5, accuracy: 1e-9)
    }

    func testPositionSmoothingOffJumpsToRawDetection() {
        // Default (0) is legacy: the published box IS the latest detection.
        let store = TrackStore()   // positionSmoothing defaults to 0
        for i in 0..<3 { store.associate([det(.m(1), 0.9, box(0.5, 0.5))], at: Double(i) * 0.2) }
        store.associate([det(.m(1), 0.9, box(0.6, 0.5))], at: 0.8)
        XCTAssertEqual(store.track(id0)?.box.centerX ?? 0, 0.6, accuracy: 1e-9)
    }

    // MARK: - Admission (§3.1.4)

    func testTentativePromotesExactlyAtConfirmFrames() {
        let store = TrackStore()
        let b = box(0.5, 0.5)

        let f0 = store.associate([det(.s(5), 0.9, b)], at: 0.0)
        XCTAssertEqual(store.track(id0)?.state, .tentative)
        XCTAssertTrue(f0.promoted.isEmpty)
        XCTAssertEqual(store.counts.live, 0)

        let f1 = store.associate([det(.s(5), 0.9, b)], at: 0.2)
        XCTAssertEqual(store.track(id0)?.state, .tentative, "2 hits < confirmFrames(3): still tentative")
        XCTAssertTrue(f1.promoted.isEmpty)

        let f2 = store.associate([det(.s(5), 0.9, b)], at: 0.4)
        XCTAssertEqual(store.track(id0)?.state, .live, "3rd hit crosses confirmFrames → live")
        XCTAssertEqual(f2.promoted, [id0])
        XCTAssertEqual(store.counts.live, 1)
    }

    func testTwoFrameFlickerIsNeverAdmittedAndDiesSilently() {
        let store = TrackStore()
        let b = box(0.5, 0.5)

        _ = store.associate([det(.s(5), 0.9, b)], at: 0.0)   // birth (hits 1)
        let f1 = store.associate([det(.s(5), 0.9, b)], at: 0.2)   // hits 2 — still tentative
        XCTAssertEqual(store.track(id0)?.state, .tentative)
        XCTAssertTrue(f1.promoted.isEmpty)
        XCTAssertEqual(store.counts.live, 0)

        _ = store.associate([], at: 0.4)   // miss 1
        XCTAssertNotNil(store.track(id0), "one miss is survivable while tentative")
        _ = store.associate([], at: 0.6)   // miss 2 → silent death
        XCTAssertNil(store.track(id0), "2 misses kill an unconfirmed track — no event, no retirement")
        XCTAssertEqual(store.counts, .init(), "nothing left behind")
    }

    // MARK: - Low band sustains, never births (§3.1.3)

    func testLowBandDipSustainsWithoutBirthingOrRebirthing() {
        let store = liveSingle(.m(1))
        let b = box(0.5, 0.5)

        for i in 0..<3 {
            // 0.35 is below highConfidence(0.50): pure low-band matches.
            let out = store.associate([det(.m(1), 0.35, b)], at: 0.6 + Double(i) * 0.2)
            XCTAssertTrue(out.born.isEmpty, "low-band detections must never birth a second track")
            XCTAssertTrue(out.reborn.isEmpty, "the track never went missing, so no rebirth")
            XCTAssertEqual(store.counts.live, 1, "still exactly one continuous identity")
        }
        XCTAssertEqual(store.track(id0)?.state, .live)
        XCTAssertNil(store.track(id1), "no new id was ever minted")
    }

    // MARK: - Missing grace: calm vs action (§3.1.5)

    func testMissingGraceRetiresAfterSettledWindowWhenCalm() {
        let store = liveSingle()
        XCTAssertEqual(store.track(id0)?.state, .live)

        _ = store.associate([], at: 1.0)                 // → missing, since 1.0 (no motion ever seen)
        XCTAssertEqual(store.track(id0)?.state, .missing)

        _ = store.associate([], at: 2.5)                 // 1.5 s < missingGraceSettled(2.0)
        XCTAssertEqual(store.track(id0)?.state, .missing)

        _ = store.associate([], at: 3.1)                 // 2.1 s > 2.0 → retired
        XCTAssertNil(store.track(id0), "a calm missing track retires after the settled grace")
        XCTAssertEqual(store.counts.retired, 1, "kept in the rebirth ring, not deleted")
    }

    func testRecentMotionExtendsGraceToTheActionWindow() {
        let store = liveSingle()
        func motion(_ t: TimeInterval) -> MotionSample { MotionSample(t: t, level: 0.3) }

        _ = store.associate([], at: 1.0, motion: motion(1.0))   // → missing, since 1.0
        // 2.5 s missing: a calm track (grace 2.0) would already be gone; recent
        // motion stretches grace to 6.0, so it survives.
        _ = store.associate([], at: 3.5, motion: motion(3.5))
        XCTAssertEqual(store.track(id0)?.state, .missing, "motion grace keeps it alive past the settled cutoff")

        _ = store.associate([], at: 6.5, motion: motion(6.5))   // 5.5 s < 6.0
        XCTAssertEqual(store.track(id0)?.state, .missing)

        _ = store.associate([], at: 7.1, motion: motion(7.1))   // 6.1 s > 6.0 → retired
        XCTAssertNil(store.track(id0))
    }

    // MARK: - Rebirth vs genuine birth (§3.5)

    func testNudgedTileRebirthsSameTrackIDNoDoubleCount() {
        let store = liveSingle(.m(1))
        let originalCenterX = store.track(id0)!.box.centerX

        // Shift the detection far enough to break the tight association gate
        // (0.75 diag ≈ 0.07) but stay well inside the loose rebirth radius
        // (2.5 diag ≈ 0.24): the classic bumped-tile case.
        let nudged = box(0.5 + 0.10, 0.5)
        let out = store.associate([det(.m(1), 0.9, nudged)], at: 0.6)

        XCTAssertEqual(out.reborn, [id0], "the old identity is resurrected, not replaced")
        XCTAssertTrue(out.born.isEmpty, "no fresh track is born")
        XCTAssertNil(store.track(id1), "no new id minted — double-counting avoided")
        XCTAssertEqual(store.track(id0)?.state, .live)
        XCTAssertGreaterThan(store.track(id0)!.box.centerX, originalCenterX, "box followed the tile silently")
    }

    func testGenuinelyNewTileGetsAFreshID() {
        let store = liveSingle(.m(1))
        // The original tile stays put (keeps id0 live) and an unrelated tile
        // appears far away with a different face — no rebirth candidate.
        let out = store.associate([det(.m(1), 0.9, box(0.5, 0.5)),
                                   det(.s(5), 0.9, box(0.2, 0.2))], at: 0.6)
        XCTAssertEqual(out.born, [id1], "a genuine new tile mints a new id")
        XCTAssertTrue(out.reborn.isEmpty)
        XCTAssertEqual(store.track(id0)?.face, .m(1))
        XCTAssertEqual(store.track(id1)?.face, .s(5))
    }

    func testRemovedTrackIsSuppressedFromInstantRebirth() {
        let store = liveSingle(.m(1))
        store.removeTrack(id0)
        XCTAssertNil(store.track(id0))

        // The same ghost detection tries to come straight back — suppressed.
        let out = store.associate([det(.m(1), 0.9, box(0.5, 0.5))], at: 0.6)
        XCTAssertTrue(out.born.isEmpty, "suppression list blocks the ghost within suppressionWindow")
        XCTAssertTrue(out.reborn.isEmpty)
        XCTAssertEqual(store.counts, .init())
    }

    // MARK: - Face voting hysteresis (§3.2)

    /// A 40/60 7s↔8s flicker settles on the majority face with at most one
    /// published change (the initial 7s giving way to 8s once it leads by the
    /// margin — and never flipping back).
    func testMajorityFaceWinsWithAtMostOnePublishedChange() {
        let store = TrackStore()
        let b = box(0.5, 0.5)
        // 6× 7s, 9× 8s; deliberately open on the minority face to force the
        // single legitimate switch.
        let faces: [Tile] = [.s(7)]
            + Array(repeating: .s(8), count: 5)
            + Array(repeating: .s(7), count: 5)
            + Array(repeating: .s(8), count: 4)

        var published: [Tile] = []
        for (i, face) in faces.enumerated() {
            store.associate([det(face, 0.9, b)], at: Double(i) * 0.2)
            published.append(store.track(id0)!.face)
        }

        let changes = zip(published, published.dropFirst()).filter { $0 != $1 }.count
        XCTAssertLessThanOrEqual(changes, 1, "hysteresis permits only the one majority takeover")
        XCTAssertEqual(store.track(id0)?.face, .s(8), "settles on the 60% face")
    }

    /// A perfect 50/50 flicker never accrues the margin, so the incumbent face
    /// is held forever — zero churn in the published state or histogram.
    func testFiftyFiftyFlickerHoldsIncumbentByHysteresis() {
        let store = TrackStore()
        let b = box(0.5, 0.5)
        let faces: [Tile] = (0..<7).flatMap { _ in [Tile.s(7), Tile.s(8)] } + [.s(7)]  // 8×7s, 7×8s

        var published: [Tile] = []
        for (i, face) in faces.enumerated() {
            store.associate([det(face, 0.9, b)], at: Double(i) * 0.2)
            published.append(store.track(id0)!.face)
        }
        let changes = zip(published, published.dropFirst()).filter { $0 != $1 }.count
        XCTAssertEqual(changes, 0, "no challenger ever leads by voteHysteresisMargin")
        XCTAssertEqual(store.track(id0)?.face, .s(7), "incumbent (first-seen) face is held")
    }

    func testFaceConfidenceFallsBelowFloorUnderHeavyFlicker() {
        let store = TrackStore()
        let b = box(0.5, 0.5)
        // Near-even split → winner share hovers ~0.5, below faceConfidenceFloor.
        for i in 0..<10 {
            let face: Tile = i.isMultiple(of: 2) ? .s(7) : .s(8)
            store.associate([det(face, 0.9, b)], at: Double(i) * 0.2)
        }
        XCTAssertLessThan(store.track(id0)!.faceConfidence, TrackerConfig().faceConfidenceFloor,
                          "an even vote split reads as uncertain to the UI")
    }

    // MARK: - Pins win forever (§3.2, §5)

    func testPinSurvivesContradictingObservationsThenRebirth() {
        let store = liveSingle(.s(8))
        store.pin(id0, as: .s(8))

        // Bombard it with the contradicting lookalike; the pin never yields.
        let b = box(0.5, 0.5)
        for i in 0..<5 {
            store.associate([det(.s(7), 0.9, b)], at: 0.6 + Double(i) * 0.2)
            XCTAssertEqual(store.track(id0)?.face, .s(8), "pinned face outvotes every contradiction")
            XCTAssertTrue(store.track(id0)!.isPinned)
            XCTAssertEqual(store.track(id0)!.faceConfidence, 1.0)
        }

        // Nudge it out of the gate and back: rebirth reuses the object, so the
        // pin rides through missing → resurrection intact.
        let out = store.associate([det(.s(8), 0.9, box(0.5 + 0.10, 0.5))], at: 2.0)
        XCTAssertEqual(out.reborn, [id0])
        XCTAssertEqual(store.track(id0)?.face, .s(8))
        XCTAssertTrue(store.track(id0)!.isPinned, "pin survives rebirth")
        XCTAssertNil(store.track(id1))
    }

    // MARK: - Stable identity under jitter (§9.1)

    func testStableIDsAcrossManyJitteredFrames() {
        var game = ScriptedGame(seed: 20_240_716)
        game.deal(myHand: [.m(1), .m(2), .m(3), .p(4), .p(5), .p(6),
                           .s(7), .s(8), .s(9), .east, .east, .east, .whiteDragon])
        game.discard(.right, .m(9), at: 1.0)
        // Jitter is the stressor under test; dropout is exercised elsewhere, so
        // it's off here to keep the "no proliferation" bound exact.
        let noise = NoiseModel(boxJitter: 0.15, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0.05)
        let frames = game.frames(fps: 16, noise: noise)
        XCTAssertGreaterThanOrEqual(frames.count, 50, "need a long jittered run")

        let store = TrackStore()
        var everLive = Set<TrackID>()
        for f in frames {
            store.associate(f.tiles, at: f.t, motion: f.motion)
            for tr in store.tracks where tr.state == .live { everLive.insert(tr.id) }
        }

        XCTAssertEqual(everLive.count, 14, "13 hand + 1 discard = 14 identities, and never more")
        XCTAssertEqual(store.tracks.filter { $0.state == .live }.count, 14, "all present at the end")
    }

    // MARK: - Determinism (hard rule)

    func testIdenticalStreamsProduceIdenticalTrackSets() {
        var game = ScriptedGame(seed: 987_654)
        game.deal(myHand: [.m(1), .m(2), .m(3), .p(4), .p(5), .p(6),
                           .s(7), .s(8), .s(9), .east, .east, .east, .whiteDragon])
        game.discard(.right, .m(9), at: 1.0)
        game.discard(.across, .p(1), at: 2.5)
        game.myDraw(.whiteDragon, at: 4.0)
        game.myDiscard(.m(1), at: 5.0)
        game.nudge(.pond, index: 0, by: 0.06, at: 6.0)
        game.occlude(fraction: 0.4, from: 6.5, duration: 2.0)
        let frames = game.frames()   // full default noise: dropout, flicker, jitter

        let a = TrackStore(), b = TrackStore()
        for f in frames {
            a.associate(f.tiles, at: f.t, motion: f.motion)
            b.associate(f.tiles, at: f.t, motion: f.motion)
            XCTAssertEqual(a.tracks, b.tracks, "byte-identical input must yield byte-identical tracks")
        }
    }

    // MARK: - Corrections plumbing (facade support)

    func testInsertManualTrackIsLivePinnedAndSurvivesMisses() {
        let store = TrackStore()
        let id = store.insertManualTrack(face: .redDragon, zone: .pond, seat: .across,
                                         box: box(0.4, 0.4), at: 0.0)
        XCTAssertEqual(store.track(id)?.state, .live)
        XCTAssertTrue(store.track(id)!.isManual)
        XCTAssertTrue(store.track(id)!.isPinned)
        XCTAssertEqual(store.track(id)?.zone, .pond)

        for i in 0..<20 { store.associate([], at: 1.0 + Double(i)) }   // long unseen stretch
        XCTAssertEqual(store.track(id)?.state, .live, "manual tracks are never auto-retired by misses")
    }

    func testResetClearsTracksButKeepsIDsMonotonicAcrossHands() {
        let store = liveSingle(.m(1))
        XCTAssertNotNil(store.track(id0))

        store.reset()
        XCTAssertTrue(store.tracks.isEmpty)
        XCTAssertEqual(store.counts, .init())

        // A new hand's first tile must not recycle raw 0 — ids are unique for
        // the whole session so cross-hand event links can never collide.
        _ = store.associate([det(.p(1), 0.9, box(0.5, 0.5))], at: 10.0)
        XCTAssertNil(store.track(id0), "the pre-reset id is gone for good")
        XCTAssertNotNil(store.track(id1), "post-reset birth mints the next id, not a recycled one")
    }

    func testSetZoneWritesZoneAndSeatOntoTheTrack() {
        let store = liveSingle(.m(1))
        store.setZone(id0, to: .pond, seat: .across, locked: true)
        XCTAssertEqual(store.track(id0)?.zone, .pond)
        XCTAssertEqual(store.track(id0)?.seat, .across)
    }

    // MARK: - visibleRegion gating (Lane B chunk E — ROI-cropped AR ingest)

    /// A track OUTSIDE `visibleRegion` must never accrue a miss — it stays
    /// `.live` forever, well past both `missingGraceSettled` and
    /// `retiredRetention`, as long as every ingest keeps excluding it.
    func testOutOfRegionTrackNeverRetiresAcrossManyTicks() {
        let store = liveSingle(.m(1))   // track at box(0.5, 0.5)
        let farRegion = TileBoundingBox(x: 0.0, y: 0.0, width: 0.15, height: 0.15)   // nowhere near (0.5, 0.5)
        XCTAssertEqual(store.track(id0)?.state, .live)

        for i in 0..<20 {
            _ = store.associate([], at: 1.0 + Double(i), visibleRegion: farRegion)
        }
        XCTAssertEqual(store.track(id0)?.state, .live, "a track never covered by visibleRegion must never miss/retire")
        XCTAssertEqual(store.counts.retired, 0)
    }

    /// A track INSIDE `visibleRegion` retires on exactly the same schedule as
    /// a full-view ingest — the gate only protects tracks OUTSIDE the region,
    /// never masks genuine misses within it.
    func testInRegionMissingTrackStillRetiresNormally() {
        let store = liveSingle()   // track at box(0.5, 0.5)
        let coveringRegion = TileBoundingBox(x: 0.3, y: 0.3, width: 0.4, height: 0.4)   // contains (0.5, 0.5)
        XCTAssertEqual(store.track(id0)?.state, .live)

        _ = store.associate([], at: 1.0, visibleRegion: coveringRegion)
        XCTAssertEqual(store.track(id0)?.state, .missing, "missed inside a region that covers it")

        _ = store.associate([], at: 2.5, visibleRegion: coveringRegion)   // 1.5s < missingGraceSettled(2.0)
        XCTAssertEqual(store.track(id0)?.state, .missing)

        _ = store.associate([], at: 3.1, visibleRegion: coveringRegion)   // 2.1s > 2.0 → retired
        XCTAssertNil(store.track(id0), "an in-region missing track retires exactly like a full-view one")
        XCTAssertEqual(store.counts.retired, 1)
    }

    /// Default `visibleRegion == nil` re-runs `testMissingGraceRetiresAfterSettledWindowWhenCalm`'s
    /// exact schedule with the parameter simply omitted — the negative
    /// control proving existing call sites (harness, image-space loop) are
    /// byte-identical to before this parameter existed.
    func testDefaultVisibleRegionNilPreservesExistingMissingRetirementBehavior() {
        let store = liveSingle()
        XCTAssertEqual(store.track(id0)?.state, .live)

        _ = store.associate([], at: 1.0)
        XCTAssertEqual(store.track(id0)?.state, .missing)

        _ = store.associate([], at: 2.5)
        XCTAssertEqual(store.track(id0)?.state, .missing)

        _ = store.associate([], at: 3.1)
        XCTAssertNil(store.track(id0), "unchanged: a calm missing track retires after the settled grace")
        XCTAssertEqual(store.counts.retired, 1)
    }

    /// The facade forwards `visibleRegion` all the way through
    /// `TableTracker.ingest` to `TrackStore.associate` — a thin integration
    /// check on top of the `TrackStore`-level tests above.
    func testTableTrackerIngestForwardsVisibleRegionToTrackStore() {
        var config = TrackerConfig()
        config.winPredicate = { _, _ in false }
        let tracker = TableTracker(config: config)
        tracker.beginSession(mySeatWind: .east, roundWind: .east, at: 0.0)

        let farBox = box(0.2, 0.2)
        for i in 0..<3 {
            tracker.ingest([det(.m(1), 0.9, farBox)], at: Double(i) * 0.2, motion: nil)
        }
        XCTAssertEqual(tracker.diagnostics.live, 1, "3 confident hits confirm the track live")

        let farRegion = TileBoundingBox(x: 0.7, y: 0.7, width: 0.2, height: 0.2)   // excludes farBox
        for i in 0..<20 {
            tracker.ingest([], at: 1.0 + Double(i), visibleRegion: farRegion)
        }
        XCTAssertEqual(tracker.diagnostics.live, 1, "the facade's visibleRegion reaches TrackStore — an out-of-region track never retires")
        XCTAssertEqual(tracker.diagnostics.retired, 0)
    }
}

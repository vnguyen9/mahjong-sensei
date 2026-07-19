import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Chunk-4 coverage: `ZoneModel` — parser-on-settled-frames zone voting,
/// static-camera calibration (hand band + pond Gaussian), table subdivision
/// into pond/opponentMeld, hysteresis, and locked-zone respect (the tracker
/// plan's §3.3 and the ZoneModel subset of its §9 test list).
///
/// Two styles, deliberately: `ScriptedGame` streams driven through
/// `TrackerHarness` for the emergent "a whole deal zones correctly" and
/// determinism properties, and hand-built settled frames where the point is a
/// precise threshold (a controlled parser flip, the hysteresis margin, a lock)
/// that realistic noise would only blur.
final class ZoneModelTests: XCTestCase {

    // MARK: - Fixtures

    private func box(_ cx: Double, _ cy: Double, w: Double, h: Double) -> TileBoundingBox {
        TileBoundingBox(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func det(_ tile: Tile, _ box: TileBoundingBox, _ conf: Double = 0.9) -> DetectedTile {
        DetectedTile(tile: tile, confidence: conf, box: box)
    }

    /// One settled ingest with no motion (association treats a nil motion frame
    /// as calm) — the direct-drive equivalent of one `TrackerHarness` settle.
    private func ingest(_ dets: [DetectedTile], _ store: TrackStore, _ zone: ZoneModel, at t: TimeInterval) {
        let outcome = store.associate(dets, at: t)
        zone.ingestSettled(detections: dets, outcome: outcome, store: store, at: t)
    }

    private func dealHand() -> [Tile] {
        [.m(1), .m(2), .m(3), .m(4), .m(5), .p(2), .p(3), .p(4), .s(6), .s(7), .s(8), .east, .west]
    }

    // MARK: - Convergence on a scripted deal (§9.8/§9.9)

    func testZonesConvergeOnScriptedDeal() {
        var game = ScriptedGame(seed: 4_040)
        game.deal(myHand: dealHand())
        game.discard(.right, .m(9), at: 1.0)
        game.discard(.across, .p(1), at: 2.5)
        game.claim(.pung, by: .left, tiles: [.s(5), .s(5), .s(5)], at: 4.0)   // s5 not in pond → pure add
        let harness = TrackerHarness()
        harness.run(game.frames())

        let tracks = harness.store.tracks
        // My rank → myHand.
        let myHand = tracks.filter { $0.zone == .myHand }.map(\.face)
        for face in dealHand() { XCTAssertTrue(myHand.contains(face), "\(face) should be myHand, zones=\(zoneSummary(tracks))") }

        // Discards → pond.
        XCTAssertTrue(tracks.contains { $0.zone == .pond && $0.face == .m(9) }, "m9 should be pond")
        XCTAssertTrue(tracks.contains { $0.zone == .pond && $0.face == .p(1) }, "p1 should be pond")

        // The side run → opponentMeld owned by .left.
        let meld = tracks.filter { $0.zone == .opponentMeld }
        XCTAssertEqual(meld.count, 3, "the 3 s5 tiles form one opponent meld, zones=\(zoneSummary(tracks))")
        XCTAssertTrue(meld.allSatisfy { $0.face == .s(5) && $0.seat == .left }, "owned by .left")

        // Calibration locked from the settled rank frames.
        XCTAssertTrue(harness.zoneModel.isBandCalibrated, "hand band should lock from the deal")
        XCTAssertNotNil(harness.zoneModel.pondCentroid, "pond centroid should exist once discards fold in")
    }

    // MARK: - Opponent-meld subdivision by edge (§9.10)

    func testOpponentPungClusterAtRightEdgeIsOwnedByRight() {
        let store = TrackStore(), zone = ZoneModel()
        // Three same-face tiles hugging the right edge, no rank in frame — the
        // parser lumps them into `table`; ZoneModel must split them out.
        let boxes = [box(0.94, 0.44, w: 0.047, h: 0.075),
                     box(0.94, 0.50, w: 0.047, h: 0.075),
                     box(0.94, 0.56, w: 0.047, h: 0.075)]
        for i in 0..<6 { ingest(boxes.map { det(.whiteDragon, $0) }, store, zone, at: Double(i) * 0.2) }

        let meld = store.tracks.filter { $0.zone == .opponentMeld }
        XCTAssertEqual(meld.count, 3, "cluster at the right edge is an opponent meld, not pond")
        XCTAssertTrue(meld.allSatisfy { $0.seat == .right }, "owner read off displacement = .right")
    }

    // MARK: - Hysteresis (§9.11)

    func testTwoBadFramesDoNotFlipEstablishedPondTile() {
        let store = TrackStore(), zone = ZoneModel()
        let target = box(0.90, 0.50, w: 0.047, h: 0.075)   // lone tile → pond, near the edge

        for i in 0..<7 { ingest([det(.s(5), target)], store, zone, at: Double(i) * 0.2) }
        XCTAssertEqual(store.track(TrackID(raw: 0))?.zone, .pond, "a lone tile settles as pond")

        // Two "bad" frames: two same-face neighbors appear, making a 3-cluster
        // at the edge that the subdivision reads as opponentMeld — the target's
        // vote flips for two frames.
        let bad = [det(.s(5), box(0.84, 0.50, w: 0.047, h: 0.075)),
                   det(.s(5), target),
                   det(.s(5), box(0.96, 0.50, w: 0.047, h: 0.075))]
        ingest(bad, store, zone, at: 1.6)
        ingest(bad, store, zone, at: 1.8)
        XCTAssertEqual(store.track(TrackID(raw: 0))?.zone, .pond,
                       "two contradicting frames never overcome an established zone")
    }

    func testSustainedContradictionEventuallySwitchesZone() {
        let store = TrackStore(), zone = ZoneModel()
        // Establish the middle tile (raw 1) as opponentMeld inside an edge pung.
        let cluster = [det(.s(5), box(0.84, 0.50, w: 0.047, h: 0.075)),
                       det(.s(5), box(0.90, 0.50, w: 0.047, h: 0.075)),
                       det(.s(5), box(0.96, 0.50, w: 0.047, h: 0.075))]
        for i in 0..<4 { ingest(cluster, store, zone, at: Double(i) * 0.2) }
        let target = TrackID(raw: 1)
        XCTAssertEqual(store.track(target)?.zone, .opponentMeld)

        // Its neighbors vanish; now it's a lone tile → a sustained run of pond
        // votes. Past the window + margin it flips — hysteresis is a margin,
        // not a permanent lock.
        for i in 0..<8 { ingest([det(.s(5), box(0.90, 0.50, w: 0.047, h: 0.075))], store, zone, at: 1.0 + Double(i) * 0.2) }
        XCTAssertEqual(store.track(target)?.zone, .pond,
                       "a sustained contradiction crosses the switch margin")
    }

    // MARK: - Locked zones are never re-voted (§5 / plan test)

    func testLockedZoneSurvivesContradictingVotes() {
        let store = TrackStore(), zone = ZoneModel()
        let target = box(0.50, 0.50, w: 0.047, h: 0.075)
        for i in 0..<5 { ingest([det(.p(1), target)], store, zone, at: Double(i) * 0.2) }
        let id = TrackID(raw: 0)
        XCTAssertEqual(store.track(id)?.zone, .pond)

        // User override → lock. ZoneModel must stop voting it.
        store.setZone(id, to: .myMeld, seat: nil, locked: true)
        zone.markLocked(id)

        for i in 0..<6 { ingest([det(.p(1), target)], store, zone, at: 1.2 + Double(i) * 0.2) }
        XCTAssertEqual(store.track(id)?.zone, .myMeld, "a locked zone is never re-voted back to pond")
    }

    // MARK: - Stability under realistic parser flicker + determinism

    func testPondTilesStayPondUnderNoisyStream() {
        var game = ScriptedGame(seed: 7_777)
        game.deal(myHand: dealHand())
        game.discard(.right, .m(9), at: 1.0)
        game.discard(.across, .p(1), at: 2.5)
        game.discard(.left, .s(1), at: 4.0)
        let harness = TrackerHarness()
        harness.run(game.frames())   // full default noise (dropout/jitter/flicker)

        for face in [Tile.m(9), .p(1), .s(1)] {
            let zones = harness.store.tracks.filter { $0.face == face }.map(\.zone)
            XCTAssertTrue(zones.contains(.pond) && !zones.contains(.opponentMeld),
                          "\(face) stays pond under noise, got \(zones)")
        }
    }

    func testDeterministicZonesForSameSeed() {
        func zonesFor(seed: UInt64) -> [String] {
            var game = ScriptedGame(seed: seed)
            game.deal(myHand: dealHand())
            game.discard(.right, .m(9), at: 1.0)
            game.claim(.pung, by: .across, tiles: [.s(5), .s(5), .s(5)], at: 3.0)
            let harness = TrackerHarness()
            harness.run(game.frames())
            return harness.store.tracks.sorted { $0.id < $1.id }.map { "\($0.id.raw):\($0.zone.rawValue):\($0.seat.map { "\($0.rawValue)" } ?? "-")" }
        }
        XCTAssertEqual(zonesFor(seed: 555), zonesFor(seed: 555), "same seed → identical zone assignment")
    }

    // MARK: - Zoner single-row hand rescue (A4)

    /// `TableSceneParser.handClusterIndex` gates a "hand" candidate on
    /// `sceneConfig.minHandCount` (default 4) *and* `minHandTileHeight`
    /// (default 0.055). `handRescueMinTiles` (8, default) is already
    /// *stricter* than the default `minHandCount`, so under default config any
    /// cluster big enough to earn the rescue would already have satisfied the
    /// parser's own (weaker) count gate — the parser would never have missed
    /// it in the first place. To reproduce a genuine "parser misses the rank
    /// this frame" scenario (the observed rank→POND bug the interim fix
    /// targets) while still leaving a cluster big enough for the rescue,
    /// these tests raise `sceneConfig.minHandCount` — the parser's own,
    /// independent knob — past what any real rank can reach, leaving
    /// `handRescueMinTiles` at its own, separate default untouched.
    private func rescueTestConfig() -> TrackerConfig {
        var config = TrackerConfig()
        config.sceneConfig.minHandCount = 20   // no cluster in these tests can ever satisfy handClusterIndex
        return config
    }

    func testSingleRowRankRescuesToMyHandWhenParserMissesItThisFrame() {
        let config = rescueTestConfig()
        let store = TrackStore(config: config), zone = ZoneModel(config: config)

        // 13 rank-scale tiles in one bottom-band row — a real concealed hand,
        // arranged so `handClusterIndex` (count ≥ 20, per `rescueTestConfig`)
        // misses it every frame, exactly like the old unconditional-pond
        // default would have pond-locked it.
        let rank = dealHand().enumerated().map { i, tile in
            det(tile, box(0.10 + Double(i) * 0.065, 0.85, w: 0.05, h: 0.08))
        }
        XCTAssertEqual(rank.count, 13)

        for i in 0..<8 { ingest(rank, store, zone, at: Double(i) * 0.2) }

        let tracks = store.tracks
        XCTAssertEqual(tracks.count, 13)
        XCTAssertTrue(tracks.allSatisfy { $0.zone == .myHand },
                      "a genuine single-row rank the parser missed this frame must rescue to myHand, " +
                      "not pond-lock: \(zoneSummary(tracks))")
    }

    func testMultiRowTableBlobStaysPondEvenWhenParserMissesTheHand() {
        let config = rescueTestConfig()
        let store = TrackStore(config: config), zone = ZoneModel(config: config)

        // Two stacked rows of rank-scale tiles (14 total — comparable size to
        // the single-row case above), bridged into one physical cluster but
        // spanning two lines. `handClusterIndex` still misses it (same
        // `rescueTestConfig`), but the rescue's own single-line requirement
        // must reject it — a stacked blob is table content, never a
        // concealed rank.
        let faces = dealHand() + [.north]
        XCTAssertEqual(faces.count, 14)
        let row1 = faces.prefix(7).enumerated().map { i, tile in
            det(tile, box(0.10 + Double(i) * 0.065, 0.80, w: 0.05, h: 0.08))
        }
        let row2 = faces.suffix(7).enumerated().map { i, tile in
            det(tile, box(0.10 + Double(i) * 0.065, 0.90, w: 0.05, h: 0.08))
        }
        let blob = row1 + row2

        for i in 0..<8 { ingest(blob, store, zone, at: Double(i) * 0.2) }

        let tracks = store.tracks
        XCTAssertEqual(tracks.count, 14)
        XCTAssertTrue(tracks.allSatisfy { $0.zone == .pond },
                      "a two-row blob must stay pond even on a parser-missed frame: \(zoneSummary(tracks))")
    }

    func testSmallTableClusterBelowRescueFloorStaysPond() {
        // A lone 3-tile, non-meld cluster in the bottom band — well under
        // `handRescueMinTiles` (8) — must never be mistaken for a missed
        // hand, even though the parser also finds no hand at all this frame
        // (3 < the *default* minHandCount(4) too, so no config override is
        // needed here).
        let store = TrackStore(), zone = ZoneModel()
        let small = [det(.m(1), box(0.20, 0.85, w: 0.05, h: 0.08)),
                    det(.p(5), box(0.29, 0.85, w: 0.05, h: 0.08)),
                    det(.s(9), box(0.38, 0.85, w: 0.05, h: 0.08))]

        for i in 0..<7 { ingest(small, store, zone, at: Double(i) * 0.2) }

        let tracks = store.tracks
        XCTAssertEqual(tracks.count, 3)
        XCTAssertTrue(tracks.allSatisfy { $0.zone == .pond },
                      "a cluster below handRescueMinTiles must stay pond: \(zoneSummary(tracks))")
    }

    func testRescueDoesNotApplyToTableClustersWhenTheParserFoundAValidHand() {
        // Default config: the primary 13-tile row is a real, parser-findable
        // hand (highest score — closest to the bottom). A second, separate
        // 8-tile row sits higher up (still inside the rescue's own y/height/
        // single-line criteria, so it *would* rescue on a miss-frame) but the
        // parser finds a valid `mine` this frame — the rescue must stay
        // inactive for every other table cluster, so the second row falls
        // through to the ordinary pond default.
        let store = TrackStore(), zone = ZoneModel()

        let primary = dealHand().enumerated().map { i, tile in
            det(tile, box(0.10 + Double(i) * 0.065, 0.90, w: 0.05, h: 0.08))
        }
        // Disjoint from `dealHand()`'s faces (m1–5, p2–4, s6–8, E, W) so
        // filtering tracks by face below can't conflate the two clusters.
        let secondaryFaces: [Tile] = [.m(6), .m(7), .m(8), .p(6), .p(7), .p(8), .s(1), .s(2)]
        let secondary = secondaryFaces.enumerated().map { i, tile in
            det(tile, box(0.10 + Double(i) * 0.065, 0.60, w: 0.05, h: 0.08))
        }

        for i in 0..<8 { ingest(primary + secondary, store, zone, at: Double(i) * 0.2) }

        let tracks = store.tracks
        let primaryFaces = primary.map(\.tile)
        let myHand = tracks.filter { primaryFaces.contains($0.face) }
        let secondaryTracks = tracks.filter { secondaryFaces.contains($0.face) }
        XCTAssertEqual(myHand.count, 13)
        XCTAssertTrue(myHand.allSatisfy { $0.zone == .myHand },
                      "the real, parser-found hand must still resolve myHand: \(zoneSummary(tracks))")
        XCTAssertEqual(secondaryTracks.count, 8)
        XCTAssertTrue(secondaryTracks.allSatisfy { $0.zone == .pond },
                      "rescue must not fire on other table clusters once the parser found a valid hand: " +
                      "\(zoneSummary(tracks))")
    }

    // MARK: - Helper

    private func zoneSummary(_ tracks: [TrackedTile]) -> String {
        tracks.sorted { $0.id < $1.id }.map { "\($0.face)@\($0.zone.rawValue)" }.joined(separator: ",")
    }
}

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

    // MARK: - Helper

    private func zoneSummary(_ tracks: [TrackedTile]) -> String {
        tracks.sorted { $0.id < $1.id }.map { "\($0.face)@\($0.zone.rawValue)" }.joined(separator: ",")
    }
}

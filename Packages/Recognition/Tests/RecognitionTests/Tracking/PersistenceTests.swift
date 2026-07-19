import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Plan A6 coverage: `TrackerSnapshot` + `TableTracker.snapshot(at:)` /
/// `.restore(_:at:)` — the state-EXPORT persistence round trip that lets a
/// session survive a process relaunch. Proven against real `ScriptedGame`
/// streams (same pattern as `CorrectionTests`) so the snapshot captures
/// exactly what a live session would have, not a hand-built stub.
final class PersistenceTests: XCTestCase {

    private func dealHand() -> [Tile] {
        [.m(1), .m(2), .m(3), .m(4), .m(5), .p(2), .p(3), .p(4), .s(6), .s(7), .s(8), .east, .west]
    }

    /// Runs `frames` through a fresh, session-begun `TableTracker` — mirrors
    /// `CorrectionTests.run`.
    private func run(_ frames: [(t: TimeInterval, motion: MotionSample, tiles: [DetectedTile])],
                     mySeatWind: Wind = .east, roundWind: Wind = .east) -> TableTracker {
        let tracker = TableTracker()
        tracker.beginSession(mySeatWind: mySeatWind, roundWind: roundWind, at: 0)
        for f in frames { tracker.ingest(f.tiles, at: f.t, motion: f.motion) }
        return tracker
    }

    // MARK: - 1. Round trip preserves hand/pond/meld faces + winds + handIndex + ids

    func testSnapshotRestoreRoundTripPreservesStateAndIdentity() {
        var game = ScriptedGame(seed: 6_001)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        game.discard(.across, .p(9), at: 2.0)
        game.claim(.pung, by: .left, tiles: [.p(9), .p(9), .p(9)], at: 3.0)
        let tracker = run(game.frames(), mySeatWind: .south, roundWind: .east)

        XCTAssertFalse(tracker.state.myHand.isEmpty, "sanity: hand tiles tracked")
        XCTAssertFalse(tracker.state.pond.isEmpty, "sanity: pond tiles tracked")
        let originalMeldFaces = Set(tracker.state.opponentMelds.values.flatMap { $0.flatMap { $0 } }.map(\.face))
        XCTAssertFalse(originalMeldFaces.isEmpty, "sanity: an opponent meld was claimed")

        let snapshot = tracker.snapshot(at: 100)
        let restored = TableTracker()
        restored.restore(snapshot, at: 200)

        XCTAssertEqual(restored.state.mySeatWind, tracker.state.mySeatWind)
        XCTAssertEqual(restored.state.roundWind, tracker.state.roundWind)
        XCTAssertEqual(restored.state.handIndex, tracker.state.handIndex)

        XCTAssertEqual(Set(restored.state.myHand.map(\.id)), Set(tracker.state.myHand.map(\.id)))
        XCTAssertEqual(Set(restored.state.myHand.map(\.face)), Set(tracker.state.myHand.map(\.face)))
        XCTAssertEqual(Set(restored.state.pond.map(\.id)), Set(tracker.state.pond.map(\.id)))
        XCTAssertEqual(Set(restored.state.pond.map(\.face)), Set(tracker.state.pond.map(\.face)))

        let restoredMeldFaces = Set(restored.state.opponentMelds.values.flatMap { $0.flatMap { $0 } }.map(\.face))
        XCTAssertEqual(restoredMeldFaces, originalMeldFaces)
    }

    // MARK: - 2. Restored tracks are pinned + zone-locked

    func testRestoredTracksArePinnedAndZoneLockedAgainstContradictingIngest() {
        var game = ScriptedGame(seed: 6_002)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        let tracker = run(game.frames())

        guard let pondTrack = tracker.state.pond.first(where: { $0.face == .s(1) }) else {
            return XCTFail("expected an s1 in the pond")
        }
        let snapshot = tracker.snapshot(at: 50)
        let restored = TableTracker()
        restored.restore(snapshot, at: 60)

        XCTAssertEqual(restored.state.pond.first { $0.id == pondTrack.id }?.face, .s(1))

        // Bombard the same spot with contradicting detections after restore —
        // both the face pin and the zone lock must hold.
        for i in 0..<8 {
            let t = 61.0 + Double(i) * 0.9
            restored.ingest([DetectedTile(tile: .greenDragon, confidence: 0.9, box: pondTrack.box)],
                            at: t, motion: MotionSample(t: t, level: 0))
        }
        XCTAssertEqual(restored.state.pond.first { $0.id == pondTrack.id }?.face, .s(1),
                       "restored face is pinned — contradicting evidence never wins")
        XCTAssertTrue(restored.state.pond.contains { $0.id == pondTrack.id },
                     "restored zone is locked — the track never drifts out of the pond")
    }

    // MARK: - 3. Post-restore new tracks/events get ids strictly greater than restored max

    func testPostRestoreNewIdsAreStrictlyGreaterThanRestoredMax() {
        var game = ScriptedGame(seed: 6_003)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        let tracker = run(game.frames())
        let snapshot = tracker.snapshot(at: 50)

        let maxTileID = snapshot.tiles.map(\.id.raw).max() ?? -1
        let maxEventID = snapshot.events.map(\.id).max() ?? -1

        let restored = TableTracker()
        restored.restore(snapshot, at: 60)

        // A fresh discard after restore must mint both a new track and a new event.
        var game2 = ScriptedGame(seed: 6_004)
        game2.discard(.across, .p(1), at: 1.0)
        for f in game2.frames() {
            restored.ingest(f.tiles, at: 60 + f.t, motion: f.motion)
        }

        guard let newPondTrack = restored.state.pond.first(where: { $0.face == .p(1) }) else {
            return XCTFail("expected a fresh p1 discard to be tracked after restore")
        }
        XCTAssertGreaterThan(newPondTrack.id.raw, maxTileID, "a track born after restore never collides with a restored id")

        guard let newEvent = restored.events.last(where: {
            if case let .discard(_, tile, _) = $0.kind { return tile == .p(1) }
            return false
        }) else { return XCTFail("expected a discard event for the fresh p1") }
        XCTAssertGreaterThan(newEvent.id, maxEventID, "an event minted after restore never collides with a restored id")
    }

    // MARK: - 4. .unresolved excluded from snapshot

    func testUnresolvedTracksAreExcludedFromSnapshot() {
        let tracker = TableTracker()
        tracker.beginSession(mySeatWind: .east, roundWind: .east, at: 0)
        let unresolvedID = tracker.insertMissedTile(face: .greenDragon, zone: .unresolved, seat: nil, near: nil)
        XCTAssertTrue(tracker.state.unresolved.contains { $0.id == unresolvedID }, "sanity: the tile is unresolved")

        let snapshot = tracker.snapshot(at: 10)
        XCTAssertFalse(snapshot.tiles.contains { $0.id == unresolvedID }, "unresolved tracks never enter the snapshot")

        let restored = TableTracker()
        restored.restore(snapshot, at: 20)
        XCTAssertTrue(restored.state.unresolved.isEmpty, "nothing resurrects an excluded unresolved tile")
    }

    // MARK: - 5. A restored discard event's track reference still resolves

    func testRestoredDiscardEventTrackReferenceStillResolves() {
        var game = ScriptedGame(seed: 6_005)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        let tracker = run(game.frames())
        let snapshot = tracker.snapshot(at: 50)

        let restored = TableTracker()
        restored.restore(snapshot, at: 60)

        guard let discardEvent = restored.events.first(where: {
            if case .discard = $0.kind { return true }; return false
        }), case let .discard(_, _, trackID) = discardEvent.kind else {
            return XCTFail("expected a restored discard event")
        }

        restored.pin(track: trackID, as: .greenDragon)
        XCTAssertEqual(restored.state.pond.first { $0.id == trackID }?.face, .greenDragon,
                       "pin resolves against the restored track — not a silent no-op")
    }
}

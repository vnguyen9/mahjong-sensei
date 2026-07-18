import Foundation
import CoreGraphics
import MahjongCore
import Recognition

#if DEBUG
/// Scripted `CoachLiveSession` driver for MJ_SCREEN screenshots and the
/// Simulator's "mock-driven" Coach Live entry (no camera, no tracker — see
/// the type doc on `CoachLiveSession`).
///
/// Builds ONE consistent demo scenario straight from the mockup (UI plan
/// §15): tenpai after discarding 9筒, waiting on 1萬 (2 live) / 4萬 (3 live),
/// a 13-tile pond with the two newest discards ringed, East's revealed pung
/// of 中, West's revealed pung of 4筒, and one unresolved tile. Every count
/// below is hand-derived to reproduce the plan's exact numbers — 5 total
/// live outs, ~4.9% next-draw odds — through the REAL `CoachAdvisor` /
/// `EfficiencyEngine`, not hard-coded: `CoachLiveSession.recomputeAdvice()`
/// runs the placeholder advisor over this hand once seeded.
enum MockCoachLive {
    static func make(scene: String) -> CoachLiveSession {
        let session = CoachLiveSession(camera: CameraCapture())
        seedScenario(session)
        applyScene(scene, to: session)
        return session
    }

    // MARK: - Base scenario

    private static func seedScenario(_ session: CoachLiveSession) {
        // My seat: South. This makes RelativeSeat.left == East and .right ==
        // West (see `RelativeSeat.wind(mySeatWind:)`) — exactly the "East
        // pung of 中, West pung of 4筒" opponents the mockup shows at the
        // leading/trailing edges, with .across landing on North (the plan's
        // own "North · 13 · concealed" example chip).
        session.seatWind = .south
        session.roundWind = .east
        session.phase = .rest
        session.orientedImageSize = CGSize(width: 720, height: 1280)

        // 13 concealed + the 14th (drawn) tile: 2m3m ryanmen, 456p, 123s,
        // 55s pair, 789s, plus a dead 9p just drawn — discarding it locks in
        // tenpai on 1m/4m.
        let handFaces: [Tile] = [.m(2), .m(3), .p(4), .p(5), .p(6),
                                 .s(1), .s(2), .s(3), .s(5), .s(5), .s(7), .s(8), .s(9)]
        session.handTiles = handFaces.enumerated().map { i, face in
            TrackedTile(id: TrackID(raw: i + 1), face: face,
                       box: TileBoundingBox(x: 0.05 + Double(i) * 0.07, y: 0.86, width: 0.06, height: 0.1),
                       zone: .myHand, state: .live, firstSeen: 0, lastSeen: 0)
        }
        session.drawnTile = TrackedTile(id: TrackID(raw: 14), face: .p(9),
                                        box: TileBoundingBox(x: 0.92, y: 0.86, width: 0.06, height: 0.1),
                                        zone: .myHand, state: .live, firstSeen: 0, lastSeen: 0)
        session.myMelds = []

        // Opponents: East (left) pung of 中, West (right) pung of 4筒;
        // North (across) fully concealed.
        session.opponentMelds = [
            .left:  [Meld.pung(.redDragon)],
            .right: [Meld.pung(.p(4))],
        ]
        session.concealedCounts = [.across: 13, .left: 10, .right: 10]

        // Pond: 13 tiles; the two most recent discards (North's 9s, South's
        // 1m) are ringed. `seenHistogram` below is hand-derived from exactly
        // these tiles + the two opponent pungs.
        let pondFaces: [Tile] = [.m(1), .m(9), .p(7), .p(8), .p(5), .p(2), .p(3),
                                 .whiteDragon, .north, .m(4), .s(2)]
        session.pond = pondFaces.map { PondEntry(tile: $0) }
            + [PondEntry(tile: .s(9), isNewest: true), PondEntry(tile: .m(1), isNewest: true)]

        var seen = Array(repeating: 0, count: Tile.baseClassCount)
        for entry in session.pond { seen[entry.tile.classIndex] += 1 }
        for melds in session.opponentMelds.values {
            for meld in melds { for tile in meld.tiles { seen[tile.classIndex] += 1 } }
        }
        session.seenHistogram = seen
        session.seenTotal = seen.reduce(0, +)

        // No real loop runs on the mock path, so most `LiveDiagnostics`
        // counters stay accurately at 0 (there were no ticks) — but the
        // debug HUD (triple-tap the LIVE pill) should still read sensibly
        // for screenshot/dev use, so fill what a mock plausibly "knows".
        session.diagnostics.recognizerType = "MockRecognizer"

        // One unresolved tile — face unknown, sitting near the table's right
        // edge. Normalized ORIENTED-image coords chosen so the bracket lands
        // fully inside the feed at the rest split (see `zoneBoxes` note).
        session.unresolved = [
            UnresolvedTile(tile: nil, box: TileBoundingBox(x: 0.62, y: 0.30, width: 0.10, height: 0.12)),
        ]

        // Synthetic zone boxes (no camera on the Simulator) placed so all three
        // brackets are screenshot-able at the 54% rest split: POND high-center,
        // the unresolved tile at the right edge, and the YOURS hand-band near
        // the bottom of the visible feed (like the mockup). With a ~720×1280
        // oriented image aspect-filled into a portrait screen there's no
        // vertical crop, so normalized-y ≈ screen fraction — everything below
        // ~0.52 shows at rest, more as the feed breathes taller.
        session.zoneBoxes = ZoneBoxes(
            mine: [TileBoundingBox(x: 0.10, y: 0.45, width: 0.80, height: 0.07)],
            table: [TileBoundingBox(x: 0.20, y: 0.15, width: 0.58, height: 0.22)],
            unresolved: session.unresolved.map(\.box)
        )

        // Events, oldest → newest — the two revealed melds, the two ringed
        // pond discards (South's 一萬 flagged as reducing my wait), then my
        // own draw of the dead 9筒.
        let now = Date()
        session.events = [
            TableEvent(actor: .east, kind: .meld(.pung), tiles: [.redDragon, .redDragon, .redDragon],
                      date: now.addingTimeInterval(-140)),
            TableEvent(actor: .west, kind: .meld(.pung), tiles: [.p(4), .p(4), .p(4)],
                      date: now.addingTimeInterval(-95)),
            TableEvent(actor: .north, kind: .discard, tiles: [.s(9)],
                      date: now.addingTimeInterval(-52)),
            TableEvent(actor: .south, kind: .discard, tiles: [.m(1)],
                      date: now.addingTimeInterval(-26), waitDelta: -1),
            TableEvent(actor: .south, kind: .draw, tiles: [.p(9)],
                      date: now.addingTimeInterval(-8)),
        ]

        session.recomputeAdvice()
    }

    // MARK: - Per-scene overrides

    private static func applyScene(_ scene: String, to session: CoachLiveSession) {
        switch scene {
        case "coach-live-action", "coach-live-action-counts":
            // `-action-counts` also selects the Counts tab (RootView reads the
            // `counts` suffix) — verifies all four suit rows still fit at the
            // compressed 70% action split.
            session.phase = .action
        case "coach-live-think":
            session.phase = .thinking
        case "coach-live-handend":
            session.handBoundary = HandBoundaryPrediction(predictedRoundWind: .east,
                                                           predictedSeatWind: .west,
                                                           guessedWinner: .south)
        case "coach-live-win":
            session.winDetected = WinInfo(isSelfDraw: true, winningTile: .m(1))
        default:
            break   // "coach-live", "-counts", "-events", "-setup", "-corrections" reuse the base scenario
        }
    }
}
#endif

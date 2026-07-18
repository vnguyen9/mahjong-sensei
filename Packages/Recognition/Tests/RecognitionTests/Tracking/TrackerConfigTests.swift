import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Spot-checks `TrackerConfig`'s defaults against the tracker plan's §7
/// table, plus basic sanity for the other chunk-1 data types
/// (`TrackingModels.swift`): `RelativeSeat` turn order/wind math, `TrackID`
/// identity, and `GameEvent`/`TrackedTableState` shape. Not exhaustive — the
/// algorithms that give these values meaning (TrackStore/ZoneModel/
/// TurnEngine/HandBoundaryDetector) are later chunks with their own tests.
final class TrackerConfigTests: XCTestCase {

    // MARK: - §7 defaults spot-check

    func testAssociationDefaults() {
        let c = TrackerConfig()
        XCTAssertEqual(c.highConfidence, 0.50)
        XCTAssertEqual(c.birthConfidence, 0.45)
        XCTAssertEqual(c.lowBandVoteWeight, 0.5)
        XCTAssertEqual(c.iouGate, 0.30)
        XCTAssertEqual(c.centerGateFactor, 0.75)
        XCTAssertEqual(c.confirmFrames, 3)
        XCTAssertEqual(c.confirmWindow, 5)
    }

    func testFaceVotingDefaults() {
        let c = TrackerConfig()
        XCTAssertEqual(c.voteWindow, 15)
        XCTAssertEqual(c.voteHysteresisMargin, 2.0)
        XCTAssertEqual(c.faceConfidenceFloor, 0.6)
    }

    func testLifecycleAndRebirthDefaults() {
        let c = TrackerConfig()
        XCTAssertEqual(c.missingGraceSettled, 2.0)
        XCTAssertEqual(c.missingGraceMotion, 6.0)
        XCTAssertEqual(c.motionCooldown, 3.0)
        XCTAssertEqual(c.retiredRetention, 10.0)
        XCTAssertEqual(c.rebirthRadius, 2.5)
        XCTAssertEqual(c.rebirthWindow, 10.0)
    }

    func testSettleDiffDefaults() {
        let c = TrackerConfig()
        XCTAssertEqual(c.settleDelay, 0.7)
        XCTAssertEqual(c.motionActive, 0.045)
        XCTAssertEqual(c.motionSettle, 0.02)
        XCTAssertEqual(c.handCountSustain, 1.2)
    }

    func testZoneDefaults() {
        let c = TrackerConfig()
        XCTAssertEqual(c.zoneVoteWindow, 9)
        XCTAssertEqual(c.zoneSwitchMargin, 3)
        XCTAssertEqual(c.calibrationFrames, 5)
        XCTAssertEqual(c.pondCoreSigma, 2.0)
    }

    func testAttributionDefaults() {
        let c = TrackerConfig()
        XCTAssertEqual(c.attributionPriorWeight, 2.0)
        XCTAssertEqual(c.attributionMotionWeight, 1.0)
        XCTAssertEqual(c.attributionGeometryWeight, 0.5)
        XCTAssertEqual(c.attributionConfidenceFloor, 0.55)
        XCTAssertEqual(c.resyncMargin, 1.5)
    }

    func testHandBoundaryDefaults() {
        let c = TrackerConfig()
        XCTAssertEqual(c.handClearFraction, 0.6)
        XCTAssertEqual(c.handClearMinTiles, 8)
        XCTAssertEqual(c.handClearSustain, 5.0)
        XCTAssertEqual(c.reappearFraction, 0.5)
        XCTAssertEqual(c.reappearWindow, 8.0)
    }

    func testBookkeepingDefaults() {
        let c = TrackerConfig()
        XCTAssertEqual(c.boxHistoryCap, 12)
        XCTAssertEqual(c.suppressionWindow, 5.0)
    }

    func testWinPredicateDefaultsNilAndIsInjectable() {
        var c = TrackerConfig()
        XCTAssertNil(c.winPredicate)
        c.winPredicate = { tiles, melds in tiles.isEmpty && melds.isEmpty }
        XCTAssertNotNil(c.winPredicate)
        XCTAssertTrue(c.winPredicate!([], []))
        XCTAssertFalse(c.winPredicate!([.m(1)], []))
    }

    func testSceneConfigDefaultsToTableSceneParserDefaults() {
        let c = TrackerConfig()
        XCTAssertEqual(c.sceneConfig.minHandTileHeight, TableSceneParser.Config().minHandTileHeight)
        XCTAssertEqual(c.sceneConfig.minHandCount, TableSceneParser.Config().minHandCount)
    }

    /// `TrackerConfig` fields are `var`s on a value type — overriding one for
    /// a harness/test run must not perturb any other default.
    func testFieldsAreIndependentlyOverridable() {
        var c = TrackerConfig()
        c.motionActive = 0.09
        XCTAssertEqual(c.motionActive, 0.09)
        XCTAssertEqual(c.motionSettle, 0.02, "overriding one field mutated another")
        XCTAssertEqual(c.highConfidence, 0.50, "overriding one field mutated another")
    }

    // MARK: - RelativeSeat (§2.1)

    func testTurnOrderCyclesMeRightAcrossLeft() {
        XCTAssertEqual(RelativeSeat.me.next, .right)
        XCTAssertEqual(RelativeSeat.right.next, .across)
        XCTAssertEqual(RelativeSeat.across.next, .left)
        XCTAssertEqual(RelativeSeat.left.next, .me)
    }

    func testSeatWindFormula() {
        // My seat is East: right = South, across = West, left = North.
        XCTAssertEqual(RelativeSeat.me.wind(mySeatWind: .east), .east)
        XCTAssertEqual(RelativeSeat.right.wind(mySeatWind: .east), .south)
        XCTAssertEqual(RelativeSeat.across.wind(mySeatWind: .east), .west)
        XCTAssertEqual(RelativeSeat.left.wind(mySeatWind: .east), .north)
        // Rotate my seat wind to South: right becomes West, wrap-around holds.
        XCTAssertEqual(RelativeSeat.right.wind(mySeatWind: .south), .west)
        XCTAssertEqual(RelativeSeat.left.wind(mySeatWind: .south), .east)
    }

    // MARK: - TrackID (§2.1)

    func testTrackIDEqualityOrderingAndCodable() throws {
        XCTAssertEqual(TrackID(raw: 3), TrackID(raw: 3))
        XCTAssertNotEqual(TrackID(raw: 3), TrackID(raw: 4))
        XCTAssertLessThan(TrackID(raw: 1), TrackID(raw: 2))
        let decoded = try JSONDecoder().decode(TrackID.self, from: JSONEncoder().encode(TrackID(raw: 17)))
        XCTAssertEqual(decoded, TrackID(raw: 17))
    }

    // MARK: - GameEvent (§2.4)

    func testGameEventCodableRoundTripPreservesKindAndFlags() throws {
        let event = GameEvent(id: 5, at: 12.5, handIndex: 0,
                              kind: .discard(seat: .right, tile: .m(9), track: TrackID(raw: 2)),
                              confidence: 0.82, flags: [.uncertainAttribution])
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(GameEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.kind, .discard(seat: .right, tile: .m(9), track: TrackID(raw: 2)))
        XCTAssertEqual(decoded.flags, [.uncertainAttribution])
    }

    func testGameEventFlagsSetDeduplicates() {
        let event = GameEvent(id: 1, at: 0, handIndex: 0, kind: .myHandComplete,
                              confidence: 1.0, flags: [.amended, .amended])
        XCTAssertEqual(event.flags.count, 1)
    }

    // MARK: - TrackedTableState (§2.3)

    func testEmptyTableStateDefaults() {
        let s = TrackedTableState.empty
        XCTAssertEqual(s.revision, 0)
        XCTAssertEqual(s.phase, .calibrating)
        XCTAssertEqual(s.handIndex, 0)
        XCTAssertTrue(s.myHand.isEmpty)
        XCTAssertTrue(s.pond.isEmpty)
        XCTAssertEqual(s.seenHistogram.count, Tile.baseClassCount)
        XCTAssertTrue(s.seenHistogram.allSatisfy { $0 == 0 })
        XCTAssertFalse(s.isMyHandComplete)
    }

    // MARK: - HandEndProposal (§2.5)

    func testHandEndProposalCarriesOptionalPredictedWinds() {
        let noPrediction = HandEndProposal(at: 10, missingFraction: 0.7)
        XCTAssertNil(noPrediction.predictedWinds)
        let predicted = HandEndProposal(at: 10, missingFraction: 0.7,
                                        predictedWinds: .init(mySeatWind: .south, roundWind: .east))
        XCTAssertEqual(predicted.predictedWinds?.mySeatWind, .south)
    }
}

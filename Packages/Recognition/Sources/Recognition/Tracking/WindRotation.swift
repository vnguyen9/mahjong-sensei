import Foundation
import MahjongCore

/// Predicts the next hand's seat/round winds from how this hand ended — the
/// HK Old Style dealer-rotation rule the tracker plan's §3.6 names: the
/// dealer repeats the deal on a dealer win *or* an exhaustive draw; any other
/// win passes the deal to the next seat in turn order (`RelativeSeat.next`,
/// which — per `RelativeSeat`'s own doc — walks E→S→W→N); the round wind only
/// advances once the deal has cycled through all four seats.
///
/// **Why `dealsSinceRoundStart` is a required parameter, not something
/// derived from `mySeatWind`/`roundWind` alone.** "The deal returns to East"
/// (the plan's phrasing) means *the specific seat that opened the current
/// round* gets the deal back — a fact about *identity*, not about wind
/// values. Winds alone can't recover that: after any number of passes, "my
/// wind is currently South" doesn't say whether this is hand 1 or hand 5 of
/// the round, because a dealer-repeat hand (draw or dealer win) leaves every
/// wind completely unchanged, and a physical seat's wind cycles E→N→W→S→E
/// regardless of which round it's in. The one fact that *does* pin this down
/// is a simple count — how many *distinct* dealers this round has had so
/// far — which `TableTracker` threads through as `dealsSinceRoundStart` (0
/// right after a round starts, incremented only when the deal actually
/// passes, reset to 0 the moment the 4th pass wraps into a new round).
/// Keeping that counter an explicit, caller-owned parameter (rather than
/// smuggling it into `TrackedTableState` or hiding it as private mutable
/// state here) keeps this whole rotation table a pure, trivially-testable
/// function: feed it any sequence of hand outcomes and it always answers the
/// same way, independent of everything else the tracker is doing.
///
/// (Deviation from the plan's literal `WindRotation.afterHand(dealerWon:
/// Bool)` sketch: collapsing "not the dealer" into one bool would conflate a
/// genuine opponent win with an exhaustive draw, and HK Old Style does *not*
/// pass the deal on a draw — the dealer repeats on both. Taking `winner:
/// RelativeSeat?` instead recovers that distinction for free.)
public enum WindRotation {

    /// One prediction: the next hand's winds, plus the updated
    /// `dealsSinceRoundStart` counter to feed into the *following* call.
    public struct Prediction: Sendable, Hashable {
        public var winds: HandEndProposal.PredictedWinds
        public var dealsSinceRoundStart: Int
        public init(winds: HandEndProposal.PredictedWinds, dealsSinceRoundStart: Int) {
            self.winds = winds
            self.dealsSinceRoundStart = dealsSinceRoundStart
        }
    }

    /// - Parameters:
    ///   - mySeatWind: my wind for the hand that just ended.
    ///   - roundWind: the prevailing wind for the hand that just ended.
    ///   - winner: the winning seat, relative to me; `nil` for an exhaustive
    ///     draw (荒牌). HK Old Style keeps the same dealer on a draw, exactly
    ///     like a dealer win.
    ///   - dealsSinceRoundStart: distinct dealers seated so far this round
    ///     (0 for the round's first hand) — see the type doc for why this is
    ///     required input rather than derived.
    public static func afterHand(mySeatWind: Wind, roundWind: Wind, winner: RelativeSeat?,
                                 dealsSinceRoundStart: Int) -> Prediction {
        let dealerSeat = RelativeSeat(rawValue: (4 - mySeatWind.rawValue) % 4)!

        // Dealer repeats: a dealer win, or a drawn (荒牌) hand.
        guard let winner, winner != dealerSeat else {
            return Prediction(winds: .init(mySeatWind: mySeatWind, roundWind: roundWind),
                              dealsSinceRoundStart: dealsSinceRoundStart)
        }

        // Deal passes to the next seat in turn order — every wind (including
        // mine) rotates back one step: a single physical seat's wind cycles
        // E→N→W→S→E as the deal moves on, since whoever is *next* becomes
        // the new East.
        let newMySeatWind = Wind(rawValue: (mySeatWind.rawValue + 3) % 4)!
        let deals = dealsSinceRoundStart + 1
        if deals >= 4 {
            let newRoundWind = Wind(rawValue: (roundWind.rawValue + 1) % 4)!
            return Prediction(winds: .init(mySeatWind: newMySeatWind, roundWind: newRoundWind),
                              dealsSinceRoundStart: 0)
        }
        return Prediction(winds: .init(mySeatWind: newMySeatWind, roundWind: roundWind),
                          dealsSinceRoundStart: deals)
    }
}

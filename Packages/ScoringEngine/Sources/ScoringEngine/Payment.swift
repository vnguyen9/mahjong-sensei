import Foundation
import MahjongCore

/// Who pays what for a scored hand.
///
/// This is a **secondary** helper: the UI is driven by the faan breakdown in
/// ``ScoreResult``. The model here is intentionally simple and clearly documented;
/// real tables vary widely in their money conventions.
public struct Payment: Sendable, Hashable {
    /// Base points for the hand's faan (see ``PaymentCalculator/basePoints(forFaan:)``).
    public let base: Int
    /// Total points the winner collects.
    public let winnerReceives: Int
    /// Points each non-winning opponent pays (self-draw only, else 0).
    public let perOpponent: Int
    /// Points the discarder pays (discard win only, else 0).
    public let discarderPays: Int
    /// Whether the win was self-drawn.
    public let isSelfDraw: Bool

    public init(base: Int, winnerReceives: Int, perOpponent: Int, discarderPays: Int, isSelfDraw: Bool) {
        self.base = base
        self.winnerReceives = winnerReceives
        self.perOpponent = perOpponent
        self.discarderPays = discarderPays
        self.isSelfDraw = isSelfDraw
    }
}

/// Converts faan to points using a documented exponential doubling table.
public enum PaymentCalculator {

    /// Base points for a faan total: `2^faan` (a "faan unit"; multiply by the table
    /// stake for money). Faan is clamped to `>= 0`. Real HK tables often use a
    /// stepped lookup with a cap instead — swap this out to retune.
    public static func basePoints(forFaan faan: Int) -> Int {
        1 << max(0, faan)
    }

    /// Settles a hand.
    ///
    /// - Self-draw: all three opponents pay `base` each; the winner collects `3 * base`.
    /// - Discard: only the discarder pays `base`; the winner collects `base`.
    ///
    /// `faan` should be the payable (capped) `totalFaan`.
    public static func settle(faan: Int, isSelfDraw: Bool) -> Payment {
        let base = basePoints(forFaan: faan)
        if isSelfDraw {
            return Payment(base: base,
                           winnerReceives: 3 * base,
                           perOpponent: base,
                           discarderPays: 0,
                           isSelfDraw: true)
        }
        return Payment(base: base,
                       winnerReceives: base,
                       perOpponent: 0,
                       discarderPays: base,
                       isSelfDraw: false)
    }

    /// Convenience: settle directly from a ``ScoreResult`` (uses `totalFaan`).
    public static func settle(_ result: ScoreResult, isSelfDraw: Bool) -> Payment {
        settle(faan: result.totalFaan, isSelfDraw: isSelfDraw)
    }
}

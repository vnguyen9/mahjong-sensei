import Foundation

/// The calibration surface for the EV model — every prior the advisor leans on,
/// gathered in one tunable struct (plan §2a). Defaults are HK Old Style guesses,
/// not measurements; a future simulator can fit them without touching the math.
///
/// Every constant here is **shared across candidate discards**, so tweaking one
/// moves the absolute EV numbers but never the *within-class* ranking — the
/// ordering an equal-shanten field gets is driven by the real ukeire that
/// differs per candidate, not these priors.
struct ModelConstants: Sendable, Hashable {
    /// ρ — the chance an opponent's discard is "as good as a random unseen tile"
    /// for winning off it. Scales the three discard channels against the lone
    /// self-draw channel.
    var discardAvailability: Double = 0.5
    /// h — per-go-around chance the hand ends for reasons outside this model
    /// (someone else wins, the wall runs out). Uniform across options, so it is
    /// ranking-neutral; it only sharpens the absolute calibration.
    var deadHazard: Double = 0.06
    /// n_T — assumed live outs of the eventual tenpai wait, used when a candidate
    /// is not yet tenpai and its real wait is unknowable.
    var typicalWait: Int = 6

    // Estimator weights (plan §2b) — how much partial credit a *potential*
    // category earns toward the "typical" faan.
    /// Credit for a held pair that could still become a scoring triplet.
    var pairToPungCredit: Double = 0.35
    /// Credit for a whole-hand line (七對子 / 對對糊 / 十三么) the shape is on.
    var lineCredit: Double = 0.25
    /// Credit for 無花 — a live "no flowers" bonus that a future flower draw breaks.
    var noFlowersCredit: Double = 0.5

    static let standard = ModelConstants()

    /// A[l] — assumed live ukeire at an intermediate stage `l` go-arounds from
    /// tenpai that we cannot yet see. Only used for advances *after* the first;
    /// the first advance always uses the candidate's real ukeire. Constant across
    /// candidates at equal shanten, so it scales across shanten classes (its job)
    /// without distorting within-class ranking.
    func stageUkeire(remainingAdvances l: Int) -> Int {
        switch l {
        case ...1: return 20
        case 2:    return 26
        case 3:    return 32
        default:   return 36
        }
    }
}

/// Win probability as an absorbing Markov chain over go-arounds (plan §2a).
///
/// States are the number of *advances completed* `k ∈ 0…s` toward tenpai, plus
/// the two absorbing outcomes `win` and `dead`. One transition fires per
/// go-around:
/// - **Pre-tenpai** (`k < s`): the hand advances one stage on *my draw only*
///   with probability `min(1, n/U)`, where `n` is the candidate's real ukeire
///   for the first advance and the stage prior `A[·]` for later ones. No
///   mid-hand chow/pung claims are modelled (v1, documented).
/// - **Tenpai** (`k = s`): the hand wins this go-around with
///   `q = 1 − (1 − a)(1 − ρa)³`, folding the self-draw channel `a = n_wait/U`
///   and the three opponent-discard channels `ρa`.
/// - Every non-absorbing go-around also ends the hand with hazard `h`.
///
/// `probability(...)` returns the chance of absorbing into `win` within `D`
/// go-arounds. The chain is `O(D·s)` — a few dozen cells — so this is
/// microseconds. Because every hazard is time-constant, the win mass splits
/// **exactly** proportionally into channels (``channelWeights(_:)``) and,
/// per-wait, proportionally to each wait's live count — computed at EV time.
///
/// Honest approximations, all documented on ``ModelConstants``: `outs/U` treats
/// the unseen pool as exchangeable; there is no opponent modelling or defence;
/// `A`, `n_T`, `ρ`, `h` are priors, not measurements. A dead tenpai
/// (`liveOuts == 0`) yields exactly 0 — so a live 1-shanten can outrank it.
enum WinProbability {

    /// Probability of winning within `drawsRemaining` go-arounds.
    ///
    /// - Parameters:
    ///   - shanten: the kept 13-tile hand's shanten (`0` = tenpai). Negatives are
    ///     clamped to 0 (a winning shape is scored elsewhere).
    ///   - liveOuts: the hand's real live ukeire total — the immediate next
    ///     advance's outs (at tenpai, the live wait count).
    ///   - unseen: `U`, the tiles nobody has seen yet.
    ///   - drawsRemaining: `D`, go-arounds left in the wall.
    ///   - constants: the calibration priors.
    static func probability(shanten: Int,
                            liveOuts: Int,
                            unseen: Int,
                            drawsRemaining: Int,
                            constants: ModelConstants = .standard) -> Double {
        guard unseen > 0, drawsRemaining > 0, liveOuts >= 0 else { return 0 }
        let s = max(0, shanten)
        let U = Double(unseen)
        let h = constants.deadHazard
        let rho = constants.discardAvailability

        // Probability mass over the advance stages k = 0…s. `win` accumulates the
        // absorbed win mass; dead mass is simply dropped (also absorbing).
        var stage = [Double](repeating: 0, count: s + 1)
        stage[0] = 1
        var win = 0.0

        for _ in 0..<drawsRemaining {
            var next = [Double](repeating: 0, count: s + 1)
            for k in 0...s where stage[k] > 0 {
                let mass = stage[k]
                if k < s {
                    // Advance on my draw; the first advance uses the real ukeire,
                    // later ones the stage prior.
                    let remaining = s - k
                    let n = (k == 0) ? liveOuts : constants.stageUkeire(remainingAdvances: remaining)
                    let p = min(1.0, Double(n) / U)
                    next[k + 1] += mass * (1 - h) * p           // advanced a stage
                    next[k]     += mass * (1 - h) * (1 - p)     // stayed put
                    // dead: mass * h  (dropped)
                } else {
                    // Tenpai: attempt the win this go-around.
                    let nWait = (s == 0) ? liveOuts : constants.typicalWait
                    let a = Double(nWait) / U
                    let q = 1 - (1 - a) * pow(1 - rho * a, 3)
                    win += mass * q
                    next[k] += mass * (1 - q) * (1 - h)         // survived to next go-around
                    // dead: mass * (1 - q) * h  (dropped)
                }
            }
            stage = next
        }
        return min(1, max(0, win))
    }

    /// The exact channel split of the win mass at tenpai. Because the per-round
    /// self-draw hazard is `a` and each of the three discard hazards is `ρa`, the
    /// shares are the time-constant `1/(1+3ρ)` and `3ρ/(1+3ρ)` — independent of
    /// the wait size. Sums to 1.
    static func channelWeights(_ constants: ModelConstants = .standard) -> (selfDraw: Double, discard: Double) {
        let rho = constants.discardAvailability
        let denom = 1 + 3 * rho
        return (selfDraw: 1 / denom, discard: 3 * rho / denom)
    }

    /// Go-arounds left in the wall when the tracker cannot supply them exactly:
    /// unseen tiles minus the ~39 in opponents' concealed hands is the wall, and
    /// four tiles leave it per go-around (plan §2a). Floored at 1.
    static func derivedDraws(unseen: Int, opponentMeldCount: Int) -> Int {
        max(1, (unseen - 39 + 3 * opponentMeldCount) / 4)
    }
}

import Foundation

/// Mass-disappearance → non-destructive hand-end proposal (tracker plan
/// §3.6). Watches how many of the tiles it has seen confirmed-live *this
/// hand* are currently gone and, once that clearing has been sustained long
/// enough, surfaces a `HandEndProposal` for the UI to confirm or dismiss.
/// Never mutates tracked state itself — `TableTracker` (the facade) owns the
/// actual reset on confirm.
///
/// **Why "confirmed this hand" instead of the store's live snapshot at any
/// one instant.** Once a track has been `.missing` for its motion-aware
/// grace window it *retires* and vanishes from `TrackStore.tracks` entirely
/// (`TrackerConfig.missingGraceSettled`/`.missingGraceMotion` are both well
/// under `handClearSustain`'s 5 s). If this detector only looked at the live
/// snapshot, its own denominator would shrink out from under it as a real
/// clear progressed — tiles that genuinely left the table would eventually
/// stop counting *at all*, in either direction. So it remembers every
/// `TrackID` that was ever `.live` during the current hand
/// (`everLiveThisHand`, reset only by `reset()`) as a *stable* denominator,
/// and counts a track as "missing" the moment `store.track(id)` stops
/// reporting it `.live` — `.missing` and retired-and-gone both count,
/// uniformly, exactly the signal a real table-clear produces.
///
/// **Occlusion guard.** This type carries no motion field of its own — the
/// plan's "nothing fires during high motion" requirement is structural, not
/// a per-call check: `TableTracker` (like `ZoneModel`/`TurnEngine`) only
/// calls `evaluateSettled` on settled frames, so a mid-action frame where an
/// arm sweeps across the table (which could transiently look like a mass
/// disappearance) never reaches this type at all.
///
/// **Meld immunity.** A claimed pung/kong moves at most 4 tiles physically
/// (plus, briefly, the claimed tile leaving the pond) — always below
/// `handClearMinTiles` (8), so the floor check alone makes a meld claim
/// structurally unable to trigger a proposal; no special-case code needed.
///
/// **Dismiss cooldown.** A manual `dismiss(at:)` remembers *when* and *which*
/// tracks were missing at the moment of dismissal. Until
/// `TrackerConfig.handEndDismissCooldown` elapses, `evaluateSettled`
/// suppresses re-proposal for as long as the currently-missing set stays a
/// *subset* of what was dismissed — the lean-over-the-table misfire (the
/// same handful of tiles still gone, table otherwise unchanged) doesn't
/// immediately re-nag. Any genuinely *new* missing track breaks the subset
/// relation and lifts the cooldown at once — real evidence of an actual
/// clear always wins over the suppression.
///
/// Not `Sendable` — mutable single-owner state, same convention as
/// `TrackStore`/`ZoneModel`/`TurnEngine`. No `Date()`/`UUID()` in any logic
/// path; every timestamp is the caller's injected `TimeInterval`.
public final class HandBoundaryDetector {
    private let config: TrackerConfig

    private var everLiveThisHand: Set<TrackID> = []
    private var clearingSince: TimeInterval?
    private var pending: Pending?

    // Dismiss-cooldown bookkeeping (see the type doc's "Dismiss cooldown"
    // note). `dismissedAt` nil ⇒ no cooldown in effect.
    private var dismissedAt: TimeInterval?
    private var dismissedMissingIDs: Set<TrackID> = []

    private struct Pending {
        var proposal: HandEndProposal
        var goneAtProposal: Set<TrackID>
    }

    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
    }

    /// True while a clearing episode is building toward a proposal but
    /// hasn't sustained long enough yet — `TableTracker` surfaces this as
    /// `TrackedHandPhase.clearing`.
    public var isClearing: Bool { clearingSince != nil }

    /// True while a proposal is active, awaiting confirm/dismiss/auto-cancel.
    public var isProposed: Bool { pending != nil }

    /// One settled-frame step. The facade calls this after
    /// `TurnEngine.commitSettled`, in the same "settled frames only"
    /// sequence `ZoneModel`/`TurnEngine` already follow — see the type doc's
    /// occlusion-guard note for why that alone satisfies "nothing fires
    /// during high motion".
    @discardableResult
    public func evaluateSettled(store: TrackStore, at t: TimeInterval) -> BoundaryOutcome {
        for tr in store.tracks where tr.state == .live { everLiveThisHand.insert(tr.id) }

        if let current = pending {
            let goneCount = current.goneAtProposal.count
            guard goneCount > 0 else { pending = nil; return BoundaryOutcome() }
            let reappeared = current.goneAtProposal.filter { store.track($0)?.state == .live }.count
            let reappearedFraction = Double(reappeared) / Double(goneCount)
            if t - current.proposal.at <= config.reappearWindow, reappearedFraction >= config.reappearFraction {
                pending = nil
                return BoundaryOutcome(cancelled: true)
            }
            return BoundaryOutcome()
        }

        let confirmed = everLiveThisHand.count
        guard confirmed > 0 else { return BoundaryOutcome() }
        let missingIDs = everLiveThisHand.filter { store.track($0)?.state != .live }
        let missingFraction = Double(missingIDs.count) / Double(confirmed)

        // Dismiss cooldown: while the currently-missing set is still a
        // *subset* of what a recent manual dismissal already waved off, and
        // that dismissal hasn't aged out of `handEndDismissCooldown`, never
        // even start the sustain timer — the lean-over-the-table misfire
        // doesn't immediately re-nag. A missing track outside that dismissed
        // set falls through to the normal logic below (real evidence wins).
        if let da = dismissedAt, t - da < config.handEndDismissCooldown,
           missingIDs.isSubset(of: dismissedMissingIDs) {
            clearingSince = nil
            return BoundaryOutcome()
        }

        guard missingFraction >= config.handClearFraction, missingIDs.count >= config.handClearMinTiles else {
            clearingSince = nil
            return BoundaryOutcome()
        }
        if clearingSince == nil { clearingSince = t }
        guard let since = clearingSince, t - since >= config.handClearSustain else {
            return BoundaryOutcome()
        }

        // Proposal fires — `predictedWinds` is left nil here on purpose:
        // this type has no notion of who's winning, that's `WindRotation`'s
        // job, and only `TableTracker` (which owns the current winds) can
        // fill it in.
        let proposal = HandEndProposal(at: t, missingFraction: missingFraction, predictedWinds: nil)
        pending = Pending(proposal: proposal, goneAtProposal: missingIDs)
        clearingSince = nil
        // A fresh proposal supersedes whatever an earlier dismissal was
        // suppressing — clear its bookkeeping so a *later* dismissal of
        // *this* proposal starts its own, independent cooldown.
        dismissedAt = nil
        dismissedMissingIDs.removeAll()
        return BoundaryOutcome(proposed: proposal)
    }

    /// Manual dismissal (`TableTracker.dismissHandEnd`) — clears the pending
    /// proposal without waiting for the auto-cancel reappearance signal, and
    /// (see the type doc's "Dismiss cooldown" note) remembers `t` and the
    /// dismissed proposal's missing-track set so `evaluateSettled` can
    /// suppress an immediate re-proposal over the same evidence. `t` is the
    /// caller's injected monotonic clock (`TableTracker.now`) — never
    /// `Date()`.
    public func dismiss(at t: TimeInterval) {
        if let current = pending {
            dismissedAt = t
            dismissedMissingIDs = current.goneAtProposal
        }
        pending = nil
        clearingSince = nil
    }

    /// Confirmed hand end (or a fresh session) — a brand-new hand starts
    /// counting confirmed tracks from zero.
    public func reset() {
        everLiveThisHand.removeAll()
        clearingSince = nil
        pending = nil
        dismissedAt = nil
        dismissedMissingIDs.removeAll()
    }
}

/// What one `evaluateSettled` call did — `TableTracker` turns a non-nil
/// `proposed` into a `handEndProposed` event (filling in `WindRotation`'s
/// prediction, which this type deliberately doesn't know how to compute) and
/// `cancelled` into a `handEndCancelled` event.
public struct BoundaryOutcome: Sendable, Hashable {
    public var proposed: HandEndProposal?
    public var cancelled: Bool
    public init(proposed: HandEndProposal? = nil, cancelled: Bool = false) {
        self.proposed = proposed
        self.cancelled = cancelled
    }
}

import Foundation

/// §9.2 lifecycle transitions. Every function here is driven by an explicit
/// event (a hit, a *qualified* miss, or a coverage loss) at an explicit
/// timestamp — never by wall-clock polling — so replaying the same event
/// sequence always reaches the same state.
enum TrackLifecycle {
    /// The track was matched to an observation this ingest.
    static func recordHit(on track: inout PhysicalTrack, at time: TimeInterval, config: CensusConfig) {
        track.lastHitAt = time
        track.qualifiedMissStreak = 0
        track.missStreakStartedAt = nil
        switch track.state {
        case .tentative:
            appendOpportunity(true, on: &track, config: config)
        case .confirmed:
            break // reaffirmed; nothing to transition
        case .temporarilyMissing:
            track.state = .confirmed // matched again
        case .stale:
            track.state = .confirmed // successful reacquisition
        case .retired:
            break // shouldn't happen — retired tracks are dropped from the live set
        }
    }

    /// The track was *not* matched this ingest, but its footprint fell
    /// inside this batch's exact observed coverage (§8/§9.2: only a
    /// qualified, covered successful observation is an "opportunity" —
    /// callers must check coverage before calling this).
    static func recordQualifiedMiss(on track: inout PhysicalTrack, at time: TimeInterval, config: CensusConfig) {
        switch track.state {
        case .tentative:
            appendOpportunity(false, on: &track, config: config)
        case .confirmed:
            track.state = .temporarilyMissing
            track.qualifiedMissStreak = 1
            track.missStreakStartedAt = time
            checkRetirement(on: &track, at: time, config: config)
        case .temporarilyMissing:
            track.qualifiedMissStreak += 1
            if track.missStreakStartedAt == nil { track.missStreakStartedAt = time }
            checkRetirement(on: &track, at: time, config: config)
        case .stale:
            // The zone came back into view and the tile genuinely isn't
            // there: that's real absence evidence, not just "we didn't look."
            track.state = .temporarilyMissing
            track.qualifiedMissStreak = 1
            track.missStreakStartedAt = time
            checkRetirement(on: &track, at: time, config: config)
        case .retired:
            break
        }
    }

    /// The track was not matched this ingest, and this batch's coverage
    /// doesn't include its footprint at all — we simply didn't look there.
    /// Coverage loss degrades a confirmed track to `.stale`, never counts as
    /// an opportunity, and never advances retirement (§9.2, §5.2).
    static func recordCoverageLoss(on track: inout PhysicalTrack) {
        if track.state == .confirmed {
            track.state = .stale
        }
        // tentative/temporarilyMissing/stale/retired: no-op.
    }

    /// True when a tentative track exhausted its confirmation window (§9.2:
    /// "confirmation window expires") without reaching 3 hits — the caller
    /// should drop it from the live track set.
    static func tentativeWindowExpired(_ track: PhysicalTrack, config: CensusConfig) -> Bool {
        guard track.state == .tentative else { return false }
        guard track.recentOpportunities.count >= config.tentativeWindow else { return false }
        return track.recentOpportunities.filter { $0 }.count < config.tentativeConfirmHits
    }

    private static func appendOpportunity(_ hit: Bool, on track: inout PhysicalTrack, config: CensusConfig) {
        track.recentOpportunities.append(hit)
        if track.recentOpportunities.count > config.tentativeWindow {
            track.recentOpportunities.removeFirst(track.recentOpportunities.count - config.tentativeWindow)
        }
        if track.recentOpportunities.filter({ $0 }).count >= config.tentativeConfirmHits {
            track.state = .confirmed
        }
    }

    private static func checkRetirement(on track: inout PhysicalTrack, at time: TimeInterval, config: CensusConfig) {
        guard track.qualifiedMissStreak >= config.retireMissCount,
              let started = track.missStreakStartedAt,
              time - started >= config.retireMinDuration else { return }
        track.state = .retired
    }
}

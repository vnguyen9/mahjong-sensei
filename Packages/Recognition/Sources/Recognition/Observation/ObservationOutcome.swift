/// A frame was intentionally not processed. Skips never add hits or misses
/// (§8) — they simply mean "we didn't look," as opposed to `.failed`, which
/// means "we tried to look and the attempt itself broke."
public enum SkipReason: Sendable, Hashable {
    case trackingNotNormal
    case qualityRejected(Set<FrameRejectionReason>)
    case zoneOffScreen
    case cadenceThrottled
    case calibrationMissing
    /// The short-lived Vision object tracker (§7.4) lost its target. This only
    /// schedules detector reacquisition — it is never absence evidence.
    case visionTrackerLostTarget
}

/// Inference or crop mapping failed outright. A `.failed` outcome must never
/// be coerced into `.success` with an empty observation list — that
/// conflation ("`recognize()` threw, so treat it as `.empty`") is exactly the
/// bug §8 exists to make impossible.
public enum ObservationFailure: Sendable, Hashable {
    case locatorThrew(String)
    case classifierThrew(String)
    case pixelCropFailed
    case cropMappingFailed
}

/// The outcome of attempting to turn one `ARFrame` (or zone crop within it)
/// into recognition evidence. See §8's outcome table: only `.success` may add
/// hits, and only inside its own `ObservationBatch.coverage` may it add
/// misses; `.skipped` and `.failed` add neither.
public enum ObservationOutcome: Sendable {
    case success(ObservationBatch)
    case skipped(SkipReason)
    case failed(ObservationFailure)
}

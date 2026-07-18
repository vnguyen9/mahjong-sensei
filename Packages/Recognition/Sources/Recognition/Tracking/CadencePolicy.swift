import Foundation

/// Pure cadence decision: given the current motion level, thermal state, and
/// time since the last inference, should the live loop run a recognizer pass
/// now (tracker plan §4.3)? Targets ~1 Hz idle, ~5.5 Hz burst during action,
/// a short 3-frame settle-burst right after motion calms (to catch the new
/// state promptly), and full suspension at critical thermal.
///
/// A small value type holding just enough state to remember "did motion just
/// calm down" and "how many settle-burst frames are left" — no threads, no
/// `Date()`; the caller supplies `timeSinceLastInference` from its own
/// injected clock (`ContinuousClock` in the app, stream `t` in the harness),
/// so this type is deterministic and trivially unit-testable by feeding it a
/// scripted sequence of `decide` calls.
///
/// Own constants (`idleInterval`, `burstInterval`, `settleBurstCount`,
/// `settleBurstInterval`, `pollInterval`, thermal multipliers) are **not**
/// duplicated into `TrackerConfig` — see that type's own header note; they
/// live here so tuning cadence can never drift out of sync with a second
/// copy of the same number. The one threshold this type *does* borrow from
/// `TrackerConfig` is `motionActive` (shared with `TrackStore`'s grace
/// extension and `TurnEngine`'s burst-region gate — "the scene is in
/// action" should mean the same motion level everywhere).
public struct CadencePolicy: Sendable {
    private let config: TrackerConfig

    /// Idle cadence when the scene has been calm for a while (~1 Hz).
    public var idleInterval: TimeInterval = 1.0
    /// Burst cadence while motion is active (~5.5 Hz; inference itself is
    /// 15–30 ms, so drop-if-in-flight rarely binds at this rate).
    public var burstInterval: TimeInterval = 0.18
    /// How many inferences, right after motion calms, run at the tighter
    /// `settleBurstInterval` before decaying back to idle — catches the new
    /// settled state promptly instead of waiting a full idle tick.
    public var settleBurstCount: Int = 3
    public var settleBurstInterval: TimeInterval = 0.25
    /// The app loop's own tick rate (motion is sampled every tick regardless
    /// of whether this policy says to infer) — carried here since it's a
    /// cadence constant, even though `decide` itself doesn't consume it.
    public var pollInterval: TimeInterval = 0.12

    /// `.fair` thermal multiplies idle/burst intervals by this (settle-burst
    /// intervals are deliberately left unscaled at every non-critical tier —
    /// they carry the information a freshly-settled frame needs).
    public var fairMultiplier: Double = 1.5
    public var seriousIdleInterval: TimeInterval = 2.0
    public var seriousBurstInterval: TimeInterval = 0.5

    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
    }

    /// Coarse thermal bucket, decoupled from `ProcessInfo.ThermalState` so
    /// this type never imports a live system API: the caller maps
    /// `ProcessInfo.processInfo.thermalState.rawValue` (0...3, nominal→
    /// critical, which is exactly `ProcessInfo.ThermalState`'s own raw
    /// ordering) straight across via `init(processInfoRawValue:)`; unit
    /// tests construct the case directly.
    public enum Thermal: Int, Sendable, CaseIterable, Comparable {
        case nominal = 0, fair, serious, critical
        public static func < (l: Thermal, r: Thermal) -> Bool { l.rawValue < r.rawValue }
        public init(processInfoRawValue: Int) {
            self = Thermal(rawValue: processInfoRawValue) ?? .critical
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Run inference now.
        case infer
        /// Not due yet — keep sampling motion, don't infer.
        case skip
        /// Thermal `.critical` — inference suspended entirely; the caller
        /// keeps a slow keepalive + motion sampling on its own
        /// (`health.pausedReason = .thermal` is an app-level concern, out of
        /// this package's scope).
        case suspend
    }

    // Settle-burst state.
    private var wasActive = false
    private var settleBurstFramesLeft = 0

    /// One state transition for the current tick. `motionLevel` is this
    /// tick's `MotionSample.level`; `timeSinceLastInference` is measured by
    /// the caller against its own clock.
    public mutating func decide(motionLevel: Double, thermal: Thermal,
                                timeSinceLastInference: TimeInterval) -> Decision {
        guard thermal != .critical else {
            wasActive = false
            settleBurstFramesLeft = 0
            return .suspend
        }

        let activeNow = motionLevel >= config.motionActive
        if wasActive && !activeNow {
            settleBurstFramesLeft = settleBurstCount   // motion just calmed — arm the burst
        }
        wasActive = activeNow

        let interval: TimeInterval
        if activeNow {
            interval = scaled(burstInterval, seriousValue: seriousBurstInterval, thermal: thermal)
        } else if settleBurstFramesLeft > 0 {
            interval = settleBurstInterval             // never thermally scaled — see type doc
        } else {
            interval = scaled(idleInterval, seriousValue: seriousIdleInterval, thermal: thermal)
        }

        guard timeSinceLastInference >= interval else { return .skip }
        if !activeNow, settleBurstFramesLeft > 0 { settleBurstFramesLeft -= 1 }
        return .infer
    }

    private func scaled(_ nominal: TimeInterval, seriousValue: TimeInterval, thermal: Thermal) -> TimeInterval {
        switch thermal {
        case .nominal: return nominal
        case .fair: return nominal * fairMultiplier
        case .serious: return seriousValue
        case .critical: return seriousValue   // unreachable (guarded above); safe fallback
        }
    }
}

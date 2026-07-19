import Foundation

/// Sustained-dark hysteresis for the torch-suggestion chip (plan A5). A pure,
/// mutable-state struct — mirrors `Recognition.CadencePolicy`'s "value type +
/// mutating decide/update" shape — so `CoachLiveSession` owns one instance
/// and feeds it a `MotionSample.meanLuma` reading every tick, with no
/// camera/UIKit dependency of its own.
///
/// Hysteresis keeps the chip from flickering as the brightness reading hovers
/// near a single threshold: the table only becomes "dark" after
/// `sustainDuration` of unbroken readings below the dark threshold, and it
/// clears the instant a reading reaches the clear threshold — well above the
/// dark one, so a scene sitting right at the boundary can't rapid-fire both
/// states. Lane B's AR loop feeds `update(lightLux:at:)` instead of
/// `update(meanLuma:at:)` whenever ARKit supplies a light estimate (a real
/// hardware light-sensor reading, more reliable than luma-from-pixels) —
/// both share the same `isDark`/hysteresis state, just against their own
/// domain-appropriate thresholds (`meanLuma` is a 0–255 pixel average,
/// `lightLux` is ARKit's ~0–2000-scaled ambient intensity), since the
/// detector itself doesn't care where the brightness reading came from.
struct DarkTableDetector {
    /// Below this mean luma (0–255), a reading counts toward the dark-sustain
    /// window; at/above it (but below `clearThreshold`) a not-yet-dark
    /// reading resets the window — only an unbroken run counts.
    var darkThreshold: Double = 40
    /// At or above this mean luma, `isDark` clears immediately — no sustain
    /// needed on the way back to bright, only on the way into dark.
    var clearThreshold: Double = 60
    /// `lightLux` (ARKit `ARFrame.lightEstimate.ambientIntensity`) equivalents
    /// of `darkThreshold`/`clearThreshold` — ~300 lux ≈ a dim indoor room.
    var darkLuxThreshold: Double = 300
    var clearLuxThreshold: Double = 450
    /// How long readings must stay below the dark threshold, uninterrupted,
    /// before `isDark` flips true.
    var sustainDuration: TimeInterval = 3

    private(set) var isDark = false
    /// Monotonic timestamp where the current unbroken below-threshold run
    /// began; nil while no such run is in progress.
    private var darkStreakStart: TimeInterval?

    init() {}

    /// Feeds one pixel-luma brightness reading at monotonic time `t`. Call
    /// once per tick from the live loop's motion block (the image-space/
    /// fallback capture path — no ARKit light estimate available).
    mutating func update(meanLuma: Double, at t: TimeInterval) {
        update(brightness: meanLuma, dark: darkThreshold, clear: clearThreshold, at: t)
    }

    /// Feeds one ARKit ambient-light reading at monotonic time `t` — the AR
    /// loop's preferred signal (`ARTableFrame.lightLux`) whenever a frame
    /// supplies one.
    mutating func update(lightLux: Double, at t: TimeInterval) {
        update(brightness: lightLux, dark: darkLuxThreshold, clear: clearLuxThreshold, at: t)
    }

    private mutating func update(brightness: Double, dark: Double, clear: Double, at t: TimeInterval) {
        if isDark {
            if brightness >= clear {
                isDark = false
                darkStreakStart = nil
            }
            return
        }
        guard brightness < dark else {
            darkStreakStart = nil
            return
        }
        let streakStart = darkStreakStart ?? t
        darkStreakStart = streakStart
        if t - streakStart >= sustainDuration {
            isDark = true
            darkStreakStart = nil
        }
    }
}

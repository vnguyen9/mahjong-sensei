import Foundation
import simd

/// Pure pose-velocity gate — the "hold steady" seam between ARKit's
/// continuous 60Hz pose stream and the tracking loop's event-cadence.
///
/// While the phone is visibly moving (panning, lifting, an unsteady hand)
/// every detection this tick was found against a camera pose the loop
/// hasn't finished reasoning about yet, and by the time a recognize pass
/// completes the phone may already be somewhere else — projecting that
/// frame's detections into table space would plant them at a stale,
/// physically wrong spot. So `CoachLiveSession`'s AR loop uses this gate to
/// skip motion-sample/cadence/inference/ingest entirely while moving
/// (publishing `session.cameraMoving` for the "Hold steady…" chip instead),
/// and forces one immediate inference on the moving→still edge to catch the
/// settled table promptly rather than waiting out a full idle cadence tick.
///
/// Pure, ARKit-free (only `simd`/`Foundation`) — unit-testable with synthetic
/// transforms, same "value type + mutating update" shape as
/// `Recognition.CadencePolicy`/`DarkTableDetector`. Single-owner mutable
/// state (a short ring of recent poses), not `Sendable`.
struct CameraMotionGate {
    /// How many recent `(transform, t)` samples the gate keeps. Velocity is
    /// measured from the OLDEST ring entry to the newest fed sample —
    /// spanning a few ticks smooths ARKit's per-frame pose jitter without
    /// lagging a genuine stop by more than a beat.
    private static let ringCapacity = 4

    /// Linear speed threshold, metres/second, above which the camera counts
    /// as moving. Unverified — tune on device (see the Lane B plan).
    var linearThreshold: Double = 0.12
    /// Angular speed threshold, degrees/second.
    var angularThreshold: Double = 25

    private var ring: [(transform: simd_float4x4, t: TimeInterval)] = []

    init() {}

    /// Feeds one `(transform, t)` sample (once per loop tick — `t` is the
    /// frame's own monotonic timestamp, not a wall clock) and returns
    /// whether the camera currently reads as moving. The very first sample
    /// (nothing to diff against yet) reads as still.
    mutating func update(transform: simd_float4x4, at t: TimeInterval) -> Bool {
        defer {
            ring.append((transform, t))
            if ring.count > Self.ringCapacity { ring.removeFirst() }
        }
        guard let oldest = ring.first, t > oldest.t else { return false }
        let dt = t - oldest.t
        guard dt > 0 else { return false }

        let p0 = SIMD3<Float>(oldest.transform.columns.3.x, oldest.transform.columns.3.y, oldest.transform.columns.3.z)
        let p1 = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let linearSpeed = Double(simd_distance(p0, p1)) / dt

        let q0 = simd_quatf(Self.rotation(oldest.transform))
        let q1 = simd_quatf(Self.rotation(transform))
        // Angle between the two orientations via the quaternion dot product
        // (`abs` because q and -q represent the same rotation): 2·acos(|q0·q1|).
        let dot = Double(min(1, max(-1, abs(simd_dot(q0.vector, q1.vector)))))
        let angleDegrees = 2 * acos(dot) * 180 / Double.pi
        let angularSpeed = angleDegrees / dt

        return linearSpeed > linearThreshold || angularSpeed > angularThreshold
    }

    private static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                     SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                     SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }
}

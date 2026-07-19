import Foundation
import simd

/// Pure state machine that decides which detected horizontal plane is "the
/// table" and when to promote it from a moving candidate to a locked
/// anchor. Takes plain data — **no `ARKit` import** — so it's fully
/// unit-testable and reviewable independent of a live `ARSession`.
/// `ARTableCapture` is the only caller today; it's responsible for
/// converting each frame's `ARPlaneAnchor`s into the `Candidate` shape
/// below (see that struct's doc for exactly what shape to hand in — in
/// particular, the centering it requires callers to do up front).
///
/// ## Selection
///
/// Each fed frame, among `candidates`, the policy picks the largest (by
/// horizontal area, `extentX * extentZ`) whose center lies within
/// `lateralRadius` of the camera's ground-projected position (its world
/// `(x, z)`, ignoring height) — i.e. "the biggest flat surface roughly
/// under/near me." That's a reasonable prior for "the table I'm holding my
/// phone over," and it keeps a horizontal surface on the far side of the
/// room from stealing the lock just because ARKit happened to merge a
/// bigger mesh for it.
///
/// ## Promotion (stability gate)
///
/// A pick is promoted to `lockedPlane` once the SAME candidate `id` has
/// been the pick continuously for `stableDuration` seconds AND its center
/// moved less than `centerEpsilon` between every pair of consecutive fed
/// frames throughout that whole window (ARKit's plane-merging otherwise
/// keeps nudging a plane's extent/center as more of the table comes into
/// view — this waits out that settling before committing). Losing the pick
/// (a different or no candidate wins a frame) or exceeding `centerEpsilon`
/// resets the stability clock. Once `lockedPlane` is non-nil the policy is
/// done — every subsequent `update` is a no-op; feed a **fresh instance**
/// for a new session or a re-lock (e.g. after relocalization fails and the
/// caller wants to re-find the table).
///
/// ## LOCKED CONTRACT — yaw alignment at promotion
///
/// On promotion, the emitted `lockedPlane.transform` is **not** the winning
/// candidate's raw `transform` — it's that transform with its local X/Z
/// basis re-derived (about the SAME local Y / normal, at the SAME origin)
/// so the resulting local **+Z** axis points from the plane's origin
/// toward `initialCameraPosition` (the session-start camera position,
/// passed once at `init`) projected onto the plane.
///
/// This is load-bearing downstream: `Recognition.TableProjection` /
/// `DetectionProjector` express every detection in this exact anchor-local
/// frame, and the tracker's seat/zone geometry (`seatFromDisplacement`,
/// hand-band-near-my-edge heuristics) assumes table-space **+y** — which is
/// fed from anchor-local **z** (see `TableProjection`'s doc on its
/// `SIMD2(x: local x, y: local z)` packing) — "grows toward me." Do not
/// change this convention without auditing every consumer of
/// `TableProjection` / `DetectionProjector` / table-space `ZoneModel`.
public struct PlaneLockPolicy {
    /// One horizontal plane candidate, as of a single fed frame.
    ///
    /// `transform` MUST already be centered — its translation column must
    /// be the plane's actual center point in world space, not the
    /// (possibly offset) anchor origin. `ARPlaneAnchor.transform` is
    /// anchor-origin → world, and `ARPlaneAnchor.center` is a local-space
    /// offset from that origin to the plane's true center; callers
    /// translate `transform` by `center` (in the anchor's own local space,
    /// i.e. `anchor.transform * translation(center)`) before constructing
    /// a `Candidate` — this type performs no such correction itself, to
    /// keep this input shape a plain, ARKit-independent data bag.
    public struct Candidate {
        public var id: UUID
        /// Local → world, already centered per the doc above. Local Y is
        /// the plane's normal (ARKit horizontal-plane convention).
        public var transform: simd_float4x4
        /// Plane extent along its local X axis, metres.
        public var extentX: Float
        /// Plane extent along its local Z axis, metres.
        public var extentZ: Float

        public init(id: UUID, transform: simd_float4x4, extentX: Float, extentZ: Float) {
            self.id = id
            self.transform = transform
            self.extentX = extentX
            self.extentZ = extentZ
        }
    }

    /// A promoted, yaw-aligned, centered plane lock — see the type's
    /// LOCKED CONTRACT doc for exactly what `transform` means.
    public struct LockedPlane: Equatable {
        public var id: UUID
        public var transform: simd_float4x4

        public init(id: UUID, transform: simd_float4x4) {
            self.id = id
            self.transform = transform
        }
    }

    /// How long (seconds) the same candidate must keep winning selection,
    /// with a near-motionless center, before it's promoted. Defaults to
    /// 2.0s per the design's target lock latency.
    public let stableDuration: TimeInterval
    /// Max center movement (metres) allowed between consecutive fed frames
    /// during the stability window before the clock resets. 2cm default —
    /// small enough to reject genuine re-centering as ARKit refines the
    /// plane, generous enough to absorb per-frame anchor jitter.
    public let centerEpsilon: Float
    /// Max lateral distance (metres, ground-plane) from the camera's
    /// ground-projected position for a candidate to be eligible for
    /// selection at all. 1.5m default — a propped phone is expected to sit
    /// at or near the table's edge; tune on-device once real geometry is
    /// in hand.
    public let lateralRadius: Float
    /// The session-start camera world position — the fixed reference the
    /// LOCKED CONTRACT's yaw alignment points local +Z toward.
    public let initialCameraPosition: SIMD3<Float>

    /// The candidate `id` currently being tracked for stability, and when
    /// it started being the pick.
    private var trackingID: UUID?
    private var trackingSince: TimeInterval?
    private var lastCenter: SIMD3<Float>?

    /// Non-nil exactly once promotion happens; `update` is then a no-op
    /// forever (feed a fresh instance to re-lock).
    public private(set) var lockedPlane: LockedPlane?

    public init(stableDuration: TimeInterval = 2.0,
                centerEpsilon: Float = 0.02,
                lateralRadius: Float = 1.5,
                initialCameraPosition: SIMD3<Float>) {
        self.stableDuration = stableDuration
        self.centerEpsilon = centerEpsilon
        self.lateralRadius = lateralRadius
        self.initialCameraPosition = initialCameraPosition
    }

    /// Feeds one frame's candidates. A no-op once `lockedPlane` is set.
    public mutating func update(candidates: [Candidate],
                                cameraTransform: simd_float4x4,
                                t: TimeInterval) {
        guard lockedPlane == nil else { return }

        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x,
                                          cameraTransform.columns.3.y,
                                          cameraTransform.columns.3.z)
        let groundCamera = SIMD2<Float>(cameraPosition.x, cameraPosition.z)

        let eligible = candidates.filter { candidate in
            let center = candidate.transform.columns.3
            let groundCenter = SIMD2<Float>(center.x, center.z)
            return simd_distance(groundCamera, groundCenter) <= lateralRadius
        }

        guard let winner = eligible.max(by: { $0.extentX * $0.extentZ < $1.extentX * $1.extentZ }) else {
            // Nothing eligible this frame — lose any in-progress pick.
            trackingID = nil
            trackingSince = nil
            lastCenter = nil
            return
        }

        let center = SIMD3<Float>(winner.transform.columns.3.x,
                                  winner.transform.columns.3.y,
                                  winner.transform.columns.3.z)

        guard trackingID == winner.id else {
            // A new (or first) winner — restart the stability window.
            trackingID = winner.id
            trackingSince = t
            lastCenter = center
            return
        }

        if let lastCenter, simd_distance(lastCenter, center) > centerEpsilon {
            trackingSince = t   // moved too much — restart the window from now
        }
        lastCenter = center

        guard let since = trackingSince, t - since >= stableDuration else { return }

        lockedPlane = LockedPlane(id: winner.id,
                                  transform: Self.yawAligned(winner.transform, towards: initialCameraPosition))
    }

    /// Composes `transform` (already centered — its translation IS the
    /// plane's world-space origin) into a new transform whose local +Z
    /// points from that origin toward `target` projected onto the plane —
    /// see the type's LOCKED CONTRACT doc. Local Y (the plane's normal) and
    /// the origin are unchanged; only the in-plane X/Z basis is re-derived,
    /// directly (via cross products) rather than via an angle + rotation
    /// matrix, so there's no separate step that could get the rotation
    /// direction backwards.
    private static func yawAligned(_ transform: simd_float4x4, towards target: SIMD3<Float>) -> simd_float4x4 {
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let normal = simd_normalize(SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))

        // Project the target onto the plane (drop the component along the
        // normal) to get the desired in-plane "forward" direction.
        let toTarget = target - origin
        let inPlane = toTarget - simd_dot(toTarget, normal) * normal
        guard simd_length(inPlane) > 1e-6 else {
            // Camera directly above/below the plane's center — no
            // well-defined yaw; keep the original (arbitrary) orientation
            // rather than divide by a near-zero vector.
            return transform
        }

        // Right-handed orthonormal basis: for the original transform's
        // columns (X, Y, Z), X = Y × Z holds (ARKit anchor transforms are
        // proper rotations). Preserving that identity with the new Z gives
        // the new X directly, with no separate angle/quaternion step.
        let newZ = simd_normalize(inPlane)
        let newX = simd_normalize(simd_cross(normal, newZ))
        let newY = normal

        var result = transform
        result.columns.0 = SIMD4<Float>(newX, 0)
        result.columns.1 = SIMD4<Float>(newY, 0)
        result.columns.2 = SIMD4<Float>(newZ, 0)
        result.columns.3 = SIMD4<Float>(origin, 1)
        return result
    }
}

import Foundation
import Recognition
import simd

/// v2.5's scored, gated candidate-plane selection (Technical design §4.1) —
/// what the design doc calls "`PlaneLockPolicy` becomes `TableCalibrationController`."
/// This is a NEW, separate type: `PlaneLockPolicy` stays exactly as-is for
/// the v2 (image-space fallback) path, which still just wants "biggest
/// nearby plane, no scoring." Nothing here imports `ARKit` — every input is
/// plain data the caller (a future v2.5 `ARTableCapture` integration) builds
/// from `ARFrame`/`ARPlaneAnchor`, the same way `ARTableCapture.candidate(for:)`
/// already does for `PlaneLockPolicy.Candidate`. `Recognition.TableProjection`
/// IS used (for the on-screen-projection gate/score term below) — that's a
/// pure `simd`/`Foundation` package with no platform dependency of its own,
/// so importing it doesn't reintroduce one here.
///
/// Unlike `PlaneLockPolicy` ("pick the largest, wait for it to sit still"),
/// this type keeps EVERY plausible candidate every frame, scores each one
/// (§4.1's table), and only locks once a clear, stable winner emerges. It
/// never locks silently, either: the design's "user confirmation remains
/// mandatory even when confidence is high" (§4.1's closing line) is enforced
/// by the CALLER treating `lockedCandidate` as a proposal to show the user
/// (feed it to `TableQuadProposal`, then `TableCalibrationView`), not as an
/// already-confirmed table — this type has no notion of user confirmation at
/// all, on purpose.
public struct TableCalibrationController {

    // MARK: - Input shapes

    /// One horizontal plane candidate, as of a single fed frame — the same
    /// "caller must pre-center `transform`" contract as
    /// `PlaneLockPolicy.Candidate` (see that type's doc for exactly why:
    /// `ARPlaneAnchor.transform` is anchor-origin → world while
    /// `ARPlaneAnchor.center` is a local-space offset to the plane's true
    /// center — translate before constructing this).
    public struct Candidate {
        public var id: UUID
        /// Local → world, centered. Local Y is the plane's normal (ARKit
        /// horizontal-plane convention) — this is what the hard gates read
        /// to reject tilted planes, walls, and ceilings/undersides.
        public var transform: simd_float4x4
        /// Plane extent along its local X axis, metres.
        public var extentX: Float
        /// Plane extent along its local Z axis, metres.
        public var extentZ: Float
        /// ARKit's plane classification, when resolved. `false` (not an
        /// `Optional`) when classification is unavailable or still
        /// unresolved — "no evidence either way" reads identically to "not
        /// (yet) classified as table" in this scoring model; see §4.1's
        /// table, "+3.0 — strong semantic evidence WHERE AVAILABLE."
        public var isClassifiedTable: Bool
        /// How many raycast tile footpoints (this frame, from the locator's
        /// current detections) land supported on this candidate's plane —
        /// paired with `totalFootpointCount` for the support-FRACTION score
        /// term (§4.1). Computed by the caller (raycasting is
        /// `TableProjection`/ARKit-adjacent geometry this `Candidate` shape
        /// deliberately stays independent of, mirroring how
        /// `PlaneLockPolicy.Candidate` pre-digests `ARPlaneAnchor` fields
        /// rather than embedding one); `(0, 0)` before any tile has ever
        /// been detected.
        public var supportedFootpointCount: Int
        public var totalFootpointCount: Int

        public init(id: UUID,
                    transform: simd_float4x4,
                    extentX: Float,
                    extentZ: Float,
                    isClassifiedTable: Bool = false,
                    supportedFootpointCount: Int = 0,
                    totalFootpointCount: Int = 0) {
            self.id = id
            self.transform = transform
            self.extentX = extentX
            self.extentZ = extentZ
            self.isClassifiedTable = isClassifiedTable
            self.supportedFootpointCount = supportedFootpointCount
            self.totalFootpointCount = totalFootpointCount
        }
    }

    /// Per-frame camera pose/intrinsics context every candidate is scored
    /// against — plain ARKit-SHAPED data (mirrors `ARTableFrame`'s own
    /// fields), never an `ARFrame` itself.
    public struct FrameContext {
        public var cameraTransform: simd_float4x4
        public var intrinsics: simd_float3x3
        public var imageResolution: SIMD2<Float>
        public var orientedImageSize: SIMD2<Float>
        public var timestamp: TimeInterval

        public init(cameraTransform: simd_float4x4,
                    intrinsics: simd_float3x3,
                    imageResolution: SIMD2<Float>,
                    orientedImageSize: SIMD2<Float>,
                    timestamp: TimeInterval) {
            self.cameraTransform = cameraTransform
            self.intrinsics = intrinsics
            self.imageResolution = imageResolution
            self.orientedImageSize = orientedImageSize
            self.timestamp = timestamp
        }
    }

    // MARK: - Output shapes

    /// Why a candidate was hard-rejected this frame (§4.1's rejection list).
    /// `normalMisaligned` covers BOTH "alignment is not horizontal" and
    /// "normal differs from gravity-up by more than 10°" — in this
    /// implementation they're the same angle test (a plane's "horizontal-
    /// ness" IS how close its normal sits to gravity-up under ARKit's
    /// `.gravity` world alignment), so keeping one case avoids a fake second
    /// check that could never fire independently of the first.
    public enum HardGateFailure: Sendable, Hashable {
        case normalMisaligned
        case notBelowCamera
        case heightOutOfRange
        case extentTooSmall
        case mostlyOffScreen
    }

    /// One candidate's scoring result for this frame — surfaced so a debug
    /// HUD (a later chunk) can show why the proposal is/isn't converging.
    /// `TableCalibrationController` itself only acts on `lockedCandidate`.
    public struct ScoredCandidate {
        public var id: UUID
        public var score: Float
        public var passesHardGates: Bool
        public var failedGates: Set<HardGateFailure>
    }

    /// A scored, gated candidate that met every lock condition in §4.1 — a
    /// PROPOSAL for the calibration UI to show and the user to confirm, NOT
    /// an already-confirmed table (see the type's doc).
    public struct LockedCandidate: Equatable {
        public var id: UUID
        public var transform: simd_float4x4
        public var score: Float
    }

    // MARK: - Tunable thresholds (§4.1 — "starting values", log them on-device)

    public var maxNormalTiltDegrees: Double = 10
    public var heightRange: ClosedRange<Float> = 0.10...0.80
    public var minExtent: Float = 0.55
    /// Fraction of a sampled on-plane grid that must land inside the visible
    /// `[0,1]x[0,1]` frame for "projected mostly on-screen" to pass — also
    /// doubles as the §4.1 "projected center/coverage" score term's input
    /// (one measurement, two uses; see `onScreenFraction`'s doc).
    public var minOnScreenFraction: Float = 0.5
    public var stableDuration: TimeInterval = 2.0
    public var centerEpsilon: Float = 0.02
    public var lockScoreThreshold: Float = 5.0
    public var lockMarginThreshold: Float = 1.0
    public var minSupportedFootpointsForLock: Int = 3

    // MARK: - State

    private var stability: [UUID: (since: TimeInterval, lastCenter: SIMD3<Float>)] = [:]
    private var leaderID: UUID?
    private var leaderSince: TimeInterval?

    /// Non-nil exactly once lock happens; `update` is then a no-op forever —
    /// feed a fresh instance to re-find a table (e.g. after "Rescan table"
    /// or a failed relocalization).
    public private(set) var lockedCandidate: LockedCandidate?

    public init() {}

    // MARK: - Update

    /// Feeds one frame's candidates; returns `[]` once `lockedCandidate` is
    /// already set (see that property's doc).
    @discardableResult
    public mutating func update(candidates: [Candidate], frame: FrameContext) -> [ScoredCandidate] {
        guard lockedCandidate == nil else { return [] }

        var results: [ScoredCandidate] = []
        results.reserveCapacity(candidates.count)
        for candidate in candidates {
            results.append(score(candidate, frame: frame))
        }

        let passing: [(candidate: Candidate, scored: ScoredCandidate)] =
            zip(candidates, results).compactMap { $1.passesHardGates ? ($0, $1) : nil }
        guard let best = passing.max(by: { $0.scored.score < $1.scored.score }) else {
            leaderID = nil
            leaderSince = nil
            return results
        }
        let runnerUpScore = passing
            .filter { $0.candidate.id != best.candidate.id }
            .map { $0.scored.score }
            .max() ?? -Float.infinity
        let margin = best.scored.score - runnerUpScore

        let hasSupportingEvidence = best.candidate.isClassifiedTable
            || best.candidate.supportedFootpointCount >= minSupportedFootpointsForLock
        let eligible = best.scored.score >= lockScoreThreshold
            && margin >= lockMarginThreshold
            && hasSupportingEvidence

        guard eligible else {
            leaderID = nil
            leaderSince = nil
            return results
        }

        guard leaderID == best.candidate.id else {
            leaderID = best.candidate.id
            leaderSince = frame.timestamp
            return results
        }

        if let since = leaderSince, frame.timestamp - since >= stableDuration {
            lockedCandidate = LockedCandidate(id: best.candidate.id,
                                              transform: best.candidate.transform,
                                              score: best.scored.score)
        }
        return results
    }

    // MARK: - Scoring

    private mutating func score(_ candidate: Candidate, frame: FrameContext) -> ScoredCandidate {
        var failed: Set<HardGateFailure> = []

        let origin = SIMD3<Float>(candidate.transform.columns.3.x, candidate.transform.columns.3.y, candidate.transform.columns.3.z)
        let normal = simd_normalize(SIMD3<Float>(candidate.transform.columns.1.x, candidate.transform.columns.1.y, candidate.transform.columns.1.z))
        let cameraPosition = SIMD3<Float>(frame.cameraTransform.columns.3.x, frame.cameraTransform.columns.3.y, frame.cameraTransform.columns.3.z)

        // Angle between the plane's normal and gravity-up, in Double for the
        // same precision/style `CameraMotionGate.update` uses for its own
        // quaternion-angle computation.
        let tiltCos = Double(min(1, max(-1, simd_dot(normal, SIMD3<Float>(0, 1, 0)))))
        let tiltDegrees = acos(tiltCos) * 180 / Double.pi
        if tiltDegrees > maxNormalTiltDegrees { failed.insert(.normalMisaligned) }

        let verticalDistance = cameraPosition.y - origin.y
        if verticalDistance <= 0 {
            failed.insert(.notBelowCamera)
        } else if !heightRange.contains(verticalDistance) {
            failed.insert(.heightOutOfRange)
        }

        if candidate.extentX < minExtent || candidate.extentZ < minExtent { failed.insert(.extentTooSmall) }

        let coverage = onScreenFraction(candidate, frame: frame)
        if coverage < minOnScreenFraction { failed.insert(.mostlyOffScreen) }

        guard failed.isEmpty else {
            return ScoredCandidate(id: candidate.id, score: 0, passesHardGates: false, failedGates: failed)
        }

        var total: Float = 0
        if candidate.isClassifiedTable { total += 3.0 }

        let supportFraction = candidate.totalFootpointCount > 0
            ? Float(candidate.supportedFootpointCount) / Float(candidate.totalFootpointCount) : 0
        total += 3.0 * supportFraction

        if isStable(candidate, at: frame.timestamp) { total += 2.0 }

        total += 1.5 * areaScore(candidate.extentX * candidate.extentZ)
        total += 1.0 * min(1, coverage)

        let rangeWidth = heightRange.upperBound - heightRange.lowerBound
        let edgeDistance = min(verticalDistance - heightRange.lowerBound, heightRange.upperBound - verticalDistance)
        let nearEdge = 1 - min(1, max(0, edgeDistance / (rangeWidth / 2)))
        total -= 1.0 * nearEdge

        return ScoredCandidate(id: candidate.id, score: total, passesHardGates: true, failedGates: [])
    }

    /// §4.1's "plausible table area" term — saturates (full credit) across
    /// 0.8-1.2m per side (`0.64`-`1.44` m²) and decays linearly to zero over
    /// an equally-wide band on either side. A placeholder shape, like every
    /// other §4.1 weight — the design doc calls these "starting values"
    /// that "must be recorded in device logs" once real geometry is in hand.
    private func areaScore(_ area: Float) -> Float {
        let lower: Float = 0.64, upper: Float = 1.44
        guard area > 0 else { return 0 }
        if area >= lower && area <= upper { return 1 }
        if area < lower { return max(0, area / lower) }
        return max(0, 1 - (area - upper) / upper)
    }

    /// True iff `candidate`'s center has stayed within `centerEpsilon` of
    /// itself continuously since it was first seen (or last jumped) —
    /// mirrors `PlaneLockPolicy`'s own stability-window technique (see that
    /// type's doc), tracked independently PER CANDIDATE `id` here (rather
    /// than one shared clock) so a losing candidate never resets a
    /// DIFFERENT candidate's stability window.
    private mutating func isStable(_ candidate: Candidate, at t: TimeInterval) -> Bool {
        let center = SIMD3<Float>(candidate.transform.columns.3.x, candidate.transform.columns.3.y, candidate.transform.columns.3.z)
        guard let entry = stability[candidate.id] else {
            stability[candidate.id] = (since: t, lastCenter: center)
            return false
        }
        if simd_distance(entry.lastCenter, center) > centerEpsilon {
            stability[candidate.id] = (since: t, lastCenter: center)
            return false
        }
        stability[candidate.id]?.lastCenter = center
        return t - entry.since >= stableDuration
    }

    /// Fraction of a 3x3 grid of points spanning `candidate`'s extent that
    /// both project successfully (in front of the camera, per
    /// `TableProjection.normalizedOrientedPoint`'s own contract) AND land
    /// inside the visible `[0,1]x[0,1]` oriented-normalized frame — reused
    /// for both the "projected mostly on-screen" hard gate and the §4.1
    /// "projected center/coverage" score term (see `minOnScreenFraction`'s
    /// doc for why one measurement serves both).
    private func onScreenFraction(_ candidate: Candidate, frame: FrameContext) -> Float {
        let halfX = candidate.extentX / 2, halfZ = candidate.extentZ / 2
        guard halfX > 0, halfZ > 0 else { return 0 }
        let projection = TableProjection(cameraTransform: frame.cameraTransform,
                                         intrinsics: frame.intrinsics,
                                         imageResolution: frame.imageResolution,
                                         planeTransform: candidate.transform)
        let orientedSize = SIMD2<Double>(Double(frame.orientedImageSize.x), Double(frame.orientedImageSize.y))
        let steps: [Float] = [-1, 0, 1]
        var onScreen = 0
        var total = 0
        for fx in steps {
            for fz in steps {
                total += 1
                let local = SIMD2<Double>(Double(fx * halfX), Double(fz * halfZ))
                guard let p = projection.normalizedOrientedPoint(ofTablePoint: local, orientedImageSize: orientedSize) else { continue }
                if p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 { onScreen += 1 }
            }
        }
        return total > 0 ? Float(onScreen) / Float(total) : 0
    }
}

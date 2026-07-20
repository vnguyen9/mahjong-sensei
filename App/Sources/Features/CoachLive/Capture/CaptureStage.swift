import Foundation

enum LegacyFallbackReason: String, Equatable, Sendable {
    case arUnavailable
    case depthUnsupported
    case depthUnavailable

    var message: String {
        switch self {
        case .arUnavailable: return "AR tracking unavailable"
        case .depthUnsupported: return "This device has no LiDAR depth"
        case .depthUnavailable: return "LiDAR depth stopped responding"
        }
    }
}

enum CoachLiveCountSource: Equatable, Sendable {
    case spatialBootstrapping
    case worldCensus
    case legacy2D(LegacyFallbackReason)

    var diagnosticName: String {
        switch self {
        case .spatialBootstrapping: return "BOOTSTRAP"
        case .worldCensus: return "CENSUS"
        case .legacy2D: return "2D"
        }
    }
}

enum SpatialTrackingHealth: Equatable, Sendable {
    case calibrating
    case healthy
    case relocalizing
    case depthUnavailable
    case trackingLimited

    var diagnosticName: String {
        switch self {
        case .calibrating: return "calibrating"
        case .healthy: return "healthy"
        case .relocalizing: return "relocalizing"
        case .depthUnavailable: return "depth-unavailable"
        case .trackingLimited: return "tracking-limited"
        }
    }
}

/// The ARKit table-capture pipeline's coarse lifecycle state — what
/// `ARTableCapture` is doing right now, independent of any single frame's
/// tracking quality. The Lane A staged-loading UI (`StartupStatusOverlay`)
/// renders off this enum once the Lane B wiring chunk lands; it lives here,
/// standalone, so that later work and this one can both compile and be
/// reviewed independently.
///
/// Transition order in the common case:
/// `.starting` → `.findingTable` → `.tableLocked` → `.tracking`, with
/// `.relocalizing` a temporary detour from any of the post-lock stages and
/// `.unavailable` a terminal state reached only from `.starting` (ARKit
/// either is or isn't supported at start time).
public enum CaptureStage: Equatable {
    /// The `ARSession` hasn't started yet (before `start()` is called), or
    /// has just been asked to start and hasn't delivered a first frame.
    case starting

    /// The session is delivering frames and looking for a horizontal plane
    /// candidate large and stable enough to lock as "the table" —
    /// `PlaneLockPolicy` hasn't promoted anything yet.
    case findingTable

    /// A table plane has been promoted (`PlaneLockPolicy.lockedPlane` fired)
    /// and plane detection has been turned off to save power. The locked
    /// transform is stable; downstream projection can start using it.
    case tableLocked

    /// Normal steady-state operation: the phone is propped, the plane is
    /// locked, and the tracking loop is ingesting frames. Driven externally
    /// via `ARTableCapture.enterTracking()` — this type never enters the
    /// stage on its own.
    case tracking

    /// ARKit's world tracking has degraded
    /// (`ARCamera.TrackingState.limited(.relocalizing)`) or the session was
    /// interrupted (e.g. a phone call, app backgrounding) — pose is
    /// untrustworthy until tracking recovers. The stage held immediately
    /// before the interruption is restored once tracking resumes normal.
    case relocalizing

    /// ARKit world tracking isn't supported on this device/runtime (e.g.
    /// the Simulator) — the capture pipeline is permanently unavailable for
    /// this session; callers should fall back to the image-space capture
    /// path. Reached only from `.starting`, and never left.
    case unavailable
}

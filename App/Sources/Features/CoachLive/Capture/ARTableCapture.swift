import ARKit
import AVFoundation
import Observation
import os

/// Owns the ARKit world-tracking session for Coach Live's table capture:
/// starts world tracking with horizontal-plane detection, drives
/// `PlaneLockPolicy` frame-by-frame until a table plane locks, then turns
/// plane detection off (a real power/thermal win — ARKit's plane merging
/// keeps costing cycles even once nothing reads the results anymore).
///
/// Two different concurrency techniques cover the two different kinds of
/// state here, mirroring how `CameraCapture` (the AVCapture equivalent)
/// splits its own per-frame buffer from its published state:
/// - `latestFrame` is per-frame (~60Hz) and polled, not observed — cached
///   behind `frameLock` exactly like `CameraCapture.latestBuffer`, because
///   `ARSessionDelegate` callbacks are not guaranteed to land on the main
///   actor and per-frame `@Observable` churn would thrash SwiftUI's
///   diffing for data no view reads directly anyway.
/// - Everything else (`captureStage`, `lockedPlaneTransform`) is
///   `@Observable` and mutated ONLY on the main actor: this class is
///   `@MainActor` by default, and the handful of `ARSessionDelegate`
///   methods that can run off-main are individually marked `nonisolated`
///   and hop back with `Task { @MainActor in ... }` before touching any of
///   it.
///
/// No session wiring into `CoachLiveSession` happens here — that's a later
/// chunk. This type stands alone and must simply compile (sim + device).
@Observable
@MainActor
final class ARTableCapture: NSObject {
    nonisolated private static let logger = Logger(subsystem: "com.lumiodatalabs.MahjongSensei", category: "artablecapture")

    // MARK: - Published (main-actor-only) state

    /// See `CaptureStage`'s doc for the full lifecycle. Starts `.starting`
    /// and, absent a call to `start()`, stays there.
    private(set) var captureStage: CaptureStage = .starting

    /// The locked table plane's anchor-local → world transform, already
    /// yaw-aligned and centered per `PlaneLockPolicy`'s LOCKED CONTRACT —
    /// exactly what `Recognition.TableProjection.planeTransform` expects.
    /// `nil` until `captureStage` first reaches `.tableLocked`.
    private(set) var lockedPlaneTransform: simd_float4x4?

    /// The locked plane's larger horizontal side in metres — the physical size
    /// the normalized [0,1] table space spans. Used to build the auto-partition
    /// `TableGeometry` at tracker-lock time so its central pond fraction maps to
    /// the real table. `nil` until `.tableLocked`.
    private(set) var lockedPlaneExtent: Double?

    // MARK: - Per-frame state (polled, not observed)

    // `@ObservationIgnored` on both: these are manually synchronized via
    // `frameLock` (not the Observation registrar) — a `let` of `Sendable`
    // type (`NSLock`) is already usable from any isolation domain, but
    // `_latestFrame` is mutated through it from a `nonisolated` delegate
    // callback, so it needs the explicit `nonisolated(unsafe)` opt-out.
    @ObservationIgnored private let frameLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _latestFrame: ARTableFrame?
    /// The most recent frame ARKit has delivered, cached behind a lock so
    /// it can be polled from any thread — mirrors
    /// `CameraCapture.latestBuffer`'s contract exactly. Written from
    /// `session(_:didUpdate:)` (not guaranteed main-actor); read by the
    /// (later) tracking loop.
    nonisolated var latestFrame: ARTableFrame? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestFrame
    }

    // MARK: - Internal (main-actor-only) bookkeeping

    private let session = ARSession()
    private var planeLockPolicy: PlaneLockPolicy?
    /// Whether the running configuration currently requests horizontal
    /// plane detection — tracked locally because `ARWorldTrackingConfiguration`
    /// doesn't expose the running session's live configuration back out.
    private var planeDetectionRequested = true
    /// `captureStage` immediately before a `.relocalizing` detour, restored
    /// once tracking recovers.
    private var stageBeforeRelocalizing: CaptureStage?
    /// The last torch state requested via `setTorch(_:)`, re-applied after
    /// any `session.run(_:)` re-configuration (see that method's doc — a
    /// config re-run can silently reset the torch to off).
    private var pendingTorchState: Bool?

    /// True once `ARWorldTrackingConfiguration` reports support — false on
    /// the Simulator (and any device lacking the needed sensors), which is
    /// exactly the case `start()` maps to `captureStage = .unavailable`.
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    override init() {
        super.init()
        session.delegate = self
    }

    // MARK: - Lifecycle

    /// Starts (or restarts from `.unavailable`/a fresh instance) world
    /// tracking with horizontal plane detection. No-op transitions:
    /// `captureStage = .unavailable` immediately when ARKit isn't
    /// supported (the Simulator path) instead of calling `session.run`.
    func start() {
        guard Self.isSupported else {
            captureStage = .unavailable
            return
        }
        captureStage = .starting
        lockedPlaneTransform = nil
        lockedPlaneExtent = nil
        planeLockPolicy = nil
        planeDetectionRequested = true
        session.run(Self.makeConfiguration(planeDetection: true))
    }

    /// Pauses the underlying `ARSession` (e.g. app backgrounding). Cheap
    /// and reversible — `resume()` continues the same world-tracking
    /// session rather than re-finding the table from scratch.
    func pause() {
        session.pause()
    }

    /// Resumes a previously paused session, preserving whether plane
    /// detection had already been turned off at lock time. Re-applies the
    /// torch state if one was requested, since resuming re-runs the
    /// configuration (see `setTorch`'s doc).
    func resume() {
        guard Self.isSupported else { return }
        session.run(Self.makeConfiguration(planeDetection: planeDetectionRequested))
        if let pendingTorchState {
            setTorch(pendingTorchState)
        }
    }

    /// Advances to `.sweeping` — the guided post-lock sweep (Lane B chunk
    /// H): `CoachLiveSession.startARLoop` calls this immediately on table
    /// lock (instead of going straight to `.tracking`), inviting the user
    /// to pan across the table once before propping the phone. Also the
    /// entry point for the "Rescan table" affordance
    /// (`CoachLiveSession.rescanTable()`), which calls this again from
    /// `.tracking` mid-session — no tracker reset, the sweep card just
    /// reappears. No-op unless the table is already locked (or already
    /// mid-sweep/tracking).
    func enterSweeping() {
        guard captureStage == .tableLocked || captureStage == .tracking else { return }
        captureStage = .sweeping
    }

    /// Advances to `.tracking` — `CoachLiveSession.startARLoop` calls this
    /// once the guided sweep ends (Lane B chunk H: either the user's "Done"
    /// tap or the elapsed+coverage exit condition) and steady-state
    /// ingestion begins. No-op unless the table is already locked.
    func enterTracking() {
        guard captureStage == .tableLocked || captureStage == .sweeping else { return }
        captureStage = .tracking
    }

    /// Toggles the torch on the back wide-angle camera while the
    /// `ARSession` is running. This is community-proven to work alongside
    /// ARKit (ARKit owns the capture device but doesn't lock out torch
    /// control) but is NOT part of any documented ARKit contract — VERIFY
    /// ON DEVICE, and be ready to degrade to suggestion-only (Lane A's
    /// torch chip) if it proves flaky on a given iOS release. A
    /// `session.run(_:)` re-run (as `resume()` and the internal
    /// plane-detection-off reconfiguration both do) can silently reset the
    /// torch to off, since ARKit reclaims the capture device's
    /// configuration on each run; this method remembers the last requested
    /// state in `pendingTorchState` and both of those call sites re-apply
    /// it afterward.
    func setTorch(_ on: Bool) {
        pendingTorchState = on
        CameraTorch.set(on)
    }

    private static func makeConfiguration(planeDetection: Bool) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = planeDetection ? [.horizontal] : []
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .none
        // No `frameSemantics` opt-in (default `[]`) — this capture path
        // needs neither scene depth nor person segmentation, and both cost
        // real GPU/thermal budget.
        return configuration
    }

    // MARK: - Frame processing (main-actor only; delegate methods hop here)

    /// Caches the frame, transitions `.starting` → `.findingTable` on
    /// first arrival, and — while not yet locked — feeds `PlaneLockPolicy`
    /// the frame's horizontal-plane candidates. Promotes to
    /// `.tableLocked` and disables plane detection the instant the policy
    /// locks.
    private func processFrame(cameraTransform: simd_float4x4,
                              candidates: [PlaneLockPolicy.Candidate],
                              timestamp: TimeInterval) {
        if captureStage == .starting {
            captureStage = .findingTable
        }
        guard lockedPlaneTransform == nil, captureStage != .relocalizing else { return }

        if planeLockPolicy == nil {
            let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x,
                                              cameraTransform.columns.3.y,
                                              cameraTransform.columns.3.z)
            planeLockPolicy = PlaneLockPolicy(initialCameraPosition: cameraPosition)
        }
        planeLockPolicy?.update(candidates: candidates, cameraTransform: cameraTransform, t: timestamp)

        guard let locked = planeLockPolicy?.lockedPlane else { return }
        lockedPlaneTransform = locked.transform
        lockedPlaneExtent = locked.extent
        captureStage = .tableLocked
        Self.logger.notice("table plane locked (id: \(locked.id.uuidString, privacy: .public))")

        guard planeDetectionRequested else { return }
        planeDetectionRequested = false
        session.run(Self.makeConfiguration(planeDetection: false))
        if let pendingTorchState {
            setTorch(pendingTorchState)
        }
    }

    /// Sets/clears the `.relocalizing` detour, remembering (and later
    /// restoring) whichever stage was active beforehand.
    private func setRelocalizing(_ relocalizing: Bool) {
        if relocalizing {
            guard captureStage != .relocalizing else { return }
            stageBeforeRelocalizing = captureStage
            captureStage = .relocalizing
        } else {
            guard captureStage == .relocalizing else { return }
            captureStage = stageBeforeRelocalizing ?? (lockedPlaneTransform == nil ? .findingTable : .tableLocked)
            stageBeforeRelocalizing = nil
        }
    }

    /// Converts one `ARPlaneAnchor` into a `PlaneLockPolicy.Candidate`,
    /// applying the center-offset correction that struct's doc requires:
    /// `ARPlaneAnchor.transform` is anchor-origin → world, while
    /// `ARPlaneAnchor.center` is the plane's true center as a LOCAL-space
    /// offset from that origin — translating in local space before
    /// applying `transform` yields a world transform whose translation is
    /// the plane's actual center while leaving its orientation untouched.
    nonisolated private static func candidate(for anchor: ARPlaneAnchor) -> PlaneLockPolicy.Candidate {
        var localCenter = matrix_identity_float4x4
        localCenter.columns.3 = SIMD4<Float>(anchor.center, 1)
        let centeredTransform = anchor.transform * localCenter
        return PlaneLockPolicy.Candidate(id: anchor.identifier,
                                         transform: centeredTransform,
                                         extentX: anchor.planeExtent.width,
                                         extentZ: anchor.planeExtent.height)
    }
}

// MARK: - ARSessionDelegate

extension ARTableCapture: ARSessionDelegate {
    /// Not guaranteed to run on the main actor — caches the frame behind
    /// `frameLock` synchronously (cheap, matches `CameraCapture`'s own
    /// buffer-caching delegate callback), then hops the plane-lock/stage
    /// bookkeeping over to the main actor as plain `Sendable` values.
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let tableFrame = ARTableFrame(pixelBuffer: frame.capturedImage,
                                      cameraTransform: camera.transform,
                                      intrinsics: camera.intrinsics,
                                      imageResolution: camera.imageResolution,
                                      lightLux: frame.lightEstimate.map { Double($0.ambientIntensity) },
                                      timestamp: frame.timestamp)
        frameLock.lock()
        _latestFrame = tableFrame
        frameLock.unlock()

        let cameraTransform = camera.transform
        let timestamp = frame.timestamp
        let candidates = frame.anchors.compactMap { anchor -> PlaneLockPolicy.Candidate? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return nil }
            return Self.candidate(for: plane)
        }
        Task { @MainActor [weak self] in
            self?.processFrame(cameraTransform: cameraTransform, candidates: candidates, timestamp: timestamp)
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let isRelocalizing: Bool
        if case .limited(.relocalizing) = camera.trackingState {
            isRelocalizing = true
        } else {
            isRelocalizing = false
        }
        Task { @MainActor [weak self] in
            self?.setRelocalizing(isRelocalizing)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.setRelocalizing(true)
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.setRelocalizing(false)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Self.logger.error("ARSession failed: \(String(describing: error), privacy: .public)")
    }
}

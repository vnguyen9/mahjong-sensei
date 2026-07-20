import ARKit
import AVFoundation
import ImageIO
import Observation
import Recognition
import os

/// App-facing restore decision for the Coach Live flow. It deliberately
/// exposes outcome, not ARSession controls: `ARTableCapture` remains the sole
/// owner of session run/pause/reset behavior.
enum ARTableCalibrationRestoreStatus: Equatable {
    case none
    case restoring
    case restored
}

/// A small, DEBUG-visible audit trail for the only code paths allowed to
/// re-run ARKit configuration. The live calibration handoff must retain the
/// same `sessionID`; a later behavior change can use these facts to prove it
/// did not hide a tracking reset behind a UI transition.
struct ARSessionRunDiagnostics: Equatable {
    enum Reason: String, Equatable {
        case initialStart
        case restoreWorldMap
        case resume
        case retryDepthSemantics
        case disablePlaneDetection
        case freshTableLock
    }

    let sessionID = UUID()
    private(set) var configurationRunCount = 0
    private(set) var resetTrackingRunCount = 0
    private(set) var removeExistingAnchorsRunCount = 0
    private(set) var lastRunUsedResetTracking = false
    private(set) var lastRunUsedRemoveExistingAnchors = false
    private(set) var lastReason: Reason?

    mutating func record(options: ARSession.RunOptions, reason: Reason) {
        configurationRunCount += 1
        lastReason = reason
        lastRunUsedResetTracking = options.contains(.resetTracking)
        lastRunUsedRemoveExistingAnchors = options.contains(.removeExistingAnchors)
        if lastRunUsedResetTracking { resetTrackingRunCount += 1 }
        if lastRunUsedRemoveExistingAnchors { removeExistingAnchorsRunCount += 1 }
    }
}

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
    private(set) var lockedPlaneIdentifier: UUID?

    /// The locked plane's larger horizontal side in metres — the physical size
    /// the normalized [0,1] table space spans. Used to build the auto-partition
    /// `TableGeometry` at tracker-lock time so its central pond fraction maps to
    /// the real table. `nil` until `.tableLocked`.
    private(set) var lockedPlaneExtent: Double?

    /// Non-nil only while a saved world map has successfully supplied the
    /// named table-origin calibration for this launch.
    private(set) var restoredTableCalibration: WorldTableCalibration?

    /// `.restored` is emitted only after ARKit tracking is normal and the
    /// named table-origin anchor has been observed in the relocalized frame.
    var calibrationRestoreStatus: ARTableCalibrationRestoreStatus {
        if captureStage == .relocalizing { return .restoring }
        if restoredTableCalibration != nil,
           captureStage == .tableLocked || captureStage == .tracking {
            return .restored
        }
        return .none
    }

    /// Configuration-run diagnostics for the calibration → Live continuity
    /// audit. `sessionID` is allocated with this capture owner, rather than a
    /// frame, so it remains stable across a normal plane-lock reconfiguration.
    private(set) var sessionDiagnostics = ARSessionRunDiagnostics()

    // MARK: - Per-frame state (polled, not observed)

    // `@ObservationIgnored` on both: these are manually synchronized via
    // `frameLock` (not the Observation registrar) — a `let` of `Sendable`
    // type (`NSLock`) is already usable from any isolation domain, but
    // `_latestFrame` is mutated through it from a `nonisolated` delegate
    // callback, so it needs the explicit `nonisolated(unsafe)` opt-out.
    @ObservationIgnored private let frameLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var _latestFrame: ARTableFrame?
    @ObservationIgnored private let orientationLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var imageOrientationRaw: UInt32 =
        CGImagePropertyOrientation.right.rawValue
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

    nonisolated func updateImageOrientation(
        _ orientation: CGImagePropertyOrientation
    ) {
        orientationLock.lock()
        imageOrientationRaw = orientation.rawValue
        orientationLock.unlock()
    }

    nonisolated private var currentImageOrientation: CGImagePropertyOrientation {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        return CGImagePropertyOrientation(rawValue: imageOrientationRaw) ?? .right
    }

    // MARK: - Internal (main-actor-only) bookkeeping

    private let session = ARSession()
    /// Calibration renders and raycasts through this session. ARTableCapture
    /// remains the only owner allowed to run, pause, reset, or delegate it.
    var sharedSession: ARSession { session }
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
    private var tableOriginAnchorID: UUID?
    private var tableOriginTransform: simd_float4x4?
    private var tableOriginExtent: SIMD2<Float>?
    private var tableCalibration: WorldTableCalibration?
    /// True only for an unsaved calibration-review update. It lets an initial
    /// cancellation remove the transient named origin without touching a
    /// previously accepted world-map archive.
    private var tableCalibrationIsDraft = false
    private var mappingIsSaveable = false
    private var restoringWorldMap = false
    private var relocalizationTimeoutTask: Task<Void, Never>?
    private var worldMapSaveTask: Task<Void, Never>?

    /// True once `ARWorldTrackingConfiguration` reports support — false on
    /// the Simulator (and any device lacking the needed sensors), which is
    /// exactly the case `start()` maps to `captureStage = .unavailable`.
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    nonisolated static var supportsSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

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
        lockedPlaneIdentifier = nil
        lockedPlaneExtent = nil
        restoredTableCalibration = nil
        tableCalibration = nil
        tableCalibrationIsDraft = false
        planeLockPolicy = nil
        planeDetectionRequested = true
        mappingIsSaveable = false

        if let restored = ARWorldMapStore.load() {
            restoringWorldMap = true
            restoredTableCalibration = restored.calibration
            tableCalibration = restored.calibration
            tableCalibrationIsDraft = false
            lockedPlaneTransform = restored.calibration.tableToWorld
            lockedPlaneIdentifier = nil
            lockedPlaneExtent = Double(
                (restored.calibration.extent.x
                    + restored.calibration.extent.y) * 0.5
            )
            tableOriginExtent = restored.calibration.extent
            tableOriginTransform = restored.calibration.tableToWorld
            tableOriginAnchorID = restored.worldMap.anchors.first {
                $0.name == ARWorldMapStore.tableOriginAnchorName
            }?.identifier
            planeDetectionRequested = false
            stageBeforeRelocalizing = .tableLocked
            captureStage = .relocalizing
            let configuration = Self.makeConfiguration(
                planeDetection: false,
                initialWorldMap: restored.worldMap
            )
            runConfiguration(
                configuration,
                options: [.resetTracking, .removeExistingAnchors],
                reason: .restoreWorldMap
            )
            scheduleRelocalizationTimeout()
        } else {
            restoringWorldMap = false
            runConfiguration(
                Self.makeConfiguration(planeDetection: true),
                reason: .initialStart
            )
        }
    }

    /// Pauses the underlying `ARSession` (e.g. app backgrounding). Cheap
    /// and reversible — `resume()` continues the same world-tracking
    /// session rather than re-finding the table from scratch.
    func pause() {
        saveWorldMapIfEligible()
        session.pause()
    }

    /// Resumes a previously paused session, preserving whether plane
    /// detection had already been turned off at lock time. Re-applies the
    /// torch state if one was requested, since resuming re-runs the
    /// configuration (see `setTorch`'s doc).
    func resume() {
        guard Self.isSupported else { return }
        runConfiguration(
            Self.makeConfiguration(planeDetection: planeDetectionRequested),
            reason: .resume
        )
        if let pendingTorchState {
            setTorch(pendingTorchState)
        }
    }

    /// Re-applies the current world-tracking configuration without resetting
    /// its map. Coach Live calls this once when a LiDAR-capable device stops
    /// supplying depth, before explicitly degrading to 2D counts.
    func retryDepthSemantics() {
        guard Self.isSupported, Self.supportsSceneDepth else { return }
        runConfiguration(
            Self.makeConfiguration(planeDetection: planeDetectionRequested),
            reason: .retryDepthSemantics
        )
        if let pendingTorchState {
            setTorch(pendingTorchState)
        }
    }

    /// Advances to `.tracking` immediately after table lock. Recounts are
    /// one-shot inference requests and never change the capture lifecycle.
    func enterTracking() {
        guard captureStage == .tableLocked else { return }
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

    /// One production AR raycast for manual pond-center correction. The
    /// point uses ARFrame's normalized image coordinates.
    func raycastWorldPoint(
        atNormalizedImagePoint point: CGPoint
    ) -> SIMD3<Float>? {
        guard let query = session.currentFrame?.raycastQuery(
            from: point,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        ), let result = session.raycast(query).first else {
            return nil
        }
        return SIMD3<Float>(
            result.worldTransform.columns.3.x,
            result.worldTransform.columns.3.y,
            result.worldTransform.columns.3.z
        )
    }

    /// Keeps exactly one named AR anchor for the fitted table origin. Tile
    /// tracks remain ordinary census data and are never promoted to ARAnchor.
    func updateTableCalibration(
        _ calibration: WorldTableCalibration,
        persist: Bool = true
    ) {
        let calibrationChanged = tableCalibration != calibration
        let originAlreadyMatches = tableOriginTransform.map {
            Self.transformsAreNear($0, calibration.tableToWorld)
        } == true && tableOriginExtent.map {
            simd_length($0 - calibration.extent) < 0.001
        } == true
        tableCalibration = calibration
        tableCalibrationIsDraft = !persist
        updateTableOrigin(
            transform: calibration.tableToWorld,
            extent: calibration.extent,
            persist: persist
        )
        if persist && calibrationChanged && originAlreadyMatches {
            scheduleWorldMapSave()
        }
    }

    func updateTableOrigin(
        transform: simd_float4x4,
        extent: SIMD2<Float>,
        persist: Bool = true
    ) {
        if let current = tableOriginTransform,
           Self.transformsAreNear(current, transform),
           simd_length(
               tableOriginExtent.map { $0 - extent }
                   ?? SIMD2<Float>(repeating: 1)
           ) < 0.001 {
            return
        }
        if let tableOriginAnchorID,
           let existing = session.currentFrame?.anchors.first(where: {
               $0.identifier == tableOriginAnchorID
           }) {
            session.remove(anchor: existing)
        }
        let anchor = ARAnchor(
            name: ARWorldMapStore.tableOriginAnchorName,
            transform: transform
        )
        session.add(anchor: anchor)
        tableOriginAnchorID = anchor.identifier
        tableOriginTransform = transform
        tableOriginExtent = extent
        if persist && tableCalibration != nil {
            scheduleWorldMapSave()
        }
    }

    /// Recalibration supersedes any previously archived coordinate frame.
    func invalidatePersistedCalibration() {
        ARWorldMapStore.discard()
        tableCalibration = nil
        tableCalibrationIsDraft = false
        worldMapSaveTask?.cancel()
        worldMapSaveTask = nil
    }

    /// Removes only an in-memory origin that has never been accepted: either
    /// the uncalibrated plane-centroid origin or a provisional guided draft.
    /// This is intentionally narrower than
    /// `invalidatePersistedCalibration()`: cancelling a first-run review must
    /// not delete an already accepted archive.
    func discardInMemoryUnacceptedOrigin() {
        guard tableCalibration == nil || tableCalibrationIsDraft else { return }
        if let tableOriginAnchorID,
           let existing = session.currentFrame?.anchors.first(where: {
               $0.identifier == tableOriginAnchorID
           }) {
            session.remove(anchor: existing)
        }
        tableOriginAnchorID = nil
        tableOriginTransform = nil
        tableOriginExtent = nil
        tableCalibration = nil
        tableCalibrationIsDraft = false
    }

    private static func makeConfiguration(
        planeDetection: Bool,
        initialWorldMap: ARWorldMap? = nil
    ) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = planeDetection ? [.horizontal] : []
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .none
        configuration.initialWorldMap = initialWorldMap
        // Depth is opt-in and LiDAR-only. Prefer ARKit's temporally smoothed
        // estimate, then fall back to per-frame scene depth. This helper is
        // reused for start, post-lock reconfiguration, and resume so the
        // selected semantic cannot be accidentally dropped.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        return configuration
    }

    /// Centralizes `ARSession.run` so DEBUG diagnostics distinguish the two
    /// legitimate recovery resets from ordinary configuration refreshes. The
    /// empty-options form intentionally calls ARKit's no-options overload,
    /// preserving the existing no-reset behavior exactly.
    private func runConfiguration(
        _ configuration: ARWorldTrackingConfiguration,
        options: ARSession.RunOptions = [],
        reason: ARSessionRunDiagnostics.Reason
    ) {
        sessionDiagnostics.record(options: options, reason: reason)
        if options.isEmpty {
            session.run(configuration)
        } else {
            session.run(configuration, options: options)
        }
    }

    // MARK: - Frame processing (main-actor only; delegate methods hop here)

    /// Caches the frame, transitions `.starting` → `.findingTable` on
    /// first arrival, and — while not yet locked — feeds `PlaneLockPolicy`
    /// the frame's horizontal-plane candidates. Promotes to
    /// `.tableLocked` and disables plane detection the instant the policy
    /// locks.
    private func processFrame(cameraTransform: simd_float4x4,
                              candidates: [PlaneLockPolicy.Candidate],
                              restoredOrigin: ARAnchor?,
                              trackingIsNormal: Bool,
                              mappingIsSaveable: Bool,
                              timestamp: TimeInterval) {
        self.mappingIsSaveable = mappingIsSaveable
        if restoringWorldMap {
            guard trackingIsNormal, let restoredOrigin,
                  var calibration = restoredTableCalibration else {
                return
            }
            calibration.tableToWorld = restoredOrigin.transform
            calibration.source = .restoredWorldMap
            restoredTableCalibration = calibration
            tableCalibration = calibration
            tableOriginAnchorID = restoredOrigin.identifier
            tableOriginTransform = restoredOrigin.transform
            tableOriginExtent = calibration.extent
            lockedPlaneTransform = restoredOrigin.transform
            lockedPlaneExtent = Double(
                (calibration.extent.x + calibration.extent.y) * 0.5
            )
            restoringWorldMap = false
            relocalizationTimeoutTask?.cancel()
            relocalizationTimeoutTask = nil
            stageBeforeRelocalizing = nil
            captureStage = .tableLocked
            Self.logger.notice(
                "world map relocalized with named table origin"
            )
            return
        }
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
        lockedPlaneIdentifier = locked.id
        lockedPlaneExtent = locked.extent
        captureStage = .tableLocked
        Self.logger.notice("table plane locked (id: \(locked.id.uuidString, privacy: .public))")

        guard planeDetectionRequested else { return }
        planeDetectionRequested = false
        runConfiguration(
            Self.makeConfiguration(planeDetection: false),
            reason: .disablePlaneDetection
        )
        if let pendingTorchState {
            setTorch(pendingTorchState)
        }
    }

    private func scheduleRelocalizationTimeout() {
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  let self,
                  self.restoringWorldMap,
                  self.captureStage == .relocalizing else { return }
            Self.logger.notice("saved world map did not relocalize in 8s; starting fresh")
            ARWorldMapStore.discard()
            self.beginFreshTableLock()
        }
    }

    private func beginFreshTableLock() {
        restoringWorldMap = false
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = nil
        captureStage = .starting
        stageBeforeRelocalizing = nil
        lockedPlaneTransform = nil
        lockedPlaneIdentifier = nil
        lockedPlaneExtent = nil
        restoredTableCalibration = nil
        tableOriginAnchorID = nil
        tableOriginTransform = nil
        tableOriginExtent = nil
        tableCalibration = nil
        planeLockPolicy = nil
        planeDetectionRequested = true
        mappingIsSaveable = false
        runConfiguration(
            Self.makeConfiguration(planeDetection: true),
            options: [.resetTracking, .removeExistingAnchors],
            reason: .freshTableLock
        )
    }

    private func scheduleWorldMapSave() {
        worldMapSaveTask?.cancel()
        worldMapSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.saveWorldMapIfEligible()
        }
    }

    private func saveWorldMapIfEligible() {
        guard mappingIsSaveable, let calibration = tableCalibration else {
            return
        }
        session.getCurrentWorldMap { worldMap, error in
            guard let worldMap, error == nil else {
                Self.logger.error("unable to capture ARWorldMap")
                return
            }
            guard let origin = worldMap.anchors.first(where: {
                $0.name == ARWorldMapStore.tableOriginAnchorName
            }) else {
                Self.logger.error(
                    "refusing to save world map without named table origin"
                )
                return
            }
            var anchoredCalibration = calibration
            anchoredCalibration.tableToWorld = origin.transform
            do {
                try ARWorldMapStore.save(
                    worldMap: worldMap,
                    calibration: anchoredCalibration
                )
            } catch {
                Self.logger.error(
                    "unable to archive ARWorldMap: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private static func transformsAreNear(
        _ lhs: simd_float4x4,
        _ rhs: simd_float4x4
    ) -> Bool {
        (0 ..< 4).allSatisfy {
            simd_length(lhs[$0] - rhs[$0]) < 0.001
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
        let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth
        let tableFrame = ARTableFrame(pixelBuffer: frame.capturedImage,
                                      cameraTransform: camera.transform,
                                      intrinsics: camera.intrinsics,
                                      imageResolution: camera.imageResolution,
                                      imageOrientation: currentImageOrientation,
                                      lightLux: frame.lightEstimate.map { Double($0.ambientIntensity) },
                                      depthMap: sceneDepth?.depthMap,
                                      depthConfidence: sceneDepth?.confidenceMap,
                                      timestamp: frame.timestamp)
        frameLock.lock()
        _latestFrame = tableFrame
        frameLock.unlock()

        let cameraTransform = camera.transform
        let timestamp = frame.timestamp
        let mappingIsSaveable = frame.worldMappingStatus == .extending
            || frame.worldMappingStatus == .mapped
        let restoredOrigin = frame.anchors.first {
            $0.name == ARWorldMapStore.tableOriginAnchorName
        }
        let trackingIsNormal: Bool
        if case .normal = frame.camera.trackingState {
            trackingIsNormal = true
        } else {
            trackingIsNormal = false
        }
        let candidates = frame.anchors.compactMap { anchor -> PlaneLockPolicy.Candidate? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return nil }
            return Self.candidate(for: plane)
        }
        Task { @MainActor [weak self] in
            self?.processFrame(
                cameraTransform: cameraTransform,
                candidates: candidates,
                restoredOrigin: restoredOrigin,
                trackingIsNormal: trackingIsNormal,
                mappingIsSaveable: mappingIsSaveable,
                timestamp: timestamp
            )
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let trackingState = camera.trackingState
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch trackingState {
            case .normal:
                if !self.restoringWorldMap {
                    self.setRelocalizing(false)
                }
            case .limited(.relocalizing):
                self.setRelocalizing(true)
            default:
                break
            }
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.setRelocalizing(true)
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        // Wait for cameraDidChangeTrackingState(.normal); leaving the detour
        // before ARKit trusts the pose would make visibility misses unsafe.
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Self.logger.error("ARSession failed: \(String(describing: error), privacy: .public)")
    }
}

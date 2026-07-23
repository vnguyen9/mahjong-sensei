#if DEBUG
import ARKit
import RealityKit
import SwiftUI
import UIKit

/// Which built-in ARKit capabilities the Model Lab's AR stress-test mode runs.
/// Each is an independent toggle so the frame-rate cost of every feature can be
/// isolated against the detector load.
struct ModelLabAROptions: Equatable {
    var showPlanes = true          // planeDetection h+v, drawn as our own ~15% entities
    var showFeaturePoints = false  // .showFeaturePoints + .showWorldOrigin
    var lidarDepth = false         // frameSemantics .smoothedSceneDepth (fallback .sceneDepth)
    var sceneMesh = false          // sceneReconstruction .mesh + .showSceneUnderstanding
    var peopleOcclusion = false    // frameSemantics .personSegmentationWithDepth
    var statsBar = false           // .showStatistics — Apple's huge overlay; opt-in only

    /// Gates the whole AR chip (false on the Simulator).
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    static var supportsDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
    static var supportsMesh: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
    static var supportsPeople: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth)
    }
}

/// One ARKit camera frame published for the Lab's detector loop — mirrors the
/// `CameraFrame` shape the loop already polls off `CameraCapture`.
struct LabARFrame {
    let pixelBuffer: CVPixelBuffer
    let imageOrientation: CGImagePropertyOrientation
    let sequenceNumber: UInt64
    let timestamp: TimeInterval
    /// Centre sample of the LiDAR depth map (metres), when depth is enabled.
    let centerDepthMetres: Double?
}

/// Owns the Lab's `ARView` + `ARSession` and publishes frames/metrics for the
/// detector loop. RealityKit's built-in `debugOptions` render every requested
/// visualization (planes, feature points, mesh, stats) — no custom 3D content.
///
/// Only one party may own the camera: the Lab stops its `CameraCapture` before
/// starting this source (the Coach Live handoff pattern). Frame publishing uses
/// the same lock-guarded poll idiom as `CameraCapture.latestFrame` /
/// `ARTableCapture.latestFrame`.
@MainActor
final class ModelLabARSource: NSObject, ARSessionDelegate {
    let arView: ARView

    private let frameLock = NSLock()
    nonisolated(unsafe) private var _latestFrame: LabARFrame?
    nonisolated(unsafe) private var _sequence: UInt64 = 0
    nonisolated(unsafe) private var _arFPS = 0.0
    nonisolated(unsafe) private var _droppedFrames = 0
    nonisolated(unsafe) private var _lastTimestamp: TimeInterval?
    nonisolated(unsafe) private var _expectedInterval = 1.0 / 60.0
    nonisolated(unsafe) private var _statusNote: String?
    nonisolated(unsafe) private var _wantsDepthSample = false
    nonisolated(unsafe) private var _wantsHeatmap = false
    nonisolated(unsafe) private var _depthImage: CGImage?
    /// Torch survives `session.run` reconfigs only if re-asserted (ARKit
    /// silently resets it) — the `ARTableCapture.pendingTorchState` pattern.
    private var pendingTorch = false

    // Custom plane rendering (main-actor only): faint entities replace
    // RealityKit's fixed-opacity `.showAnchorGeometry`.
    private struct PlaneViz {
        let anchor: AnchorEntity
        let plane: ModelEntity
        var extent: SIMD2<Float>
    }
    private var planes: [UUID: PlaneViz] = [:]
    private var planesEnabled = true

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar,
                        automaticallyConfigureSession: false)
        super.init()
        arView.session.delegate = self
    }

    // MARK: - Lifecycle

    func start(_ options: ModelLabAROptions) {
        apply(options)
    }

    func stop() {
        arView.session.pause()
        frameLock.lock()
        _latestFrame = nil
        _lastTimestamp = nil
        frameLock.unlock()
    }

    func setTorch(_ on: Bool) {
        pendingTorch = on
        CameraTorch.set(on)
    }

    /// Heatmap on/off is display-only — deliberately NOT part of `apply()`,
    /// so flipping it never re-runs the AR session.
    func setHeatmapEnabled(_ on: Bool) {
        frameLock.lock()
        _wantsHeatmap = on
        if !on { _depthImage = nil }
        frameLock.unlock()
    }

    /// (Re)runs the session for the given toggles. Default run options keep the
    /// world map, so flipping a feature doesn't restart tracking from scratch.
    func apply(_ options: ModelLabAROptions) {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = options.showPlanes ? [.horizontal, .vertical] : []
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        var semantics: ARConfiguration.FrameSemantics = []
        if options.lidarDepth {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                semantics.insert(.smoothedSceneDepth)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                semantics.insert(.sceneDepth)
            }
        }
        if options.peopleOcclusion, ModelLabAROptions.supportsPeople {
            semantics.insert(.personSegmentationWithDepth)
        }
        config.frameSemantics = semantics
        if options.sceneMesh, ModelLabAROptions.supportsMesh {
            config.sceneReconstruction = .mesh
        }

        frameLock.lock()
        _wantsDepthSample = options.lidarDepth
        _arFPS = 0
        _droppedFrames = 0
        _lastTimestamp = nil
        _expectedInterval = 1.0 / Double(max(1, config.videoFormat.framesPerSecond))
        _statusNote = nil
        frameLock.unlock()

        arView.session.run(config)

        var debug: ARView.DebugOptions = []
        if options.showFeaturePoints {
            debug.insert(.showFeaturePoints)
            debug.insert(.showWorldOrigin)
        }
        if options.sceneMesh { debug.insert(.showSceneUnderstanding) }
        if options.statsBar { debug.insert(.showStatistics) }
        arView.debugOptions = debug

        planesEnabled = options.showPlanes
        if options.showPlanes {
            // ARKit won't re-fire didAdd for anchors that survived the re-run.
            rebuildPlanesFromSession()
        } else {
            removeAllPlanes()
        }

        if pendingTorch { CameraTorch.set(true) }
    }

    // MARK: - Custom plane visualization (~15% "barely-there" wash)

    /// Sendable slice of an `ARPlaneAnchor` for the delegate → main-actor hop.
    private struct PlaneSnapshot: Sendable {
        let id: UUID
        let transform: simd_float4x4
        let center: SIMD3<Float>
        let width: Float
        let depth: Float
        let yaw: Float
    }

    nonisolated private static func snapshot(_ anchor: ARPlaneAnchor) -> PlaneSnapshot {
        PlaneSnapshot(id: anchor.identifier,
                      transform: anchor.transform,
                      center: anchor.center,
                      width: anchor.planeExtent.width,
                      depth: anchor.planeExtent.height,
                      yaw: anchor.planeExtent.rotationOnYAxis)
    }

    private static func planeMaterial() -> UnlitMaterial {
        var material = UnlitMaterial(color: UIColor(red: 0.25, green: 0.85, blue: 0.60, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.15))
        return material
    }

    private func upsertPlane(_ snap: PlaneSnapshot) {
        guard planesEnabled else { return }
        if var viz = planes[snap.id] {
            viz.anchor.transform = Transform(matrix: snap.transform)
            viz.plane.position = snap.center
            viz.plane.orientation = simd_quatf(angle: snap.yaw, axis: [0, 1, 0])
            // Regenerate the mesh only on meaningful growth — not every frame.
            if abs(viz.extent.x - snap.width) > 0.02 || abs(viz.extent.y - snap.depth) > 0.02 {
                viz.plane.model?.mesh = .generatePlane(width: snap.width, depth: snap.depth)
                viz.extent = [snap.width, snap.depth]
                planes[snap.id] = viz
            }
        } else {
            let anchorEntity = AnchorEntity(world: snap.transform)
            let plane = ModelEntity(mesh: .generatePlane(width: snap.width, depth: snap.depth),
                                    materials: [Self.planeMaterial()])
            plane.position = snap.center
            plane.orientation = simd_quatf(angle: snap.yaw, axis: [0, 1, 0])
            anchorEntity.addChild(plane)
            arView.scene.addAnchor(anchorEntity)
            planes[snap.id] = PlaneViz(anchor: anchorEntity, plane: plane,
                                       extent: [snap.width, snap.depth])
        }
    }

    private func removePlane(_ id: UUID) {
        guard let viz = planes.removeValue(forKey: id) else { return }
        arView.scene.removeAnchor(viz.anchor)
    }

    private func removeAllPlanes() {
        for viz in planes.values { arView.scene.removeAnchor(viz.anchor) }
        planes.removeAll()
    }

    private func rebuildPlanesFromSession() {
        let anchors = arView.session.currentFrame?.anchors ?? []
        for case let anchor as ARPlaneAnchor in anchors {
            upsertPlane(Self.snapshot(anchor))
        }
    }

    // MARK: - Published state (polled from the Lab's loop)

    nonisolated var latestFrame: LabARFrame? {
        frameLock.lock(); defer { frameLock.unlock() }
        return _latestFrame
    }

    nonisolated var arFPS: Double {
        frameLock.lock(); defer { frameLock.unlock() }
        return _arFPS
    }

    nonisolated var droppedFrames: Int {
        frameLock.lock(); defer { frameLock.unlock() }
        return _droppedFrames
    }

    nonisolated var statusNote: String? {
        frameLock.lock(); defer { frameLock.unlock() }
        return _statusNote
    }

    nonisolated var depthImage: CGImage? {
        frameLock.lock(); defer { frameLock.unlock() }
        return _depthImage
    }

    // MARK: - ARSessionDelegate

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        upsertFromDelegate(anchors)
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        upsertFromDelegate(anchors)
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let ids = anchors.compactMap { ($0 as? ARPlaneAnchor)?.identifier }
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            for id in ids { self.removePlane(id) }
        }
    }

    nonisolated private func upsertFromDelegate(_ anchors: [ARAnchor]) {
        let snapshots = anchors.compactMap { ($0 as? ARPlaneAnchor).map(Self.snapshot) }
        guard !snapshots.isEmpty else { return }
        Task { @MainActor in
            for snapshot in snapshots { self.upsertPlane(snapshot) }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameLock.lock()
        _sequence &+= 1
        var depth: Double?
        if _wantsDepthSample,
           let map = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap {
            depth = Self.centerDepth(map)
            if _wantsHeatmap, _sequence % 6 == 0 {   // ~10 Hz — plenty for a viz
                _depthImage = Self.heatmapImage(from: map)
            }
        }
        if let last = _lastTimestamp {
            let delta = frame.timestamp - last
            if delta > 0 {
                let instant = 1 / delta
                _arFPS = _arFPS == 0 ? instant : _arFPS * 0.9 + instant * 0.1
                if delta > _expectedInterval * 1.5 { _droppedFrames += 1 }
            }
        }
        _lastTimestamp = frame.timestamp
        // The Lab runs portrait; ARKit's captured image is landscape → `.right`
        // (the Coach Live convention, ARTableFrame's doc).
        _latestFrame = LabARFrame(pixelBuffer: frame.capturedImage,
                                  imageOrientation: .right,
                                  sequenceNumber: _sequence,
                                  timestamp: frame.timestamp,
                                  centerDepthMetres: depth)
        frameLock.unlock()
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        frameLock.lock(); _statusNote = "AR interrupted"; frameLock.unlock()
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        frameLock.lock(); _statusNote = nil; frameLock.unlock()
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        frameLock.lock(); _statusNote = error.localizedDescription; frameLock.unlock()
    }

    /// Warm→cool color ramp, precomputed once (index = clamped depth/2.5m × 255).
    nonisolated(unsafe) private static let heatLUT: [(r: UInt8, g: UInt8, b: UInt8)] =
        (0..<256).map { i in
            // hue 0 (red, near) → 0.66 (blue, far)
            let hue = CGFloat(i) / 255 * 0.66
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            UIColor(hue: hue, saturation: 0.9, brightness: 1, alpha: 1)
                .getRed(&red, green: &green, blue: &blue, alpha: nil)
            return (UInt8(red * 255), UInt8(green * 255), UInt8(blue * 255))
        }

    /// The 256×192 landscape Float32 depth map rendered as a PORTRAIT-oriented
    /// RGBA heatmap (rotated `.right`, matching the displayed camera image).
    nonisolated private static func heatmapImage(from map: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let srcW = CVPixelBufferGetWidth(map)
        let srcH = CVPixelBufferGetHeight(map)
        guard srcW > 0, srcH > 0 else { return nil }
        let rowFloats = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.stride
        let src = base.assumingMemoryBound(to: Float32.self)
        let dstW = srcH, dstH = srcW   // 90° CW: landscape W×H → portrait H×W
        var pixels = [UInt8](repeating: 255, count: dstW * dstH * 4)
        for y in 0..<dstH {
            for x in 0..<dstW {
                // dest(x,y) = source(col: y, row: srcH-1-x) — the `.right` rotation.
                let depth = src[(srcH - 1 - x) * rowFloats + y]
                let t = depth.isFinite ? min(max(Double(depth) / 2.5, 0), 1) : 1
                let entry = heatLUT[Int(t * 255)]
                let offset = (y * dstW + x) * 4
                pixels[offset] = entry.r
                pixels[offset + 1] = entry.g
                pixels[offset + 2] = entry.b
            }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress, width: dstW, height: dstH,
                bitsPerComponent: 8, bytesPerRow: dstW * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    /// Centre pixel of a Float32 depth map (256×192 for LiDAR sceneDepth).
    nonisolated private static func centerDepth(_ map: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else {
            return nil
        }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        guard width > 0, height > 0 else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let row = base.advanced(by: (height / 2) * rowBytes)
            .assumingMemoryBound(to: Float32.self)
        let value = Double(row[width / 2])
        return value.isFinite && value > 0 ? value : nil
    }
}

/// Mounts the source's `ARView` as the Lab's feed while AR mode is on.
struct ModelLabARFeed: UIViewRepresentable {
    let source: ModelLabARSource

    func makeUIView(context: Context) -> ARView { source.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Measures the app's display refresh rate via `CADisplayLink` — the compact
/// stand-in for Apple's `.showStatistics` render-FPS readout (which is huge
/// and now opt-in). A stalled main thread shows up here as a dipping `ui` FPS.
@MainActor
final class DisplayLinkFPS: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private(set) var fps = 0.0

    func start() {
        guard link == nil else { return }
        let newLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        fps = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        if let last = lastTimestamp {
            let delta = link.timestamp - last
            if delta > 0 {
                let instant = 1 / delta
                fps = fps == 0 ? instant : fps * 0.9 + instant * 0.1
            }
        }
        lastTimestamp = link.timestamp
    }
}
#endif

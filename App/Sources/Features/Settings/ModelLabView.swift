#if DEBUG
import SwiftUI
import PhotosUI
import ImageIO
import QuartzCore
import UIKit
import DesignSystem
import Recognition
import MahjongCore

/// Dev-only live playground (Settings → Advanced → Model Lab): a full-screen
/// camera feed with real-time detector boxes, hot-swappable bundled models, an
/// FPS/latency readout, and live Confidence / NMS-IoU sliders — the
/// Ultralytics-app workflow, but for the bundled MJSS detectors.
///
/// Owns its own `CameraCapture` (Scan stops its camera whenever its tab is not
/// visible, and only one `AVCaptureSession` may hold the device at a time).
/// Inference decodes at a pinned 0.05 floor; the Confidence slider filters
/// in-UI so it responds instantly without re-running the model.
@Observable
@MainActor
final class ModelLabController {
    let camera = CameraCapture()

    // Model
    private(set) var selectedModel: DetectorModel = TileDetector.devModel
    private(set) var isLoadingModel = false
    private(set) var loadError: String?
    private var recognizer: VisionRecognizer?

    // Controls
    var confidence = 0.30          // UI-side filter — instant, no re-inference
    var iou = 0.55                 // applied per inference (free struct copy)
    var paused = false
    /// Master switch for inference itself — off clears the boxes immediately.
    var detectorEnabled = true {
        didSet {
            guard detectorEnabled != oldValue, !detectorEnabled else { return }
            detections = []
            fps = 0
            inferenceMs = 0
        }
    }
    var torchOn = false {
        didSet {
            if arMode { arSource?.setTorch(torchOn) } else { camera.setTorch(torchOn) }
        }
    }
    var lens: CameraLens = .wide { didSet { camera.setLens(lens) } }

    // AR stress-test mode (device only). ARKit owns the camera device, so the
    // AVCapture session stops while AR runs and the detector reads ARFrames.
    var arMode = false {
        didSet {
            guard arMode != oldValue else { return }
            switchSource()
        }
    }
    var arOptions = ModelLabAROptions() {
        didSet {
            guard arOptions != oldValue else { return }
            arSource?.apply(arOptions)
            arSource?.setHeatmapEnabled(arOptions.lidarDepth && depthHeatmapOn)
        }
    }
    /// Heatmap display toggle — display-only, never re-runs the AR session.
    var depthHeatmapOn = true {
        didSet { arSource?.setHeatmapEnabled(arOptions.lidarDepth && depthHeatmapOn) }
    }
    private(set) var arSource: ModelLabARSource?
    private let displayFPS = DisplayLinkFPS()

    // Output
    private(set) var detections: [DetectedTile] = []
    private(set) var orientedImageSize: CGSize = .zero
    private(set) var inferenceMs = 0.0     // EMA over recent inferences
    private(set) var fps = 0.0             // EMA of end-to-end inference rate

    // AR metrics (polled off the source each loop tick — HUD line 2)
    private(set) var arFPS = 0.0
    private(set) var arDropped = 0
    private(set) var arDepth: Double?
    private(set) var arDepthImage: CGImage?
    private(set) var arStatus: String?
    private(set) var uiFPS = 0.0
    private(set) var thermal: ProcessInfo.ThermalState = .nominal

    // Still-photo mode (one-shot inference on a picked library photo)
    var pickedItem: PhotosPickerItem?
    private(set) var stillImage: UIImage?
    private var stillFrame: RecognizerFrame?

    private var loopTask: Task<Void, Never>?
    private var lastSequence: UInt64 = 0

    /// Pinned decode floor — see the type doc.
    nonisolated static let decodeFloor = 0.05

    func start() {
        if arMode, let arSource {
            arSource.start(arOptions)
            arSource.setHeatmapEnabled(arOptions.lidarDepth && depthHeatmapOn)
            displayFPS.start()
        } else {
            camera.requestAndStart()
        }
        if recognizer == nil { loadModel(selectedModel) }
        guard loopTask == nil else { return }
        loopTask = Task { await runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        if torchOn { torchOn = false }
        arSource?.stop()
        displayFPS.stop()
        camera.stop()
    }

    func select(_ model: DetectorModel) {
        guard model != selectedModel || (recognizer == nil && !isLoadingModel) else { return }
        selectedModel = model
        loadModel(model)
    }

    /// Re-runs the frozen photo (IoU slider / model changes need a fresh pass;
    /// the confidence slider does not — it's a display filter).
    func refreshStill() {
        guard let stillFrame else { return }
        Task { await inferStill(stillFrame) }
    }

    func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let rawOrientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
            stillImage = UIImage(cgImage: image, scale: 1,
                                 orientation: UIImage.Orientation(labOrientation: orientation))
            let frame = RecognizerFrame.image(image, orientation: orientation)
            stillFrame = frame
            detections = []
            await inferStill(frame)
        }
    }

    func clearStill() {
        stillImage = nil
        stillFrame = nil
        pickedItem = nil
        detections = []
        orientedImageSize = .zero
    }

    // MARK: - Internals

    private func switchSource() {
        lastSequence = 0
        if arMode {
            clearStill()
            camera.stop()
            let source = arSource ?? ModelLabARSource()
            arSource = source
            source.start(arOptions)
            source.setHeatmapEnabled(arOptions.lidarDepth && depthHeatmapOn)
            displayFPS.start()
            if torchOn { source.setTorch(true) }
        } else {
            arSource?.stop()
            displayFPS.stop()
            arFPS = 0
            arDropped = 0
            arDepth = nil
            arDepthImage = nil
            arStatus = nil
            uiFPS = 0
            camera.requestAndStart()
            if torchOn { camera.setTorch(true) }
        }
    }

    /// Thermal always; AR metrics only while the AR source runs. Runs every
    /// loop tick INCLUDING while paused — pause is the ARKit-only baseline.
    private func refreshARStats() {
        thermal = ProcessInfo.processInfo.thermalState
        guard arMode, let arSource else { return }
        arFPS = arSource.arFPS
        arDropped = arSource.droppedFrames
        arDepth = arSource.latestFrame?.centerDepthMetres
        arDepthImage = arSource.depthImage
        arStatus = arSource.statusNote
        uiFPS = displayFPS.fps
    }

    /// The current source's newest frame, deduped by sequence number.
    private func nextLiveFrame() -> (buffer: CVPixelBuffer,
                                     orientation: CGImagePropertyOrientation,
                                     sequence: UInt64)? {
        if arMode {
            guard let frame = arSource?.latestFrame,
                  frame.sequenceNumber != lastSequence else { return nil }
            return (frame.pixelBuffer, frame.imageOrientation, frame.sequenceNumber)
        }
        guard let frame = camera.latestFrame,
              frame.sequenceNumber != lastSequence else { return nil }
        return (frame.pixelBuffer, frame.imageOrientation, frame.sequenceNumber)
    }

    private func loadModel(_ model: DetectorModel) {
        isLoadingModel = true
        loadError = nil
        let name = model.rawValue
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? VisionRecognizer(bundledModelNamed: name,
                                      confidenceThreshold: Self.decodeFloor)
            }.value
            guard selectedModel == model else { return }   // superseded by a newer pick
            recognizer = loaded
            isLoadingModel = false
            loadError = loaded == nil ? "\(name).mlmodelc not bundled" : nil
            refreshStill()
        }
    }

    /// One configured copy per inference: the struct copy is free and lets the
    /// IoU slider apply on the very next frame without reloading the model.
    private func tunedRecognizer() -> VisionRecognizer? {
        guard var tuned = recognizer else { return nil }
        tuned.confidenceThreshold = Self.decodeFloor
        tuned.nmsIoUThreshold = iou
        return tuned
    }

    private func runLoop() async {
        var lastCompleted = CACurrentMediaTime()
        while !Task.isCancelled {
            refreshARStats()
            guard detectorEnabled, !paused, stillImage == nil,
                  let tuned = tunedRecognizer(),
                  let frame = nextLiveFrame() else {
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            lastSequence = frame.sequence
            let recognizerFrame = RecognizerFrame.buffer(frame.buffer,
                                                         orientation: frame.orientation)
            let size = recognizerFrame.orientedPixelSize
            let started = CACurrentMediaTime()
            guard let result = try? await tuned.recognize(recognizerFrame) else {
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            let now = CACurrentMediaTime()
            let ms = (now - started) * 1000
            let delta = now - lastCompleted
            lastCompleted = now
            inferenceMs = inferenceMs == 0 ? ms : inferenceMs * 0.8 + ms * 0.2
            let instantFPS = delta > 0 ? 1 / delta : 0
            fps = fps == 0 ? instantFPS : fps * 0.8 + instantFPS * 0.2
            detections = result.tiles
            orientedImageSize = size
            // Yield so slider/HUD interaction stays responsive between frames.
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func inferStill(_ frame: RecognizerFrame) async {
        guard let tuned = tunedRecognizer() else { return }
        let started = CACurrentMediaTime()
        guard let result = try? await tuned.recognize(frame) else { return }
        inferenceMs = (CACurrentMediaTime() - started) * 1000
        fps = 0
        detections = result.tiles
        orientedImageSize = frame.orientedPixelSize
    }
}

struct ModelLabView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var controller = ModelLabController()
    @State private var showModelSettings = false

    var body: some View {
        @Bindable var controller = controller
        return ZStack {
            Color.black.ignoresSafeArea()

            feed.ignoresSafeArea()
            if controller.arMode, controller.arOptions.lidarDepth,
               controller.depthHeatmapOn, let depthImage = controller.arDepthImage {
                depthHeatmapOverlay(depthImage).ignoresSafeArea()
            }
            detectionOverlay.ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                modelChips
                if showModelSettings { modelSettingsPanel }
                if let error = controller.loadError {
                    Text(error)
                        .font(MJFont.ui(11, weight: .medium))
                        .foregroundStyle(MJColor.creamHeading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.red.opacity(0.55), in: Capsule())
                }
                Spacer()
                controls
            }
            .padding(16)

            if controller.arMode {
                VStack(alignment: .leading) {
                    arStatsBadge.padding(.top, 64)   // clears the 38pt back button
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 16)
                .allowsHitTesting(false)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .onChange(of: controller.iou) { controller.refreshStill() }
        .onChange(of: controller.pickedItem) { controller.loadPickedPhoto(controller.pickedItem) }
    }

    // MARK: - Feed + overlay

    @ViewBuilder private var feed: some View {
        if let still = controller.stillImage {
            GeometryReader { geo in
                Image(uiImage: still)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else if controller.arMode, let source = controller.arSource {
            ModelLabARFeed(source: source)
        } else {
            CameraPreview(camera: controller.camera)
        }
    }

    /// Full-feed LiDAR heatmap (warm = near, cool = far). Both the camera image
    /// and the depth map are 4:3 and aspect-filled, so they stay aligned.
    private func depthHeatmapOverlay(_ image: CGImage) -> some View {
        GeometryReader { geo in
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .opacity(0.45)
        }
        .allowsHitTesting(false)
    }

    /// One `Canvas` for all boxes. The canvas is coextensive with the feed
    /// (both fill the ZStack edge-to-edge), so its own bounds ARE the
    /// aspect-fill preview bounds `AspectFillMapping` expects.
    private var detectionOverlay: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let imageSize = controller.orientedImageSize
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            for detection in controller.detections
            where detection.confidence >= controller.confidence {
                let rect = AspectFillMapping.previewRect(ofNormalized: detection.box,
                                                         previewBounds: bounds,
                                                         orientedImageSize: imageSize)
                guard rect.width > 1, rect.height > 1 else { continue }
                let color = Self.color(for: detection.tile)
                context.stroke(Path(roundedRect: rect, cornerRadius: 4),
                               with: .color(color), lineWidth: 2)
                let label = context.resolve(
                    Text("\(detection.tile.code) \(Int((detection.confidence * 100).rounded()))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                )
                let textSize = label.measure(in: CGSize(width: 200, height: 40))
                // Not enough room above the box (dense scenes stack many boxes
                // near the top) — draw the chip inside the box's top edge
                // instead of letting it run off-canvas or over a neighbor.
                let chipY = rect.minY - textSize.height - 5 < 0
                    ? rect.minY
                    : rect.minY - textSize.height - 5
                let chip = CGRect(x: rect.minX,
                                  y: chipY,
                                  width: textSize.width + 8,
                                  height: textSize.height + 4)
                context.fill(Path(roundedRect: chip, cornerRadius: 3), with: .color(color))
                context.draw(label, at: CGPoint(x: chip.minX + 4 + textSize.width / 2,
                                                y: chip.midY))
            }
        }
        .allowsHitTesting(false)   // taps fall through to the preview's focus gesture
    }

    /// Suit-coded box colors so classes are tellable apart at a glance.
    private static func color(for tile: Tile) -> Color {
        switch tile {
        case .suited(.characters, _): return Color(red: 0.96, green: 0.45, blue: 0.40)
        case .suited(.dots, _):       return Color(red: 0.40, green: 0.78, blue: 0.94)
        case .suited(.bamboo, _):     return Color(red: 0.45, green: 0.86, blue: 0.50)
        case .wind, .dragon:          return MJColor.gold
        case .flower, .season:        return Color(red: 0.85, green: 0.55, blue: 0.95)
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        let hasStillImage = controller.stillImage != nil
        return HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MJColor.creamHeading)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.45), in: Circle())
            }
            Spacer()
            VStack(spacing: 1) {
                Text(controller.selectedModel.label)
                    .font(MJFont.ui(15, weight: .semibold))
                    .foregroundStyle(MJColor.creamHeading)
                Text(statsLine)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(MJColor.cream(0.8))
            }
            Spacer()
            HStack(spacing: 8) {
                if !controller.arMode {
                    PhotosPicker(selection: Bindable(controller).pickedItem,
                                 matching: .images) {
                        hudIcon("photo.on.rectangle", active: hasStillImage)
                    }
                }
                Button { controller.torchOn.toggle() } label: {
                    hudIcon(controller.torchOn ? "bolt.fill" : "bolt.slash.fill",
                            active: controller.torchOn)
                }
            }
        }
    }

    private var statsLine: String {
        if controller.isLoadingModel { return "loading model…" }
        if !controller.detectorEnabled { return "detector off" }
        let visible = controller.detections.filter { $0.confidence >= controller.confidence }.count
        if controller.stillImage != nil {
            return String(format: "photo · %.0f ms · %d tiles", controller.inferenceMs, visible)
        }
        if controller.paused { return "paused" }
        return String(format: "%.1f FPS · %.0f ms · %d tiles",
                      controller.fps, controller.inferenceMs, visible)
    }

    /// Compact AR metrics badge, pinned top-leading under the back button —
    /// the only chrome on the left edge, so nothing can cover it.
    private var arStatsBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "AR %.0f · ui %.0f", controller.arFPS, controller.uiFPS))
            Text(String(format: "drop %d · %@", controller.arDropped, thermalLabel))
            if let depth = controller.arDepth {
                Text(String(format: "d %.2fm", depth))
            }
            if let status = controller.arStatus {
                Text(status).lineLimit(1)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(MJColor.gold)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var thermalLabel: String {
        switch controller.thermal {
        case .nominal: return "nom"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "CRITICAL"
        @unknown default: return "?"
        }
    }

    private var modelChips: some View {
        HStack(spacing: 8) {
            ForEach(DetectorModel.allCases) { model in
                let selected = model == controller.selectedModel
                Button { controller.select(model) } label: {
                    Text(model.label)
                        .font(MJFont.ui(12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .black : MJColor.creamHeading)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(selected ? AnyShapeStyle(MJColor.gold)
                                             : AnyShapeStyle(.black.opacity(0.45)),
                                    in: Capsule())
                }
                .disabled(controller.isLoadingModel)
            }
            if controller.isLoadingModel {
                ProgressView().tint(MJColor.gold)
            }
            Button { showModelSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(showModelSettings ? .black : MJColor.creamHeading)
                    .padding(.horizontal, 9).padding(.vertical, 8)
                    .background(showModelSettings ? AnyShapeStyle(MJColor.gold)
                                                  : AnyShapeStyle(.black.opacity(0.45)),
                                in: Capsule())
            }
        }
    }

    /// Collapsible model settings, docked under the model chips: detector
    /// on/off (off clears the boxes) + the Confidence / NMS-IoU sliders.
    private var modelSettingsPanel: some View {
        @Bindable var controller = controller
        return VStack(spacing: 12) {
            Toggle(isOn: $controller.detectorEnabled) {
                Text("Tile detector")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MJColor.creamHeading)
            }
            .tint(MJColor.gold)
            sliderRow(title: String(format: "%.2f Confidence", controller.confidence),
                      value: $controller.confidence, range: 0.05...0.95)
            sliderRow(title: String(format: "%.2f NMS IoU", controller.iou),
                      value: $controller.iou, range: 0.10...0.90)
        }
        .padding(14)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if controller.arMode { arToggleChips }

            HStack(spacing: 10) {
                if controller.stillImage == nil, !controller.arMode,
                   controller.camera.availableBackLenses.count > 1 {
                    ForEach(controller.camera.availableBackLenses, id: \.self) { lens in
                        let active = lens == controller.lens
                        Button(lens.rawValue) { controller.lens = lens }
                            .font(MJFont.ui(13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? .black : MJColor.creamHeading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(active ? AnyShapeStyle(MJColor.gold)
                                               : AnyShapeStyle(.black.opacity(0.45)),
                                        in: Capsule())
                    }
                }
                Spacer()
                if controller.stillImage != nil {
                    Button {
                        controller.clearStill()
                    } label: {
                        Label("Live", systemImage: "video.fill")
                            .font(MJFont.ui(13, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(MJColor.gold, in: Capsule())
                    }
                } else {
                    if ModelLabAROptions.isSupported {
                        Button { controller.arMode.toggle() } label: {
                            Text("AR")
                                .font(MJFont.ui(13, weight: .bold))
                                .foregroundStyle(controller.arMode ? .black : MJColor.creamHeading)
                                .frame(width: 38, height: 38)
                                .background(controller.arMode ? AnyShapeStyle(MJColor.gold)
                                                              : AnyShapeStyle(.black.opacity(0.45)),
                                            in: Circle())
                        }
                    }
                    Button { controller.paused.toggle() } label: {
                        hudIcon(controller.paused ? "play.fill" : "pause.fill",
                                active: controller.paused)
                    }
                }
            }
        }
    }

    /// One chip per built-in ARKit feature — each independently toggleable so
    /// its frame-rate cost can be isolated. Unsupported features are dimmed.
    /// "Heat" (heatmap display, only while LiDAR is on) never re-runs the
    /// session; "Stats" is Apple's huge overlay, off by default.
    private var arToggleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                arChip("Planes", \.showPlanes, enabled: true)
                arChip("Points", \.showFeaturePoints, enabled: true)
                arChip("LiDAR", \.lidarDepth, enabled: ModelLabAROptions.supportsDepth)
                if controller.arOptions.lidarDepth { heatChip }
                arChip("Mesh", \.sceneMesh, enabled: ModelLabAROptions.supportsMesh)
                arChip("People", \.peopleOcclusion, enabled: ModelLabAROptions.supportsPeople)
                arChip("Stats", \.statsBar, enabled: true)
            }
        }
    }

    private var heatChip: some View {
        let on = controller.depthHeatmapOn
        return Button { controller.depthHeatmapOn.toggle() } label: {
            Text("Heat")
                .font(MJFont.ui(11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .black : MJColor.creamHeading)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(on ? AnyShapeStyle(MJColor.gold)
                               : AnyShapeStyle(.black.opacity(0.45)),
                            in: Capsule())
        }
    }

    private func arChip(_ title: String,
                        _ keyPath: WritableKeyPath<ModelLabAROptions, Bool>,
                        enabled: Bool) -> some View {
        let on = controller.arOptions[keyPath: keyPath]
        return Button { controller.arOptions[keyPath: keyPath].toggle() } label: {
            Text(title)
                .font(MJFont.ui(11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .black : MJColor.creamHeading)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(on ? AnyShapeStyle(MJColor.gold)
                               : AnyShapeStyle(.black.opacity(0.45)),
                            in: Capsule())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func sliderRow(title: String, value: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(MJColor.creamHeading)
            Slider(value: value, in: range)
                .tint(MJColor.gold)
        }
    }

    private func hudIcon(_ systemName: String, active: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(active ? MJColor.gold : MJColor.creamHeading)
            .frame(width: 38, height: 38)
            .background(.black.opacity(0.45), in: Circle())
    }
}

private extension UIImage.Orientation {
    init(labOrientation orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        }
    }
}
#endif

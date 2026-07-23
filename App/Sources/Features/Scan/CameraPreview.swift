import SwiftUI
import AVFoundation
import ImageIO
import UIKit
import Recognition

/// One raw camera buffer and the display transform that makes it upright in
/// the current window scene.  Capture consumers must take this snapshot rather
/// than reading `latestBuffer` and the orientation separately while a rotation
/// is in progress.
struct CameraFrame {
    let pixelBuffer: CVPixelBuffer
    let imageOrientation: CGImagePropertyOrientation
    let timestamp: TimeInterval
    let sequenceNumber: UInt64
    let cameraLens: CameraLens

    init(pixelBuffer: CVPixelBuffer,
         imageOrientation: CGImagePropertyOrientation,
         timestamp: TimeInterval,
         sequenceNumber: UInt64,
         cameraLens: CameraLens = .wide) {
        self.pixelBuffer = pixelBuffer
        self.imageOrientation = imageOrientation
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.cameraLens = cameraLens
    }
}

enum CameraLens: String, CaseIterable, Sendable {
    case ultraWide = "0.5×"
    case wide = "1×"
}

protocol TrackerPhotoCapturing: AnyObject {
    func captureTrackerStill(captureROI: TileBoundingBox?) async throws
        -> TrackerStillCapture
}

/// The shared live-camera seam. Score and What's This may inspect the latest
/// preview buffer; Tracker instead requests one quality-prioritized still and
/// never substitutes a preview frame when photo delivery fails.
final class CameraCapture: NSObject, TrackerPhotoCapturing, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "mahjong.camera.session")
    private let framesQueue = DispatchQueue(label: "mahjong.camera.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false
    private var videoInput: AVCaptureDeviceInput?
    private var sequenceNumber: UInt64 = 0
    private var preferredLens: CameraLens = .wide
    private var usesTrackerPhotoProfile = false
    let availableBackLenses: [CameraLens]

    /// The active back camera (ultra-wide 0.5× when available) — retained so the
    /// torch can be toggled.
    private var videoDevice: AVCaptureDevice?

    private let frameLock = NSLock()
    private var _latestBuffer: CVPixelBuffer?
    private var _latestFrame: CameraFrame?
    private var _activeLens: CameraLens = .wide
    private var _latestMotion = 0.0
    private var _latestMeanLuma = 128.0
    private var _trackerCaptureROI: TileBoundingBox?
    private let motionDetector = MotionDetector()
    private var photoDelegates: [Int64: TrackerPhotoDelegate] = [:]

    override init() {
        availableBackLenses = Self.discoverAvailableBackLenses()
        super.init()
    }

    private static func discoverAvailableBackLenses() -> [CameraLens] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        let types = Set(discovery.devices.map(\.deviceType))
        return CameraLens.allCases.filter { lens in
            switch lens {
            case .ultraWide: return types.contains(.builtInUltraWideCamera)
            case .wide: return types.contains(.builtInWideAngleCamera)
            }
        }
    }
    /// The most recent camera frame (retained so the shutter can recognize a fresh
    /// frame on demand). Written on the frames queue, read on the main thread.
    var latestBuffer: CVPixelBuffer? {
        frameLock.lock(); defer { frameLock.unlock() }
        return _latestBuffer
    }

    /// The orientation that makes the camera's native landscape buffer match
    /// the current window scene.  The buffer itself deliberately stays in its
    /// native orientation: Vision, ROI mapping, crop creation, and tiled
    /// recognition all receive this same transform instead of each attempting
    /// to infer the device's current pose.
    private var _imageOrientation: CGImagePropertyOrientation = .right
    var imageOrientation: CGImagePropertyOrientation {
        frameLock.lock(); defer { frameLock.unlock() }
        return _imageOrientation
    }

    var latestFrame: CameraFrame? {
        frameLock.lock(); defer { frameLock.unlock() }
        return _latestFrame
    }

    var trackerCaptureROI: TileBoundingBox? {
        frameLock.lock(); defer { frameLock.unlock() }
        return _trackerCaptureROI
    }

    fileprivate func publishTrackerCaptureROI(_ roi: TileBoundingBox?) {
        frameLock.lock()
        _trackerCaptureROI = roi
        frameLock.unlock()
    }

    // MARK: - Preview conversion (authoritative overlay geometry)

    /// The live preview layer and its containing view, registered by
    /// `CameraPreview.PreviewView` once it is attached to a window. Weak, so
    /// no manual teardown is needed. Overlays (Score/Tracker live detection
    /// boxes) use these to ask the layer itself where a detection box lands
    /// on screen instead of reconstructing the aspect-fill crop + rotation
    /// math independently (which can drift from what `videoGravity` and
    /// `videoRotationAngle` actually produce).
    private weak var previewConversionLayer: AVCaptureVideoPreviewLayer?
    private weak var previewConversionView: UIView?

    func registerPreviewConversion(layer: AVCaptureVideoPreviewLayer, view: UIView) {
        frameLock.lock()
        previewConversionLayer = layer
        previewConversionView = view
        frameLock.unlock()
    }

    /// Converts a rect in metadata-output (native, unrotated sensor buffer)
    /// space into this preview layer's local point space, via the layer's own
    /// authoritative conversion. `nil` until the preview has registered
    /// (e.g. the first few frames) — callers should fall back to the
    /// reconstructed aspect-fill math in that case so the overlay never goes
    /// blank.
    @MainActor
    func layerRect(fromMetadata rect: CGRect) -> CGRect? {
        frameLock.lock()
        let layer = previewConversionLayer
        frameLock.unlock()
        return layer?.layerRectConverted(fromMetadataOutputRect: rect)
    }

    /// Same conversion as ``layerRect(fromMetadata:)``, then mapped into
    /// window (global) coordinates via the preview's containing view — the
    /// same `convert(_:to:)` trick `updateTrackerReticle` uses in reverse
    /// (global → local) to bridge UIKit's window space and SwiftUI's
    /// `.global` coordinate space within the same window scene.
    @MainActor
    func globalRect(fromMetadata rect: CGRect) -> CGRect? {
        frameLock.lock()
        let layer = previewConversionLayer
        let view = previewConversionView
        frameLock.unlock()
        guard let layer, let view else { return nil }
        let localRect = layer.layerRectConverted(fromMetadataOutputRect: rect)
        return view.convert(localRect, to: nil)
    }

    func updateInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard orientation != .unknown else { return }
        let imageOrientation = orientation.scanCameraImageOrientation
        frameLock.lock()
        guard _imageOrientation != imageOrientation else {
            frameLock.unlock()
            return
        }
        // Do not let the last frame from the previous interface pose be
        // combined with the just-rotated preview/reticle geometry. The next
        // capture callback atomically publishes a fresh buffer + transform.
        _latestFrame = nil
        _imageOrientation = imageOrientation
        frameLock.unlock()
    }

    /// Requests camera access and starts the session if granted.
    func requestAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.sessionQueue.async { self.configureAndRun() }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Toggles the torch on the active camera. No-op if the device has none.
    func setTorch(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice, device.hasTorch,
                  (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    /// Switches the physical lens on the session queue. Tracker calls this
    /// only while idle, so a still scan uses one unambiguous camera geometry.
    func setLens(_ lens: CameraLens) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.preferredLens = lens
            // If startup has not configured the session yet, configureAndRun
            // will honor this choice. This avoids briefly adding both lenses.
            guard self.configured, let device = self.backCamera(for: lens) else { return }
            if self.videoDevice?.uniqueID == device.uniqueID { return }
            guard let replacement = try? AVCaptureDeviceInput(device: device) else { return }
            self.session.beginConfiguration()
            let previous = self.videoInput
            if let previous { self.session.removeInput(previous) }
            if self.session.canAddInput(replacement) {
                self.session.addInput(replacement)
                self.videoInput = replacement
                self.videoDevice = device
                self.publishActiveLens(for: device)
                self.configureContinuousCapture(on: device)
            } else if let previous, self.session.canAddInput(previous) {
                self.session.addInput(previous)
            }
            self.session.commitConfiguration()
            self.configurePhotoDimensions(for: device)
            self.frameLock.lock()
            self._latestFrame = nil
            self.frameLock.unlock()
        }
    }

    /// Tracker temporarily opts into the `.photo` session preset. Score and
    /// What's This return to their established 1080p preview profile.
    func setTrackerPhotoProfileEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.usesTrackerPhotoProfile = enabled
            guard self.configured else { return }
            let desired: AVCaptureSession.Preset = enabled ? .photo : .hd1920x1080
            let fallback: AVCaptureSession.Preset = enabled ? .hd1920x1080 : .hd1280x720
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(desired) {
                self.session.sessionPreset = desired
            } else if self.session.canSetSessionPreset(fallback) {
                self.session.sessionPreset = fallback
            }
            self.session.commitConfiguration()
            if enabled, let device = self.videoDevice {
                self.configurePhotoDimensions(for: device)
            }
        }
    }

    /// Captures exactly one processed still. `captureROI` is the normalized
    /// metadata rect published by the preview layer, so aspect-fill preview
    /// cropping cannot skew the 4:3 photo recognition region.
    func captureTrackerStill(captureROI: TileBoundingBox?) async throws -> TrackerStillCapture {
        let readinessStart = ContinuousClock.now
        let deadline = readinessStart.advanced(by: .milliseconds(500))
        while ContinuousClock.now < deadline {
            let ready = captureReadinessSnapshot()
            if ready.hasFrame && !ready.adjustingFocus && !ready.adjustingExposure
                && ready.motion <= 0.12 && (20...240).contains(ready.meanLuma) {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let readiness = captureReadinessSnapshot()
        guard readiness.hasFrame else { throw TrackerPhotoCaptureError.cameraNotReady }
        guard (20...240).contains(readiness.meanLuma) else {
            throw TrackerPhotoCaptureError.moreLightNeeded
        }
        guard !readiness.adjustingFocus, !readiness.adjustingExposure,
              readiness.motion <= 0.12 else {
            throw TrackerPhotoCaptureError.holdSteadier
        }
        let readinessDuration = readinessStart.duration(to: .now).timeInterval
        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else {
                    continuation.resume(throwing: TrackerPhotoCaptureError.cameraNotReady)
                    return
                }
                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [
                        AVVideoCodecKey: AVVideoCodecType.hevc
                    ])
                } else {
                    settings = AVCapturePhotoSettings(format: [
                        AVVideoCodecKey: AVVideoCodecType.jpeg
                    ])
                }
                settings.photoQualityPrioritization = .quality
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                let snapshot = self.photoContextSnapshot()
                let photoROI = captureROI.map {
                    self.photoOutput.outputRectConverted(fromMetadataOutputRect: $0.cgRect)
                }
                let startedAt = ContinuousClock.now
                let delegate = TrackerPhotoDelegate(
                    context: snapshot,
                    roi: photoROI.map(TileBoundingBox.init),
                    readinessDuration: readinessDuration,
                    startedAt: startedAt,
                    completion: { [weak self] result in
                        self?.sessionQueue.async {
                            self?.photoDelegates[settings.uniqueID] = nil
                        }
                        continuation.resume(with: result)
                    }
                )
                self.photoDelegates[settings.uniqueID] = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice,
                  (try? device.lockForConfiguration()) != nil else { return }
            let point = CGPoint(x: min(max(devicePoint.x, 0), 1),
                                y: min(max(devicePoint.y, 0), 1))
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            device.unlockForConfiguration()
        }
    }

    private func captureReadinessSnapshot()
        -> (hasFrame: Bool, adjustingFocus: Bool, adjustingExposure: Bool,
            motion: Double, meanLuma: Double) {
        frameLock.lock()
        let hasFrame = _latestFrame != nil
        let motion = _latestMotion
        let meanLuma = _latestMeanLuma
        frameLock.unlock()
        return (hasFrame, videoDevice?.isAdjustingFocus ?? true,
                videoDevice?.isAdjustingExposure ?? true, motion, meanLuma)
    }

    private func photoContextSnapshot() -> TrackerPhotoDelegate.Context {
        frameLock.lock(); defer { frameLock.unlock() }
        let preview = _latestFrame.map {
            TrackerPhotoDelegate.Preview(buffer: $0.pixelBuffer,
                                         orientation: $0.imageOrientation)
        }
        return .init(lens: _activeLens, preview: preview,
                     timestamp: ProcessInfo.processInfo.systemUptime)
    }

    /// The 0.5× ultra-wide when the phone has one, else the standard wide angle.
    private func backCamera(for lens: CameraLens = .ultraWide) -> AVCaptureDevice? {
        switch lens {
        case .ultraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .wide:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        }
    }

    private func publishActiveLens(for device: AVCaptureDevice) {
        let lens: CameraLens = device.deviceType == .builtInUltraWideCamera
            ? .ultraWide : .wide
        frameLock.lock()
        _activeLens = lens
        frameLock.unlock()
    }

    private func configureContinuousCapture(on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.isSubjectAreaChangeMonitoringEnabled = true
        device.unlockForConfiguration()
    }

    private func configurePhotoDimensions(for device: AVCaptureDevice) {
        guard let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) else { return }
        photoOutput.maxPhotoDimensions = largest
        photoOutput.maxPhotoQualityPrioritization = .quality
    }

    private func configureAndRun() {
        if !configured {
            configured = true
            session.beginConfiguration()
            let desiredPreset: AVCaptureSession.Preset = usesTrackerPhotoProfile
                ? .photo : .hd1920x1080
            let fallbackPreset: AVCaptureSession.Preset = usesTrackerPhotoProfile
                ? .hd1920x1080 : .hd1280x720
            if session.canSetSessionPreset(desiredPreset) {
                session.sessionPreset = desiredPreset
            } else if session.canSetSessionPreset(fallbackPreset) {
                session.sessionPreset = fallbackPreset
            }
            if let device = backCamera(for: preferredLens),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                videoDevice = device
                videoInput = input
                publishActiveLens(for: device)
                configureContinuousCapture(on: device)
            }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            // No `videoSettings` pin — leave the output at iOS's default
            // `BGRA`, the format the proven scan/lookup path (`VisionRecognizer`
            // via `ScanCoordinator`) has always used. `MotionDetector` reads
            // BGRA too (see its own doc), so Coach Live's motion/breathing
            // signal doesn't need a dedicated pixel format either.
            videoOutput.setSampleBufferDelegate(self, queue: framesQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            if let device = videoDevice { configurePhotoDimensions(for: device) }
            session.commitConfiguration()
        }
        if !session.isRunning { session.startRunning() }
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Cache only the latest preview frame. Tracker never runs recognition
        // on this buffer and never records it as a movie.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let motion = motionDetector.sample(
            pixelBuffer,
            at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        )
        frameLock.lock()
        sequenceNumber &+= 1
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let frame = CameraFrame(pixelBuffer: pixelBuffer,
                                imageOrientation: _imageOrientation,
                                timestamp: timestamp.isFinite ? timestamp : ProcessInfo.processInfo.systemUptime,
                                sequenceNumber: sequenceNumber,
                                cameraLens: _activeLens)
        _latestBuffer = pixelBuffer
        _latestFrame = frame
        _latestMotion = motion?.level ?? 0
        _latestMeanLuma = motion?.meanLuma ?? 128
        frameLock.unlock()
    }
}

private final class TrackerPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    struct Preview {
        var buffer: CVPixelBuffer
        var orientation: CGImagePropertyOrientation
    }
    struct Context {
        var lens: CameraLens
        var preview: Preview?
        var timestamp: TimeInterval
    }

    private let context: Context
    private let roi: TileBoundingBox?
    private let readinessDuration: TimeInterval
    private let startedAt: ContinuousClock.Instant
    private let completion: (Result<TrackerStillCapture, Error>) -> Void
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(context: Context, roi: TileBoundingBox?, readinessDuration: TimeInterval,
         startedAt: ContinuousClock.Instant,
         completion: @escaping (Result<TrackerStillCapture, Error>) -> Void) {
        self.context = context
        self.roi = roi
        self.readinessDuration = readinessDuration
        self.startedAt = startedAt
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            completion(.failure(TrackerPhotoCaptureError.captureFailed(error.localizedDescription)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(TrackerPhotoCaptureError.noPhotoData)); return
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            completion(.failure(TrackerPhotoCaptureError.imageDecodeFailed)); return
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let rawOrientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        let previewImage: CGImage? = context.preview.flatMap { preview in
            let ciImage = CIImage(cvPixelBuffer: preview.buffer).oriented(preview.orientation)
            return imageContext.createCGImage(ciImage, from: ciImage.extent)
        }
        let previewSize = previewImage.map {
            CGSize(width: $0.width, height: $0.height)
        } ?? .zero
        let format = data.starts(with: [0xFF, 0xD8]) ? "JPEG" : "HEIC"
        completion(.success(TrackerStillCapture(
            id: UUID(), encodedPhotoData: data, encodedFormat: format,
            image: image, imageOrientation: orientation, previewImage: previewImage,
            previewPixelSize: previewSize,
            photoPixelSize: CGSize(width: image.width, height: image.height),
            cameraLens: context.lens, captureTimestamp: context.timestamp, roi: roi,
            cameraReadinessDuration: readinessDuration,
            photoDeliveryDuration: startedAt.duration(to: .now).timeInterval
        )))
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Screen-space camera preview. Overlays (reticle, boxes) are drawn on top in 2D —
/// no ARKit for the flat-hand MVP (per the plan's constraint).
struct CameraPreview: UIViewControllerRepresentable {
    let camera: CameraCapture
    let trackerReticleFrame: CGRect

    init(camera: CameraCapture, trackerReticleFrame: CGRect = .zero) {
        self.camera = camera
        self.trackerReticleFrame = trackerReticleFrame
    }

    func makeUIViewController(context: Context) -> PreviewController {
        PreviewController(camera: camera)
    }

    func updateUIViewController(_ uiViewController: PreviewController, context: Context) {
        uiViewController.updateTrackerReticle(trackerReticleFrame)
    }

    /// A controller boundary gives us UIKit's rotation-transition completion,
    /// when `effectiveGeometry.interfaceOrientation` is final.  Reading it
    /// only from a plain view's layout pass can race iPad's size transition.
    final class PreviewController: UIViewController {
        private let preview: PreviewView

        init(camera: CameraCapture) {
            preview = PreviewView(camera: camera)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() { view = preview }

        func updateTrackerReticle(_ globalRect: CGRect) {
            preview.updateTrackerReticle(globalRect)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview.publishInterfaceOrientation()
        }

        override func viewWillTransition(to size: CGSize,
                                         with coordinator: any UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.preview.publishInterfaceOrientation()
            }
        }
    }

    final class PreviewView: UIView {
        private let camera: CameraCapture

        init(camera: CameraCapture) {
            self.camera = camera
            super.init(frame: .zero)
            previewLayer.session = camera.session
            previewLayer.videoGravity = .resizeAspectFill
            let tap = UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:)))
            addGestureRecognizer(tap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            publishInterfaceOrientation()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishInterfaceOrientation()
            camera.registerPreviewConversion(layer: previewLayer, view: self)
        }

        /// Preview rotation and recognizer orientation are updated from one
        /// window-scene value.  Do not rotate `AVCaptureVideoDataOutput`: its
        /// native buffers are intentionally shared with Vision and all crop
        /// paths, which use `camera.imageOrientation` below.
        func publishInterfaceOrientation() {
            let orientation =
                window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            camera.updateInterfaceOrientation(orientation)
            let angle = orientation.scanCameraPreviewRotationAngle
            if let connection = previewLayer.connection,
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }

        func updateTrackerReticle(_ globalRect: CGRect) {
            guard globalRect.width > 0, globalRect.height > 0, window != nil else {
                camera.publishTrackerCaptureROI(nil)
                return
            }
            let localRect = convert(globalRect, from: nil)
            let metadataRect = previewLayer.metadataOutputRectConverted(fromLayerRect: localRect)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            camera.publishTrackerCaptureROI(metadataRect.isNull ? nil : TileBoundingBox(metadataRect))
        }

        @objc private func focusTapped(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: self)
            camera.focus(at: previewLayer.captureDevicePointConverted(fromLayerPoint: point))
            showFocusRing(at: point)
            UISelectionFeedbackGenerator().selectionChanged()
        }

        private func showFocusRing(at point: CGPoint) {
            let ring = UIView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
            ring.center = point
            ring.layer.borderColor = UIColor.systemYellow.cgColor
            ring.layer.borderWidth = 2
            ring.layer.cornerRadius = 8
            ring.alpha = 0
            addSubview(ring)
            UIView.animate(withDuration: 0.15, animations: {
                ring.alpha = 1
                ring.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
            }) { _ in
                UIView.animate(withDuration: 0.45, delay: 0.35, options: [], animations: {
                    ring.alpha = 0
                }) { _ in ring.removeFromSuperview() }
            }
        }
    }
}

private extension TileBoundingBox {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

/// The raw `AVCaptureVideoDataOutput` back-camera buffer is landscape. UIKit's
/// `landscapeLeft`/`landscapeRight` name the *interface*, which is opposite to
/// the physical device turn. Keep this mapping local to the non-AR capture
/// pipeline: ARKit has its own captured-image coordinate system and is already
/// calibrated through `ARFrame.displayTransform`.
extension UIInterfaceOrientation {
    /// ARKit's captured-image transform. This is intentionally separate from
    /// `scanCameraImageOrientation`: ARKit's image coordinates are not the
    /// `AVCaptureVideoDataOutput` rear-camera coordinates used by Scan.
    var cameraImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }

    private var scanCameraOrientation: ScanCameraOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    var scanCameraImageOrientation: CGImagePropertyOrientation {
        scanCameraOrientation.imageOrientation
    }

    var scanCameraPreviewRotationAngle: CGFloat {
        scanCameraOrientation.previewRotationAngle
    }
}

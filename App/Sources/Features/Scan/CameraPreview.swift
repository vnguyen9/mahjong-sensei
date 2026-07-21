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
}

/// The live-camera seam. Runs the back-camera session, drives the preview layer,
/// and caches the latest frame so the shutter can run the bundled Core ML detector
/// (`VisionRecognizer`) on demand. Falls back to `MockRecognizer` when no model is
/// bundled (e.g. the Simulator).
final class CameraCapture: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "mahjong.camera.session")
    private let framesQueue = DispatchQueue(label: "mahjong.camera.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false

    /// The active back camera (ultra-wide 0.5× when available) — retained so the
    /// torch can be toggled.
    private var videoDevice: AVCaptureDevice?

    private let frameLock = NSLock()
    private var _latestBuffer: CVPixelBuffer?
    private var _latestFrame: CameraFrame?
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

    /// The 0.5× ultra-wide when the phone has one, else the standard wide angle.
    private func bestBackCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configureAndRun() {
        if !configured {
            configured = true
            session.beginConfiguration()
            // 1080p when the lens supports it — the Score shutter crops the frame to
            // the reticle band, so more source pixels mean sharper per-tile reads.
            // Falls back to 720p on lenses that can't do it.
            session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .hd1280x720
            if let device = bestBackCamera(),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                videoDevice = device
            }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            // No `videoSettings` pin — leave the output at iOS's default
            // `BGRA`, the format the proven scan/lookup path (`VisionRecognizer`
            // via `ScanCoordinator`) has always used. `MotionDetector` reads
            // BGRA too (see its own doc), so Coach Live's motion/breathing
            // signal doesn't need a dedicated pixel format either.
            videoOutput.setSampleBufferDelegate(self, queue: framesQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            session.commitConfiguration()
        }
        if !session.isRunning { session.startRunning() }
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Cache the latest frame; the shutter runs `VisionRecognizer` on it on
        // demand. A future enhancement runs detection continuously here with a
        // stability gate to auto-lock (see the plan).
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        _latestBuffer = pixelBuffer
        _latestFrame = CameraFrame(pixelBuffer: pixelBuffer, imageOrientation: _imageOrientation)
        frameLock.unlock()
    }
}

/// Screen-space camera preview. Overlays (reticle, boxes) are drawn on top in 2D —
/// no ARKit for the flat-hand MVP (per the plan's constraint).
struct CameraPreview: UIViewControllerRepresentable {
    let camera: CameraCapture

    func makeUIViewController(context: Context) -> PreviewController {
        PreviewController(camera: camera)
    }

    func updateUIViewController(_ uiViewController: PreviewController, context: Context) {}

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

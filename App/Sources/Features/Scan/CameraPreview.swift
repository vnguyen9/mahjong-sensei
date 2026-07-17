import SwiftUI
import AVFoundation

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

    private let bufferLock = NSLock()
    private var _latestBuffer: CVPixelBuffer?
    /// The most recent camera frame (retained so the shutter can recognize a fresh
    /// frame on demand). Written on the frames queue, read on the main thread.
    var latestBuffer: CVPixelBuffer? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return _latestBuffer
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
            session.sessionPreset = .hd1280x720
            if let device = bestBackCamera(),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                videoDevice = device
            }
            videoOutput.alwaysDiscardsLateVideoFrames = true
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
        bufferLock.lock()
        _latestBuffer = pixelBuffer
        bufferLock.unlock()
    }
}

/// Screen-space camera preview. Overlays (reticle, boxes) are drawn on top in 2D —
/// no ARKit for the flat-hand MVP (per the plan's constraint).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

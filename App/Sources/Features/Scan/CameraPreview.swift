import SwiftUI
import AVFoundation

/// The live-camera seam. Runs the back-camera session and — once the detector
/// `.mlpackage` is bundled — will run a `VNCoreMLRequest` per frame on the Neural
/// Engine, publishing a `RecognitionResult`. Today it drives the preview only; the
/// app runs on `MockRecognizer` until the trained model ships (see PRD / plan).
final class CameraCapture: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "mahjong.camera.session")
    private let framesQueue = DispatchQueue(label: "mahjong.camera.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false

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

    private func configureAndRun() {
        if !configured {
            configured = true
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
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
        // SEAM: once the tile detector is exported to Core ML, run a VNCoreMLRequest
        // against CMSampleBufferGetImageBuffer(sampleBuffer) here (compute units =
        // .all → Neural Engine), map observations to [DetectedTile], debounce to a
        // stable frame (the stability gate), and publish a RecognitionResult on main.
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

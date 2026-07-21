import ARKit
import SwiftUI
import UIKit
import CoreImage
import ImageIO
import Metal
import QuartzCore

/// Lightweight ARKit camera preview: blits `ARTableCapture.latestFrame?
/// .pixelBuffer` through a `CIContext` onto a `CAMetalLayer`, driven by a
/// throttled `CADisplayLink`.
///
/// Deliberately NOT `ARView`/`ARSCNView` — Coach Live never draws any 3D
/// content over the feed (the brackets are a flat SwiftUI overlay,
/// `ZoneBracketsOverlay`), so paying for a full SceneKit/RealityKit
/// compositor here would be pure thermal waste for zero visual benefit (see
/// the Lane B plan's chunk F). A plain `CAMetalLayer`-backed `UIView` also
/// slots into `LiveFeedPane` exactly like `CameraPreview` does — the
/// existing privacy blur + chrome layers above it need no changes.
struct ARCameraPreview: UIViewRepresentable {
    let capture: ARTableCapture

    func makeUIView(context: Context) -> PreviewView { PreviewView(capture: capture) }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        private let capture: ARTableCapture
        private let metalLayer = CAMetalLayer()
        private let ciContext: CIContext
        private var displayLink: CADisplayLink?

        init(capture: ARTableCapture) {
            self.capture = capture
            let device = MTLCreateSystemDefaultDevice()
            self.ciContext = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
            super.init(frame: .zero)

            metalLayer.device = device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = false
            // No window yet at init — seed from the trait environment; the real
            // window-scene scale is applied in `layoutSubviews`.
            metalLayer.contentsScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
            layer.addSublayer(metalLayer)

            let link = CADisplayLink(target: self, selector: #selector(tick))
            // Thermal win (plan chunk F): halve the refresh rate rather than
            // matching the display's own — a static-propped-phone preview
            // doesn't need 60/120fps fidelity, only to look live.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit { displayLink?.invalidate() }

        override func layoutSubviews() {
            super.layoutSubviews()
            metalLayer.frame = bounds
            // Prefer the window scene's screen scale (iOS 26 replacement for the
            // deprecated `UIScreen.main`), falling back to the trait environment.
            let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
            if scale > 0 { metalLayer.contentsScale = scale }
            let effective = metalLayer.contentsScale
            metalLayer.drawableSize = CGSize(width: bounds.width * effective, height: bounds.height * effective)
            publishInterfaceOrientation()
        }

        @objc private func tick() {
            // Read the pixel buffer once, build the `CIImage` immediately,
            // and don't hold the `CVPixelBuffer` reference any longer than
            // this call needs it — ARKit reuses/retires buffers quickly and
            // this preview must never be the thing pinning one in memory.
            guard let frame = capture.sharedSession.currentFrame,
                  metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
                  let drawable = metalLayer.nextDrawable() else { return }
            let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let interfaceOrientation =
                window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            capture.updateInterfaceOrientation(interfaceOrientation)
            let displayed = Self.displayedImage(
                frame: frame,
                interfaceOrientation: interfaceOrientation,
                viewportSize: drawableSize
            )
            ciContext.render(displayed, to: drawable.texture, commandBuffer: nil,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            drawable.present()
        }

        private func publishInterfaceOrientation() {
            let orientation =
                window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            capture.updateInterfaceOrientation(orientation)
        }

        /// ARKit's display transform is the preview authority, including the
        /// orientation-specific aspect fill and crop.
        private static func displayedImage(
            frame: ARFrame,
            interfaceOrientation: UIInterfaceOrientation,
            viewportSize: CGSize
        ) -> CIImage {
            let raw = CIImage(cvPixelBuffer: frame.capturedImage)
            guard raw.extent.width > 0, raw.extent.height > 0,
                  viewportSize.width > 0, viewportSize.height > 0 else {
                return raw
            }
            let toUnit = CGAffineTransform(
                scaleX: 1 / raw.extent.width,
                y: 1 / raw.extent.height
            )
            let flipY = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
            let display = frame.displayTransform(
                for: interfaceOrientation,
                viewportSize: viewportSize
            )
            let toPixels = CGAffineTransform(
                scaleX: viewportSize.width,
                y: viewportSize.height
            )
            return raw
                .transformed(by: toUnit)
                .transformed(by: flipY)
                .transformed(by: display)
                .transformed(by: flipY)
                .transformed(by: toPixels)
        }
    }
}

extension UIInterfaceOrientation {
    var cameraImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }
}

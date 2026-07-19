import SwiftUI
import UIKit
import CoreImage
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
            metalLayer.contentsScale = UIScreen.main.scale
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
            let scale = metalLayer.contentsScale
            metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }

        @objc private func tick() {
            // Read the pixel buffer once, build the `CIImage` immediately,
            // and don't hold the `CVPixelBuffer` reference any longer than
            // this call needs it — ARKit reuses/retires buffers quickly and
            // this preview must never be the thing pinning one in memory.
            guard let pixelBuffer = capture.latestFrame?.pixelBuffer,
                  metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
                  let drawable = metalLayer.nextDrawable() else { return }
            let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
            let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let filled = Self.aspectFill(oriented, into: drawableSize)
            ciContext.render(filled, to: drawable.texture, commandBuffer: nil,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            drawable.present()
        }

        /// Scale + center-crop `image` to fill `size` — the CoreImage
        /// equivalent of `AVLayerVideoGravity.resizeAspectFill`, matching
        /// `CameraPreview`'s (AVFoundation) preview gravity so the AR and
        /// fallback feeds look the same.
        private static func aspectFill(_ image: CIImage, into size: CGSize) -> CIImage {
            let extent = image.extent
            guard extent.width > 0, extent.height > 0, size.width > 0, size.height > 0 else { return image }
            let scale = max(size.width / extent.width, size.height / extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let dx = scaled.extent.minX - (size.width - scaled.extent.width) / 2
            let dy = scaled.extent.minY - (size.height - scaled.extent.height) / 2
            return scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
        }
    }
}

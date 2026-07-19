import CoreImage
import CoreVideo
import CoreGraphics
import Metal

/// Crops a `CVPixelBuffer` to a NATIVE (raw, un-rotated) pixel `CGRect` — as
/// computed by `ROICropMapper.cropRect` — into a fresh, pooled
/// `CVPixelBuffer` at exactly the crop's own resolution (Lane B chunk E's
/// "native 1920×1440" density win: recognizing a cropped region at its own
/// full resolution instead of the full frame letterboxed down to 640px
/// recovers far more of a small/far tile's real pixel detail).
///
/// A `CIContext` is reused across calls (creating a new one per crop is
/// expensive — mirrors `ARCameraPreview`'s own reused context); pixel
/// buffers come from a `CVPixelBufferPool` sized/formatted to whatever crop
/// size and pixel format were last requested, recreated only when either
/// changes (ARKit's captured image is always `420f`, but this stays
/// format-agnostic on principle — see `crop`'s doc).
final class PixelBufferCropper {
    private let ciContext: CIContext
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var poolFormat: OSType = 0

    init(ciContext: CIContext? = nil) {
        if let ciContext {
            self.ciContext = ciContext
        } else {
            let device = MTLCreateSystemDefaultDevice()
            self.ciContext = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
        }
    }

    /// Crops `buffer` to `rect` (NATIVE pixel coordinates — top-left origin,
    /// `+y` down — already clamped/even-snapped by `ROICropMapper.cropRect`)
    /// into a pooled `CVPixelBuffer` at exactly `rect.size`, preserving
    /// `buffer`'s own pixel format (handles `420f`/`420v` — ARKit's captured
    /// image format — as directly as `32BGRA`; `CIContext.render(_:to:
    /// bounds:colorSpace:)` renders to a Y'CbCr destination same as an RGB
    /// one). Returns `nil` for a degenerate rect or a render failure —
    /// callers fall back to skipping that crop (same "crop failed → don't
    /// ingest garbage" contract `ScanView.croppedFrame` already uses).
    func crop(_ buffer: CVPixelBuffer, to rect: CGRect) -> CVPixelBuffer? {
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard let pooled = pooledBuffer(size: rect.size, format: format) else { return nil }

        let image = CIImage(cvPixelBuffer: buffer)
        // `rect` is top-left-origin/+y-down (native pixel convention);
        // CoreImage's own space is bottom-left-origin/+y-up, so the y origin
        // flips here — the same flip `ScanView.croppedFrame` applies for its
        // own (oriented-space) crop, just against this buffer's native
        // height instead of an oriented image's.
        let ciRect = CGRect(x: rect.minX, y: bufferHeight - rect.maxY, width: rect.width, height: rect.height)
        let cropped = image.cropped(to: ciRect)
        guard !cropped.extent.isInfinite, !cropped.extent.isEmpty else { return nil }
        // Render into the pooled buffer's own (0,0)-origin frame — translate
        // the crop's (nonzero) extent origin back to zero first, or the
        // render below would sample the wrong region.
        let translated = cropped.transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
        ciContext.render(translated, to: pooled, bounds: CGRect(origin: .zero, size: rect.size), colorSpace: nil)
        return pooled
    }

    private func pooledBuffer(size: CGSize, format: OSType) -> CVPixelBuffer? {
        if pool == nil || poolSize != size || poolFormat != format {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
            poolFormat = format
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        return out
    }
}

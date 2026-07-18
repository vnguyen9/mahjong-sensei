import CoreVideo
import Foundation

/// Per-frame motion estimate for the offline harness.
///
/// TODO(coach-live): swap to Recognition.MotionDetector when it lands. The real
/// tracker plan puts motion sampling in `Packages/Recognition` (vImage luma-grid
/// diff, EMA-smoothed, per-region breakdown for discard attribution) so the app
/// and the video dumper run identical code. That component doesn't exist yet, so
/// this is a deliberately simple stand-in scoped to this package: same grid
/// shape (32×18 luma cells, matching the planned real implementation) and the
/// same normalization, but nearest-neighbor point-sampled (no vImage), no EMA
/// smoothing (raw frame-to-frame value), and no per-region output — the
/// `FrameRecord.region` field stays `nil` until the real detector lands. The
/// `motion` field itself is stable across the swap; only its precision improves.
public final class SimpleMotionEstimator {
    private var previousGrid: [UInt8]?
    private let gridWidth: Int
    private let gridHeight: Int

    public init(gridWidth: Int = 32, gridHeight: Int = 18) {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
    }

    /// Mean absolute luma difference against the previous sampled frame,
    /// normalized to roughly `0...1`. Returns `0` for the first call (no prior
    /// frame yet) and whenever the buffer's luma plane can't be read.
    public func sample(_ pixelBuffer: CVPixelBuffer) -> Double {
        guard let grid = downsampledLuma(pixelBuffer) else { return 0 }
        defer { previousGrid = grid }
        guard let previous = previousGrid, previous.count == grid.count else { return 0 }
        var sum = 0
        for i in 0..<grid.count {
            sum += abs(Int(grid[i]) - Int(previous[i]))
        }
        return Double(sum) / Double(grid.count * 255)
    }

    /// Nearest-neighbor point-samples plane 0 (luma, for both 420f biplanar and
    /// plain 8-bit-per-pixel gray buffers) onto a `gridWidth × gridHeight` grid.
    private func downsampledLuma(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let planeIndex = planar ? 0 : 0
        guard let base = planar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex)
            : CVPixelBufferGetBaseAddress(pixelBuffer)
        else { return nil }

        let srcWidth = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex) : CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex) : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0, bytesPerRow > 0 else { return nil }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var grid = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            let sy = min(srcHeight - 1, gy * srcHeight / gridHeight)
            let rowBase = sy * bytesPerRow
            for gx in 0..<gridWidth {
                let sx = min(srcWidth - 1, gx * srcWidth / gridWidth)
                grid[gy * gridWidth + gx] = ptr[rowBase + sx]
            }
        }
        return grid
    }
}

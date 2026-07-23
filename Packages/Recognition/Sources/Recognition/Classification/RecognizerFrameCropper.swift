import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Produces orientation-normalized native-resolution crops for Stage 2.
public struct RecognizerFrameCropper: Sendable {
    public var contextFraction: Double

    public init(contextFraction: Double = 0.12) {
        self.contextFraction = contextFraction
    }

    public func crop(_ frame: RecognizerFrame, box: TileBoundingBox,
                     frameID: FrameID) -> TileCrop? {
        guard let image = orientedImage(frame) else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let expanded = Self.expanded(box, by: contextFraction)
        let rect = CGRect(
            x: extent.minX + expanded.x * extent.width,
            y: extent.minY + (1 - expanded.y - expanded.height) * extent.height,
            width: expanded.width * extent.width,
            height: expanded.height * extent.height
        ).intersection(extent)
        guard rect.width >= 2, rect.height >= 2 else { return nil }

        let cropped = image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        guard let cgImage = Self.context.createCGImage(cropped, from: cropped.extent) else {
            return nil
        }
        return TileCrop(frame: .image(cgImage), frameID: frameID, sourceBox: box)
    }

    public static func expanded(_ box: TileBoundingBox, by fraction: Double) -> TileBoundingBox {
        let dx = box.width * max(0, fraction)
        let dy = box.height * max(0, fraction)
        let x = max(0, box.x - dx)
        let y = max(0, box.y - dy)
        let maxX = min(1, box.x + box.width + dx)
        let maxY = min(1, box.y + box.height + dy)
        return TileBoundingBox(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
    }

    private func orientedImage(_ frame: RecognizerFrame) -> CIImage? {
        switch frame {
        case let .cgImage(image, orientation):
            return CIImage(cgImage: image).oriented(orientation)
        case let .pixelBuffer(buffer, orientation):
            return CIImage(cvPixelBuffer: buffer).oriented(orientation)
        }
    }

    private static let context = CIContext(options: [.cacheIntermediates: true])
}

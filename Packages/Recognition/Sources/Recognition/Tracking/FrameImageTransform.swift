import CoreGraphics
import ImageIO
import simd

/// One frame's authoritative raw-sensor ↔ oriented-detector coordinate map.
/// Both spaces use normalized top-left coordinates.
public struct FrameImageTransform: Sendable, Equatable {
    public var imageOrientation: CGImagePropertyOrientation
    public var imageResolution: CGSize
    public var orientedImageSize: CGSize

    public init(
        imageOrientation: CGImagePropertyOrientation,
        imageResolution: CGSize
    ) {
        self.imageOrientation = imageOrientation
        self.imageResolution = imageResolution
        switch imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            self.orientedImageSize = CGSize(
                width: imageResolution.height,
                height: imageResolution.width
            )
        default:
            self.orientedImageSize = imageResolution
        }
    }

    public func rawNormalized(
        fromOriented point: SIMD2<Double>
    ) -> SIMD2<Double> {
        switch imageOrientation {
        case .up: return point
        case .upMirrored: return SIMD2(1 - point.x, point.y)
        case .down: return SIMD2(1 - point.x, 1 - point.y)
        case .downMirrored: return SIMD2(point.x, 1 - point.y)
        case .left: return SIMD2(1 - point.y, point.x)
        case .leftMirrored: return SIMD2(point.y, point.x)
        case .right: return SIMD2(point.y, 1 - point.x)
        case .rightMirrored: return SIMD2(1 - point.y, 1 - point.x)
        @unknown default: return point
        }
    }

    public func orientedNormalized(
        fromRaw point: SIMD2<Double>
    ) -> SIMD2<Double> {
        switch imageOrientation {
        case .up: return point
        case .upMirrored: return SIMD2(1 - point.x, point.y)
        case .down: return SIMD2(1 - point.x, 1 - point.y)
        case .downMirrored: return SIMD2(point.x, 1 - point.y)
        case .left: return SIMD2(point.y, 1 - point.x)
        case .leftMirrored: return SIMD2(point.y, point.x)
        case .right: return SIMD2(1 - point.y, point.x)
        case .rightMirrored: return SIMD2(1 - point.y, 1 - point.x)
        @unknown default: return point
        }
    }
}

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// The exact geometry used by Ultralytics' centered `LetterBox` transform.
/// Model-space coordinates use a top-left origin in the square input canvas.
public struct UltralyticsLetterboxGeometry: Sendable, Hashable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let inputSize: Int
    public let scale: Double
    public let resizedWidth: Int
    public let resizedHeight: Int
    public let leftPadding: Int
    public let topPadding: Int
    public let rightPadding: Int
    public let bottomPadding: Int

    public init(sourceSize: CGSize, inputSize: Int = 640) {
        let width = max(1, Int(sourceSize.width.rounded()))
        let height = max(1, Int(sourceSize.height.rounded()))
        let side = max(1, inputSize)
        let ratio = min(Double(side) / Double(width),
                        Double(side) / Double(height))
        let resizedWidth = Int((Double(width) * ratio).rounded())
        let resizedHeight = Int((Double(height) * ratio).rounded())
        let horizontalHalfPadding = Double(side - resizedWidth) / 2
        let verticalHalfPadding = Double(side - resizedHeight) / 2
        let left = Int((horizontalHalfPadding - 0.1).rounded())
        let right = Int((horizontalHalfPadding + 0.1).rounded())
        let top = Int((verticalHalfPadding - 0.1).rounded())
        let bottom = Int((verticalHalfPadding + 0.1).rounded())

        sourceWidth = width
        sourceHeight = height
        self.inputSize = side
        scale = ratio
        self.resizedWidth = resizedWidth
        self.resizedHeight = resizedHeight
        leftPadding = left
        rightPadding = right
        topPadding = top
        bottomPadding = bottom
    }

    public var contentRect: CGRect {
        CGRect(x: leftPadding, y: topPadding,
               width: resizedWidth, height: resizedHeight)
    }

    /// Converts an `[x1, y1, x2, y2]` model-space box into the normalized,
    /// top-left-origin coordinates of the upright canonical image.
    public func normalizedCanonicalBox(x1: Double, y1: Double,
                                       x2: Double, y2: Double) -> TileBoundingBox {
        let minimumX = (min(x1, x2) - Double(leftPadding)) / scale
        let minimumY = (min(y1, y2) - Double(topPadding)) / scale
        let maximumX = (max(x1, x2) - Double(leftPadding)) / scale
        let maximumY = (max(y1, y2) - Double(topPadding)) / scale
        let clippedMinimumX = min(max(0, minimumX), Double(sourceWidth))
        let clippedMinimumY = min(max(0, minimumY), Double(sourceHeight))
        let clippedMaximumX = min(max(0, maximumX), Double(sourceWidth))
        let clippedMaximumY = min(max(0, maximumY), Double(sourceHeight))
        return TileBoundingBox(
            x: clippedMinimumX / Double(sourceWidth),
            y: clippedMinimumY / Double(sourceHeight),
            width: max(0, clippedMaximumX - clippedMinimumX) / Double(sourceWidth),
            height: max(0, clippedMaximumY - clippedMinimumY) / Double(sourceHeight)
        )
    }
}

public struct UltralyticsLetterboxResult: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let image: CGImage
    public let geometry: UltralyticsLetterboxGeometry

    public init(pixelBuffer: CVPixelBuffer, image: CGImage,
                geometry: UltralyticsLetterboxGeometry) {
        self.pixelBuffer = pixelBuffer
        self.image = image
        self.geometry = geometry
    }
}

public enum UltralyticsLetterboxError: Error, Sendable, Equatable {
    case pixelBufferCreationFailed
    case graphicsContextCreationFailed
    case imageCreationFailed
    case orientationRenderingFailed
}

/// Renders the Core ML input ourselves so Vision cannot choose a different
/// resampler, crop policy, or padding color for small tiles.
public enum UltralyticsLetterboxRenderer {
    public static let paddingValue: UInt8 = 114

    public static func render(_ uprightImage: CGImage, inputSize: Int = 640) throws
        -> UltralyticsLetterboxResult {
        let geometry = UltralyticsLetterboxGeometry(
            sourceSize: CGSize(width: uprightImage.width, height: uprightImage.height),
            inputSize: inputSize
        )
        var optionalBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            geometry.inputSize,
            geometry.inputSize,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw UltralyticsLetterboxError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw UltralyticsLetterboxError.graphicsContextCreationFailed
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: geometry.inputSize,
            height: geometry.inputSize,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw UltralyticsLetterboxError.graphicsContextCreationFailed
        }

        let gray = CGFloat(Self.paddingValue) / 255
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0,
                            width: geometry.inputSize, height: geometry.inputSize))
        // `.low` is Quartz's deterministic bilinear path. Higher settings may
        // switch to a sharper resampler and diverge from OpenCV INTER_LINEAR.
        context.interpolationQuality = .low
        context.setShouldAntialias(false)
        // A bitmap CGContext's produced CGImage keeps the source raster upright
        // when drawn in Quartz coordinates. Only the model-space y position
        // needs conversion from Ultralytics' top origin to Quartz's bottom origin.
        let quartzContentRect = CGRect(
            x: geometry.leftPadding,
            y: geometry.bottomPadding,
            width: geometry.resizedWidth,
            height: geometry.resizedHeight
        )
        context.draw(uprightImage, in: quartzContentRect)

        guard let rendered = context.makeImage() else {
            throw UltralyticsLetterboxError.imageCreationFailed
        }
        return UltralyticsLetterboxResult(pixelBuffer: buffer, image: rendered,
                                          geometry: geometry)
    }

    /// Bakes EXIF orientation once. All downstream boxes and review markers
    /// consequently share one upright, top-left-origin coordinate system.
    public static func bakeOrientation(_ image: CGImage,
                                       orientation: CGImagePropertyOrientation) throws
        -> CGImage {
        guard orientation != .up else { return image }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let extent = oriented.extent.integral
        let translated = oriented.transformed(by: CGAffineTransform(
            translationX: -extent.minX,
            y: -extent.minY
        ))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let output = context.createCGImage(
            translated,
            from: CGRect(origin: .zero, size: extent.size)
        ) else {
            throw UltralyticsLetterboxError.orientationRenderingFailed
        }
        return output
    }
}

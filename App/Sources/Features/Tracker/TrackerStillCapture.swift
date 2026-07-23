import CoreGraphics
import Foundation
import ImageIO
import Recognition

/// One quality-prioritized photo and the preview context present at shutter
/// time. The encoded photo and decoded image live only for the review
/// transaction; neither is persisted by Tracker.
struct TrackerStillCapture: @unchecked Sendable {
    var id: UUID
    var encodedPhotoData: Data
    var encodedFormat: String
    var image: CGImage
    var imageOrientation: CGImagePropertyOrientation
    var previewImage: CGImage?
    var previewPixelSize: CGSize
    var photoPixelSize: CGSize
    var cameraLens: CameraLens
    var captureTimestamp: TimeInterval
    /// Normalized, top-left-origin rect in the oriented canonical image.
    var roi: TileBoundingBox?
    var cameraReadinessDuration: TimeInterval
    var photoDeliveryDuration: TimeInterval
}

enum TrackerPhotoCaptureError: LocalizedError {
    case cameraNotReady
    case holdSteadier
    case moreLightNeeded
    case noPhotoData
    case imageDecodeFailed
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraNotReady: return "The camera is not ready yet."
        case .holdSteadier: return "Hold steadier and try again."
        case .moreLightNeeded: return "More light is needed to scan the table."
        case .noPhotoData: return "The camera did not deliver a photo."
        case .imageDecodeFailed: return "The captured photo could not be read."
        case .captureFailed(let message): return message
        }
    }
}

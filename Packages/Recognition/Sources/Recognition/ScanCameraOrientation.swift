import CoreGraphics
import ImageIO

/// The four display poses supported by Scan's non-AR rear camera.
///
/// `UIInterfaceOrientation` deliberately stays out of this type so the camera
/// contract is testable on every Recognition platform. UIKit adapts its
/// interface orientation to this enum at the app boundary.
public enum ScanCameraOrientation: CaseIterable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    /// Orientation Vision and Core Image apply to Scan's sensor-native buffer.
    public var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        }
    }

    /// Clockwise rotation for `AVCaptureVideoPreviewLayer`.
    public var previewRotationAngle: CGFloat {
        switch self {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        }
    }
}

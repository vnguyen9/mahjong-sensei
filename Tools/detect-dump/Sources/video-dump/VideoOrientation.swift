import CoreGraphics
import ImageIO

extension CGImagePropertyOrientation {
    /// Maps an `AVAssetTrack.preferredTransform` to the orientation Vision
    /// expects, mirroring the app's `RecognizerFrame` orientation contract (a
    /// rear camera held upright in portrait — the common handheld case, and how
    /// `IMG_6249.mov` was shot — is `.right`, same as `CameraCapture`'s buffers).
    ///
    /// iPhone-recorded tracks always carry one of the four axis-aligned
    /// transforms (0°/90°/180°/270° rotation, no shear); this rounds the
    /// transform's angle to the nearest 90° and maps the four cases:
    /// 0° → `.up`, 90° → `.right`, 180° → `.down`, 270° (-90°) → `.left`.
    init(videoTransform transform: CGAffineTransform) {
        let radians = atan2(Double(transform.b), Double(transform.a))
        var degrees = radians * 180 / .pi
        if degrees < 0 { degrees += 360 }   // normalize to [0, 360)
        let quadrant = Int((degrees / 90).rounded()) % 4
        switch quadrant {
        case 0: self = .up
        case 1: self = .right
        case 2: self = .down
        default: self = .left
        }
    }

    /// True for the two 90°-rotating cases, where the displayed width/height are
    /// swapped relative to the raw (sensor-native) pixel buffer.
    var isSideways: Bool { self == .left || self == .right }
}

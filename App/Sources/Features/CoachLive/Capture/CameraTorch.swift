import AVFoundation

/// Toggles the torch on the back wide-angle camera while an `ARSession` is
/// running. ARKit owns the capture device but doesn't lock out torch control —
/// community-proven, NOT a documented ARKit contract, so verify on device and
/// be ready to degrade to suggestion-only if a given iOS release regresses.
///
/// Shared by the live capture (`ARTableCapture`) and the calibration session
/// (`ARCalibrationView`): they run separate `ARSession`s over the SAME shared
/// back camera, so one torch control serves both. A `session.run(_:)` reconfig
/// can silently reset the torch to off (ARKit reclaims the device on each run),
/// so callers re-assert their desired state after any re-run.
@MainActor
enum CameraTorch {
    /// Resolved once and cached — re-resolving per toggle is wasteful.
    private static var cachedDevice: AVCaptureDevice?

    private static func device() -> AVCaptureDevice? {
        if let cachedDevice { return cachedDevice }
        cachedDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        return cachedDevice
    }

    /// Sets the torch on/off. Returns false if there's no torch or the device
    /// couldn't be locked (caller can hide/disable the affordance).
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard let dev = device(), dev.hasTorch, (try? dev.lockForConfiguration()) != nil else { return false }
        dev.torchMode = on ? .on : .off
        dev.unlockForConfiguration()
        return true
    }

    /// Whether the back camera has a torch at all (to gate the UI).
    static var isAvailable: Bool { device()?.hasTorch ?? false }
}

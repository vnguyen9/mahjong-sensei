import SwiftUI
import DesignSystem

/// Coach Live's three new palette tokens (UI plan §2/§3).
///
/// These belong in `Packages/DesignSystem/Sources/DesignSystem/Palette.swift`
/// per the plan — but this chunk owns `App/Sources/**` only (another agent is
/// actively working inside `Packages/`), so they're added here as an
/// app-local extension on the public `MJColor` enum instead. Call sites read
/// exactly `MJColor.amberZone` etc., matching the plan verbatim; a follow-up
/// chunk can move this file's contents into the package without touching any
/// call site once `Packages/` is free again.
extension MJColor {
    /// Unresolved-zone amber — distinct from `amberLowConf` (0xFF9F0A).
    static let amberZone = Color(hex: 0xF0A24B)
    /// Ink-on-amber text/glyph color for `amberZone` chips.
    static let inkOnAmber = Color(hex: 0x3A2508)
    /// The LIVE-pill pulsing dot.
    static let liveRed = Color(hex: 0xE5484D)
}

import SwiftUI

/// The dark radial grounds behind each screen family (design spec §2.1 greens).
public enum MJBackground: Sendable {
    case welcome    // onboarding welcome / camera primer
    case content    // default non-camera content
    case camera     // live camera screens
    case lowLight   // low-light warning state
    case live       // live/AR (solid, under a blurred photo)
}

public struct ScreenBackground: View {
    public let style: MJBackground
    public init(_ style: MJBackground = .content) { self.style = style }

    public var body: some View {
        content.ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .welcome:
            ellipse([Color(hex: 0x15493C), Color(hex: 0x08211B)], center: .init(x: 0.5, y: 0.06))
        case .content:
            ellipse([Color(hex: 0x134438), Color(hex: 0x0A241D)], center: .init(x: 0.5, y: 0.04))
        case .camera:
            ellipse([Color(hex: 0x33463A), Color(hex: 0x1A2B20), Color(hex: 0x0C1611)],
                    center: .init(x: 0.5, y: 0.30))
        case .lowLight:
            ellipse([Color(hex: 0x1A241F), Color(hex: 0x0A120E)], center: .init(x: 0.5, y: 0.40))
        case .live:
            Color(hex: 0x0A120D)
        }
    }

    private func ellipse(_ colors: [Color], center: UnitPoint) -> some View {
        EllipticalGradient(gradient: Gradient(colors: colors),
                           center: center,
                           startRadiusFraction: 0,
                           endRadiusFraction: 1.1)
    }
}

public extension View {
    /// Places the given screen ground behind this view, edge-to-edge, dark scheme.
    func screenBackground(_ style: MJBackground = .content) -> some View {
        self.background(ScreenBackground(style)).preferredColorScheme(.dark)
    }
}

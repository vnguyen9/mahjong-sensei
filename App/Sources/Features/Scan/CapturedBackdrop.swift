import SwiftUI
import UIKit
import DesignSystem

/// Backdrop for the post-scan flow: a heavily blurred, dark-green-tinted copy of the
/// photo captured at the shutter — so every screen sits over the real table. Falls
/// back to the design grounds when there's no photo (mock / simulator / debug routes).
struct CapturedBackdrop: View {
    let photo: UIImage?
    var fallback: MJBackground = .content

    var body: some View {
        if let photo {
            GeometryReader { geo in
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 44, opaque: true)
                    .scaleEffect(1.2)                       // push soft blurred edges off-screen
                    .clipped()
                    .overlay(MJColor.deepJade.opacity(0.80))   // strong green tint
                    .overlay(
                        EllipticalGradient(
                            gradient: Gradient(colors: [.clear, Color(hex: 0x081C16, alpha: 0.6)]),
                            center: .init(x: 0.5, y: 0.32),
                            startRadiusFraction: 0.2, endRadiusFraction: 1.1)
                    )
            }
            .ignoresSafeArea()
        } else {
            ScreenBackground(fallback)
        }
    }
}

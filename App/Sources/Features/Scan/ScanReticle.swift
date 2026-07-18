import SwiftUI
import DesignSystem

/// The viewfinder: a full-screen frosted overlay whose blur + jade tint fade away
/// around a clear **oval** window — no border, no hard edge. Everything outside
/// the window is blurred; the window shows the live camera (or fake ground) sharp.
struct ViewfinderBlurOverlay: View {
    /// The clear window's bounding rect, in this overlay's (full-screen, global)
    /// coordinate space; the visible opening is the ellipse inscribed in it.
    let window: CGRect
    /// How soft the transition from clear to blurred is.
    var feather: CGFloat = 26

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .overlay(MJColor.deepJade.opacity(0.30))
            .mask {
                // Alpha hole: opaque everywhere, punched through at the window.
                // Blurring the punch feathers the edge so the blur ramps in
                // gradually instead of cutting off. The hole is grown by ~half
                // the feather so the fully-clear core still matches the window.
                ZStack {
                    Rectangle().fill(.white)
                    Ellipse()
                        .frame(width: window.width + feather / 2, height: window.height + feather / 2)
                        .position(x: window.midX, y: window.midY)
                        .blur(radius: feather)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }
}

/// Dots of varying size drifting slowly around the viewfinder window — a calm,
/// organic replacement for the scan-line sweep (per the user's mockup): a dense
/// field of loose elliptical bands, each dot with its own radius, speed, and twinkle.
struct OrbitDots: View {
    let window: CGRect
    private let count = 108
    private static let palette: [Color] = [MJColor.cream, MJColor.lightGold, .white, MJColor.gold(0.9)]

    /// Deterministic per-dot jitter in 0..<1 (stable frame to frame).
    private static func jitter(_ i: Int, _ salt: Double) -> Double {
        let x = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, _ in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let cx = window.midX, cy = window.midY
                let bands: [CGFloat] = [8, 22, 38, 58, 80, 104]   // insets beyond the window edge
                for i in 0..<count {
                    let jR = Self.jitter(i, 1), jP = Self.jitter(i, 2)
                    let jS = Self.jitter(i, 3), jZ = Self.jitter(i, 4)
                    let inset = bands[i % bands.count] + CGFloat(jR * 22 - 8)
                    let a = window.width / 2 + inset      // ellipse radii for this dot
                    let b = window.height / 2 + inset
                    let lap = 14.0 + jS * 10.0            // one lap in 14–24 s
                    let angle = jP * 2 * .pi + t * (2 * .pi / lap)
                    let wobble = 1 + 0.05 * sin(1.7 * Double(i) + 0.4 * t)
                    let x = cx + CGFloat(cos(angle) * wobble) * a
                    let y = cy + CGFloat(sin(angle) * wobble) * b
                    let size = 1.8 + 4.0 * jZ             // 1.8–5.8 pt
                    let twinkle = 0.35 + 0.5 * ((sin(1.1 * t + Double(i)) + 1) / 2)
                    let color = Self.palette[i % Self.palette.count].opacity(twinkle)
                    let rect = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

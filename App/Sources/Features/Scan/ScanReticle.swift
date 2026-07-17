import SwiftUI
import DesignSystem

/// The four gold corner brackets of the alignment frame (spec §3.9), drawn as a
/// single stroked shape (rounded only on the outer corner of each bracket).
struct ReticleCorners: Shape {
    var cornerLength: CGFloat = 24
    var radius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = cornerLength, r = radius
        // Top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + c))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + c, y: rect.minY))
        // Top-right
        p.move(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
        // Bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        // Bottom-left
        p.move(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
        return p
    }
}

/// Alignment reticle with animated sweep line (spec §3.9).
struct ScanReticle: View {
    var dashed: Bool = false
    @State private var sweepDown = false

    var body: some View {
        ZStack {
            if dashed {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MJColor.gold(0.4), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            } else {
                ReticleCorners(cornerLength: 24, radius: 8)
                    .stroke(MJColor.gold(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))

                GeometryReader { geo in
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, MJColor.lightGold, .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 2)
                        .shadow(color: MJColor.gold, radius: 6)
                        .padding(.horizontal, 6)
                        .position(x: geo.size.width / 2, y: sweepDown ? geo.size.height - 8 : 8)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                                sweepDown = true
                            }
                        }
                }
            }
        }
    }
}

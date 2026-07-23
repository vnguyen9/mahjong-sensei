import SwiftUI

/// The face-down side of a mahjong tile: a themed cap over an ivory body,
/// selectable via `\.tileBackStyle` (approved design review — gold glitter,
/// velvet burgundy, and jade marble river caps).
///
/// Construction is a stack: the ivory body sits offset below the cap so a
/// thin ivory edge shows on every face-down tile (`reveal` = 0.10 × width),
/// matching the real tile's beveled underside.
public struct MahjongTileBackView: View {
    private let width: CGFloat
    private let seed: UInt64
    @Environment(\.tileBackStyle) private var style
    private static let reveal: CGFloat = 0.10

    public init(width: CGFloat, seed: UInt64 = 1) {
        self.width = width
        self.seed = seed
    }

    public var body: some View {
        let corner = width * 0.18
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xF8F1E1), Color(hex: 0xE2D2AC)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: corner)
                        .strokeBorder(Color(hex: 0xD8C69C).opacity(0.8), lineWidth: 0.8)
                }
                .offset(y: width * Self.reveal)
            cap(corner)
                .frame(width: width, height: width * 1.35)
        }
        .frame(width: width, height: width * (1.35 + Self.reveal))
        .shadow(color: .black.opacity(0.20), radius: max(1, width * 0.07), y: max(1, width * 0.07))
    }

    @ViewBuilder private func cap(_ corner: CGFloat) -> some View {
        switch style {
        case .gold:   goldCap(corner)
        case .velvet: velvetCap(corner)
        case .jade:   jadeCap(corner)
        }
    }

    // MARK: - Gold (fine glitter)

    private func goldCap(_ corner: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xEED382), Color(hex: 0xD9B354), Color(hex: 0xB98F2E)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                // Soft tonal shimmer patches (the "brushed" light pooling in the reference photo).
                EllipticalGradient(colors: [Color(hex: 0xF6E49B).opacity(0.35), .clear],
                                   center: .init(x: 0.3, y: 0.25), startRadiusFraction: 0, endRadiusFraction: 0.7)
                EllipticalGradient(colors: [Color(hex: 0xF6E49B).opacity(0.25), .clear],
                                   center: .init(x: 0.75, y: 0.7), startRadiusFraction: 0, endRadiusFraction: 0.6)
            }
            .overlay {
                Canvas { ctx, size in
                    let count = Int(1.0 * size.width * size.height)
                    for i in 0..<count {
                        var v = UInt64(i) &* 0x9E3779B97F4A7C15; v ^= v >> 31; v &*= 0xBF58476D1CE4E5B9; v ^= v >> 27
                        let fx = Double(v % 10007)/10007.0, fy = Double((v >> 17) % 10009)/10009.0
                        let fr = Double((v >> 34) % 1000)/1000.0, fo = Double((v >> 44) % 1000)/1000.0
                        let s = size.width * (0.004 + fr * 0.008)
                        let color: Color = fo > 0.55 ? Color(hex: 0xFFF6D8).opacity(0.20 + (fo-0.55)*0.9)
                            : (fo > 0.25 ? Color(hex: 0xF0DA9A).opacity(0.15 + fo*0.3) : Color(hex: 0x7A5C15).opacity(0.10 + fo*0.5))
                        ctx.fill(Path(ellipseIn: CGRect(x: fx*size.width - s/2, y: fy*size.height - s/2, width: s, height: s)), with: .color(color))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
            .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(Color(hex: 0xF4E3AE).opacity(0.6), lineWidth: 0.8) }
            .shadow(color: .black.opacity(0.22), radius: max(1, width * 0.08), y: max(1, width * 0.08))
    }

    // MARK: - Velvet (burgundy crushed velvet)

    private func velvetCap(_ corner: CGFloat) -> some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color(hex: 0x6E1F2C), Color(hex: 0x4A101B)]),
                          startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            func blob(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: 2*r, height: 2*r)),
                         with: .radialGradient(Gradient(colors: [c, .clear]), center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
            }
            var s = seed | 1
            func rnd() -> CGFloat { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return CGFloat(s % 10000)/10000 }
            for _ in 0..<7 {
                let cx = rnd()*w, cy = rnd()*h, r = w*(0.28 + rnd()*0.22)
                let light = rnd() > 0.5
                blob(cx, cy, r, (light ? Color(hex: 0x93394A) : Color(hex: 0x360C15)).opacity(0.5))
            }
            let count = Int(1.7 * w * h)
            for i in 0..<count {
                var v = UInt64(i) &* 0xD1B54A32D192ED03 &+ seed; v ^= v >> 30; v &*= 0x9FB21C651E98DF25; v ^= v >> 28
                let fx = CGFloat(v % 10007)/10007, fy = CGFloat((v >> 17) % 10009)/10009, fo = Double((v >> 44) % 1000)/1000
                let sz = w*0.005
                let color = fo > 0.6 ? Color(hex: 0xA84556).opacity(0.05 + fo*0.05) : Color(hex: 0x2A0710).opacity(0.05 + fo*0.09)
                ctx.fill(Path(ellipseIn: CGRect(x: fx*w - sz/2, y: fy*h - sz/2, width: sz, height: sz)), with: .color(color))
            }
            ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [.white.opacity(0.06), .clear]),
                          center: CGPoint(x: w*0.5, y: h*0.28), startRadius: 0, endRadius: w*0.7))
            ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.22)]),
                          center: CGPoint(x: w*0.5, y: h*0.5), startRadius: w*0.35, endRadius: w*0.85))
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(Color(hex: 0xB8697A).opacity(0.22), lineWidth: 0.8) }
    }

    // MARK: - Jade (marbled jade + gold-dust river)

    private func jadeCap(_ corner: CGFloat) -> some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let rect = CGRect(origin: .zero, size: size)
            var s = (seed &* 6364136223846793005 &+ 1442695040888963407) | 1
            func rnd() -> CGFloat { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return CGFloat(s % 100000)/100000 }
            func blob(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: 2*r, height: 2*r)),
                         with: .radialGradient(Gradient(colors: [c, .clear]), center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
            }
            func cloud(_ cx: CGFloat, _ cy: CGFloat, _ spread: CGFloat, _ c: Color, _ n: Int, opacityRange: ClosedRange<Double>) {
                for _ in 0..<n {
                    let a = rnd() * 2 * .pi
                    let d = rnd() * spread
                    let r = spread * (0.25 + rnd() * 0.45)
                    let o = opacityRange.lowerBound + Double(rnd()) * (opacityRange.upperBound - opacityRange.lowerBound)
                    blob(cx + cos(a)*d, cy + sin(a)*d, r, c.opacity(o))
                }
            }

            // ===== 1. base stone =====
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color(hex: 0x33986E), Color(hex: 0x1C6F4F), Color(hex: 0x0B4130)]),
                          startPoint: CGPoint(x: w, y: 0), endPoint: CGPoint(x: 0, y: h)))
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [.clear, Color(hex: 0x042519).opacity(0.75)]),
                          startPoint: CGPoint(x: w*0.35, y: h*0.2), endPoint: CGPoint(x: w*1.0, y: h*0.55)))
            blob(w*0.5, h*0.4, w*0.55, Color(hex: 0x2E8F79).opacity(0.28))   // teal underglow

            // ===== 2. marble clouds =====
            cloud(w*(0.55 + rnd()*0.3), h*(0.10 + rnd()*0.25), w*0.30, Color(hex: 0x05301D), 12, opacityRange: 0.4...0.7)
            cloud(w*(0.6 + rnd()*0.3), h*(0.55 + rnd()*0.3), w*0.26, Color(hex: 0x063C26), 10, opacityRange: 0.35...0.6)
            cloud(w*(0.2 + rnd()*0.3), h*(0.12 + rnd()*0.2), w*0.24, Color(hex: 0x54B88C), 10, opacityRange: 0.25...0.45)
            cloud(w*0.28, h*0.70, w*0.28, Color(hex: 0xA9D9BC), 18, opacityRange: 0.18...0.34)
            cloud(w*0.30, h*0.72, w*0.13, Color(hex: 0xD5EDDC), 9, opacityRange: 0.2...0.34)
            cloud(w*0.10, h*0.52, w*0.14, Color(hex: 0x0A4B31), 6, opacityRange: 0.3...0.5)
            cloud(w*0.50, h*0.86, w*0.16, Color(hex: 0x08402A), 6, opacityRange: 0.3...0.5)
            for _ in 0..<14 {
                let a = rnd() * 2 * .pi, d = rnd() * w*0.22
                blob(w*0.28 + cos(a)*d, h*0.70 + sin(a)*d, w*(0.015 + rnd()*0.045), Color(hex: 0x1E5C42).opacity(0.3 + Double(rnd())*0.35))
            }
            for _ in 0..<12 {
                let dark = rnd() > 0.5
                blob(rnd()*w, rnd()*h, w*(0.05 + rnd()*0.10),
                     (dark ? Color(hex: 0x093824) : Color(hex: 0x74C69C)).opacity(0.18 + Double(rnd())*0.25))
            }

            // (no filaments / smoke bands — they washed out the marble; clouds carry the flow)

            // ===== 4. gold dust at two depths =====
            let flip = rnd() > 0.5
            func X(_ x: CGFloat) -> CGFloat { flip ? w - x : x }
            var goldPts: [(CGPoint, CGFloat)] = []   // (point, spread) — collected for both passes + mist

            // 4a+4b. full-height gold river as ONE smooth sinusoidal meander —
            // tangent-continuous everywhere, so no kinks; no per-point wobble.
            let x0 = 0.40 + rnd()*0.20
            let a1 = 0.22 + rnd()*0.10, a2 = 0.08 + rnd()*0.06
            let f1 = 0.9 + rnd()*0.5, f2 = 2.2 + rnd()*1.0
            let p1 = rnd() * 2 * .pi, p2 = rnd() * 2 * .pi
            let swellPhase = rnd() * 2 * .pi
            func riverX(_ gt: CGFloat) -> CGFloat {
                let xf = x0 + a1*sin(2 * .pi * f1 * gt + p1) + a2*sin(2 * .pi * f2 * gt + p2)
                return X(w * min(max(xf, 0.10), 0.90))
            }
            var riverLine: [CGPoint] = []      // saved for tangent-aligned branches
            var gt: CGFloat = 0
            while gt <= 1 {
                let pt = CGPoint(x: riverX(gt), y: h * (-0.05 + 1.10 * gt))
                riverLine.append(pt)
                let swell = 0.45 + 0.55 * sin(gt * .pi) + 0.25 * sin(gt * 2.6 * .pi + swellPhase)
                let spread = w * (0.012 + 0.048 * max(0.2, swell) * max(0.2, swell))
                let clump = rnd()
                if clump > 0.06 { goldPts.append((pt, spread * (0.85 + clump * 0.35))) }
                gt += 0.004
            }
            // 4c. tributaries — peel off tangent to the river, curving away in a smooth arc
            let branchCount = 2 + Int(rnd()*2)
            for _ in 0..<branchCount {
                let idx = Int(CGFloat(riverLine.count - 2) * (0.2 + rnd()*0.6))
                var pos = riverLine[idx]
                let tangent = CGPoint(x: riverLine[idx+1].x - pos.x, y: riverLine[idx+1].y - pos.y)
                var ang = atan2(tangent.y, tangent.x) + (rnd() > 0.5 ? 1 : -1) * (0.3 + rnd()*0.4)
                let turn = (rnd() - 0.5) * 0.10          // constant curvature → smooth arc
                let steps = 22 + Int(rnd()*20)
                let step = w * 0.013
                for st in 0..<steps {
                    pos.x += cos(ang) * step
                    pos.y += sin(ang) * step
                    ang += turn
                    let fade = 1 - CGFloat(st) / CGFloat(steps)
                    if rnd() > 0.12 {
                        goldPts.append((pos, w * (0.003 + 0.011 * fade)))
                    }
                }
            }

            // faint amber haze under all gold
            for (pt, spread) in goldPts where rnd() > 0.7 {
                blob(pt.x, pt.y, spread * 3.2, Color(hex: 0xB08526).opacity(0.05))
            }
            // DEEP pass: dim embedded dust (larger, hazier)
            for (pt, spread) in goldPts {
                let n = 2 + Int(rnd()*3)
                for _ in 0..<n {
                    let lat = (rnd() + rnd() - 1) * spread * 1.6
                    let px = pt.x + lat, py = pt.y + (rnd() - 0.5) * spread * 2.2
                    let sz = w*(0.004 + rnd()*0.010)
                    ctx.fill(Path(ellipseIn: CGRect(x: px-sz/2, y: py-sz/2, width: sz, height: sz)),
                             with: .color(Color(hex: 0x9C7A20).opacity(0.15 + Double(rnd())*0.25)))
                }
            }
            // SURFACE pass: sharp bright dust (dense core)
            for (pt, spread) in goldPts {
                let n = 4 + Int(rnd()*8)
                for _ in 0..<n {
                    let lat = (rnd() + rnd() + rnd() - 1.5) * spread
                    let px = pt.x + lat, py = pt.y + (rnd() - 0.5) * spread * 1.4
                    let sz = w*(0.0022 + rnd()*0.0065)
                    let roll = rnd()
                    let c: Color = roll > 0.84 ? Color(hex: 0xFFF8DC).opacity(0.95)
                        : roll > 0.55 ? Color(hex: 0xF2D379).opacity(0.65 + Double(rnd())*0.35)
                        : roll > 0.25 ? Color(hex: 0xCB9D36).opacity(0.55 + Double(rnd())*0.35)
                        : Color(hex: 0x8A6516).opacity(0.45 + Double(rnd())*0.3)
                    ctx.fill(Path(ellipseIn: CGRect(x: px-sz/2, y: py-sz/2, width: sz, height: sz)), with: .color(c))
                }
            }
            // glow glints: a few brightest sparks with halo
            for _ in 0..<7 {
                let (pt, spread) = goldPts[Int(rnd() * CGFloat(goldPts.count - 1))]
                let px = pt.x + (rnd()-0.5)*spread, py = pt.y + (rnd()-0.5)*spread
                blob(px, py, w*0.020, Color(hex: 0xFFE9A8).opacity(0.55))
                let sz = w*0.007
                ctx.fill(Path(ellipseIn: CGRect(x: px-sz/2, y: py-sz/2, width: sz, height: sz)), with: .color(.white.opacity(0.95)))
            }
            // stray sparkles in the stone
            for _ in 0..<26 {
                let sz = w*(0.002 + rnd()*0.005)
                ctx.fill(Path(ellipseIn: CGRect(x: rnd()*w - sz/2, y: rnd()*h - sz/2, width: sz, height: sz)),
                         with: .color(Color(hex: 0xF2DA8C).opacity(0.12 + Double(rnd())*0.3)))
            }

            // ===== 5. glass =====
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w*0.12, height: h)),
                     with: .linearGradient(Gradient(colors: [.white.opacity(0.38), .clear]),
                          startPoint: .zero, endPoint: CGPoint(x: w*0.12, y: 0)))
            ctx.fill(Path(CGRect(x: w*0.90, y: 0, width: w*0.10, height: h)),
                     with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.20)]),
                          startPoint: CGPoint(x: w*0.90, y: 0), endPoint: CGPoint(x: w, y: 0)))
            ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [.white.opacity(0.32), .clear]),
                          center: CGPoint(x: w*0.30, y: h*0.08), startRadius: 0, endRadius: w*0.55))
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [.white.opacity(0.15), .clear]),
                          startPoint: .zero, endPoint: CGPoint(x: 0, y: h*0.35)))
            ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [.clear, Color(hex: 0x03160E).opacity(0.32)]),
                          center: CGPoint(x: w*0.35, y: h*0.35), startRadius: w*0.5, endRadius: w*1.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner).strokeBorder(LinearGradient(colors: [.white.opacity(0.45), Color(hex: 0x082C20).opacity(0.55)], startPoint: .top, endPoint: .bottom), lineWidth: 1.1)
        }
    }
}

#if DEBUG
#Preview("Tile back") {
    HStack(alignment: .bottom, spacing: 14) {
        MahjongTileBackView(width: 96)
        MahjongTileBackView(width: 56)
        MahjongTileBackView(width: 40)
    }
    .padding(28)
    .screenBackground(.content)
}

#Preview("Tile back styles") {
    VStack(spacing: 16) {
        HStack(spacing: 14) {
            MahjongTileBackView(width: 64).environment(\.tileBackStyle, .gold)
            MahjongTileBackView(width: 64).environment(\.tileBackStyle, .velvet)
            MahjongTileBackView(width: 64).environment(\.tileBackStyle, .jade)
        }
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                MahjongTileBackView(width: 40, seed: UInt64(i) * 97 + 3)
                    .environment(\.tileBackStyle, .jade)
            }
        }
    }
    .padding(28)
    .screenBackground(.content)
}
#endif

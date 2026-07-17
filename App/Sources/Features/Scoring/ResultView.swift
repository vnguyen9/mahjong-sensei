import SwiftUI
import UIKit
import DesignSystem
import MahjongCore
import ScoringEngine

/// Lane 2 · Result (spec screen 9) + Why this score (screen 10).
/// Fully engine-driven: the confirmed hand is scored live by `ScoringEngine`
/// using the seat/round/win context gathered in the flow.
struct ResultView: View {
    private let onClose: () -> Void
    @State private var showWhy = false

    private let isSelfDraw: Bool
    private let score: ScoreResult
    private let capturedPhoto: UIImage?

    init(session: ScanSession, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.isSelfDraw = session.isSelfDraw
        self.score = ScoringEngine.score(hand: session.hand, context: session.gameContext)
        self.capturedPhoto = session.capturedPhoto
    }

    var body: some View {
        ZStack {
            CapturedBackdrop(photo: capturedPhoto, fallback: .content)
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 16) {
                        heroCard
                        meldStrip
                        breakdownCard
                        actions
                    }
                    .padding(20)
                    .padding(.bottom, 104)
                }
            }
        }
        .sheet(isPresented: $showWhy) {
            WhyThisScoreSheet(score: score)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            Text("Result").font(MJFont.serif(18, weight: .bold)).foregroundStyle(MJColor.creamHeading)
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MJColor.cream(0.8))
                    .frame(width: 30, height: 30)
                    .background(MJColor.cardRaised, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
    }

    private var heroCard: some View {
        VStack(spacing: 12) {
            Text(isSelfDraw ? "You win · 自摸" : "You win")
                .eyebrowStyle(MJColor.cream(0.7))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(score.totalFaan)")
                    .font(MJFont.serif(64, weight: .bold))
                    .foregroundStyle(MJColor.lightGold)
                Text("番").font(MJFont.serif(26, weight: .bold)).foregroundStyle(MJColor.lightGold)
            }
            StatusPill("→ \(points) points")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [MJColor.jade, MJColor.jadeHeroDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(MJColor.gold(0.42), lineWidth: 1)
                }
        }
        .shadow(color: Color(white: 0, opacity: 0.4), radius: 13, y: 10)
    }

    /// Simplified base points: 2^faan (7 faan → 128), matching the walkthrough.
    private var points: Int { 1 << score.totalFaan }

    private var meldStrip: some View {
        let groups = score.winningDecomposition?.allGroups ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, meld in
                    VStack(spacing: 6) {
                        HStack(spacing: 2) {
                            ForEach(Array(meld.tiles.enumerated()), id: \.offset) { _, tile in
                                MahjongTileView(tile, theme: .jade, width: 22)
                            }
                        }
                        Text(meldLabel(meld))
                            .font(MJFont.ui(9, weight: .semibold))
                            .foregroundStyle(MJColor.cream(0.6))
                    }
                    .padding(8)
                    .background(MJColor.meldGroupBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func meldLabel(_ m: Meld) -> String {
        switch m.kind {
        case .chow: return "Chow"
        case .pung: return "Pung"
        case .kong: return "Kong"
        case .pair: return "Pair"
        }
    }

    private var breakdownCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(score.components.enumerated()), id: \.offset) { i, component in
                BreakdownRow(english: component.englishName,
                             zh: component.traditionalChineseName,
                             faan: component.faan)
                if i < score.components.count - 1 {
                    Divider().overlay(MJColor.gold(0.12))
                }
            }
            Divider().overlay(MJColor.gold(0.12))
            HStack {
                Text("Total").font(MJFont.ui(13, weight: .bold)).foregroundStyle(MJColor.creamHeading)
                Spacer()
                Text("\(score.totalFaan) 番").font(MJFont.serif(15, weight: .bold)).foregroundStyle(MJColor.gold)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
        }
        .mjCard(padding: 4)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            SecondaryButton("Why?") { showWhy = true }
            GoldButton("Save hand") { onClose() }
        }
    }
}

private struct BreakdownRow: View {
    let english: String
    let zh: String
    let faan: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(english).font(MJFont.ui(12, weight: .semibold)).foregroundStyle(MJColor.creamHeading)
                Text(zh).font(MJFont.serif(11, weight: .regular)).foregroundStyle(MJColor.cream(0.5))
            }
            Spacer()
            Text("+\(faan)").font(MJFont.serif(13, weight: .bold)).foregroundStyle(MJColor.gold)
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
    }
}

/// Screen 10 — per-faan teaching cards.
private struct WhyThisScoreSheet: View {
    let score: ScoreResult

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SheetGrabber().frame(maxWidth: .infinity).padding(.top, 10)
                    Text("Why \(score.totalFaan) faan?")
                        .font(MJFont.serif(20, weight: .bold))
                        .foregroundStyle(MJColor.creamHeading)

                    ForEach(Array(score.components.enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(c.englishName) \(c.traditionalChineseName)")
                                    .font(MJFont.ui(13, weight: .semibold))
                                    .foregroundStyle(MJColor.creamHeading)
                                Spacer()
                                Text("+\(c.faan)").font(MJFont.serif(13, weight: .bold)).foregroundStyle(MJColor.gold)
                            }
                            if let reason = Self.reason(for: c.category) {
                                Text(reason).font(MJFont.ui(11.5))
                                    .foregroundStyle(MJColor.cream(0.65))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .mjCard()
                    }
                }
                .padding(20)
                .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
    }

    static func reason(for category: FaanCategory) -> String? {
        switch category {
        case .halfFlush:          return "One suit plus honor tiles only — no second number suit."
        case .fullFlush:          return "A single suit end to end, with no honors."
        case .dragonPung:         return "A triplet of dragons always scores, whatever your seat."
        case .prevailingWindPung: return "A triplet of the round wind scores this round."
        case .seatWindPung:       return "A triplet of your seat wind scores for you."
        case .selfDraw:           return "You drew the winning tile yourself."
        case .allTriplets:        return "Every set is a triplet — no runs at all."
        case .fullyConcealed:     return "You never revealed a meld before winning."
        default:                  return nil
        }
    }
}

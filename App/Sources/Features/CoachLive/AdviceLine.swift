import SwiftUI
import DesignSystem
import MahjongCore
import CoachEngine

// MARK: - Placeholder-engine display helpers
//
// `CoachAdvisor`'s current (placeholder) implementation always returns
// `RankedDiscard.waits == nil` / `WaitSet.waits == nil` — exact per-wait faan
// needs `ScoringEngine` wired through `WaitScoring`, a later CoachEngine
// chunk (see `CoachAdvisor.swift`'s own doc comment). At shanten 0, though,
// `ukeire` (which the placeholder DOES compute correctly via
// `EfficiencyEngine`) already contains exactly the waiting tiles — drawing
// one is what completes the hand. These helpers read the real `waits` when
// present (future-proof) and fall back to `ukeire` today, so no view has to
// change once the EV task lands.

extension RankedDiscard {
    var displayWaits: [(tile: Tile, seenCount: Int, liveCount: Int)] {
        if let waits, !waits.isEmpty {
            return waits.map { ($0.tile, $0.seenCount, $0.liveCount) }
        }
        guard shantenAfter <= 0 else { return [] }
        return ukeire.map { ($0.tile, $0.seenCount, $0.liveCount) }.sorted { $0.tile < $1.tile }
    }
}

extension WaitSet {
    var displayWaits: [(tile: Tile, seenCount: Int, liveCount: Int)] {
        if let waits, !waits.isEmpty {
            return waits.map { ($0.tile, $0.seenCount, $0.liveCount) }
        }
        guard shanten <= 0 else { return [] }
        return ukeire.map { ($0.tile, $0.seenCount, $0.liveCount) }.sorted { $0.tile < $1.tile }
    }
}

extension CoachAdvice {
    /// The tiles currently completing the hand, regardless of phase — used
    /// by `CountsTab`'s gold wait ring.
    var currentWaitTileSet: Set<Tile> {
        if let best { return Set(best.displayWaits.map(\.tile)) }
        if let waitSet { return Set(waitSet.displayWaits.map(\.tile)) }
        return []
    }
}

/// `n <= 0 ? "tenpai" : "n-shanten"` — the `CoachView` convention, reused verbatim.
func shantenLabel(_ n: Int) -> String { n <= 0 ? "tenpai" : "\(n)-shanten" }

// MARK: - AdviceLine

/// One-sentence advice with inline tiles (UI plan §10 — mockup sentence
/// verbatim) — fixed-height, never hides under compression. Tap →
/// `AdviceDetailSheet`.
struct AdviceLine: View {
    @Environment(CoachLiveSession.self) private var session
    @Environment(\.liveControlMetrics) private var metrics
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if let best = session.advice?.best {
                    discardAdvice(best)
                } else if let waitSet = session.advice?.waitSet {
                    waitAdvice(waitSet)
                } else {
                    Text("watching the table…")
                        .font(MJFont.ui(12 * metrics.scale, weight: .medium))
                        .foregroundStyle(MJColor.cream(0.5))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .frame(minHeight: metrics.minimumEditHitTarget)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func discardAdvice(_ best: RankedDiscard) -> some View {
        HStack(spacing: 4) {
            MahjongTileView(best.tile, width: 19 * metrics.scale)
            Text("→ \(shantenLabel(best.shantenAfter)) · waits")
                .font(MJFont.ui(12 * metrics.scale, weight: .semibold)).foregroundStyle(MJColor.lightGold)
            ForEach(Array(best.displayWaits.prefix(4).enumerated()), id: \.offset) { _, w in
                MahjongTileView(w.tile, width: 19 * metrics.scale)
            }
            Text("· \(best.displayWaits.reduce(0) { $0 + $1.liveCount }) live · \(pct(best.nextDrawOdds)) next draw")
                .font(MJFont.ui(12 * metrics.scale, weight: .semibold)).foregroundStyle(MJColor.lightGold)
        }
    }

    private func waitAdvice(_ waitSet: WaitSet) -> some View {
        HStack(spacing: 4) {
            Text("\(shantenLabel(waitSet.shanten)) · waits")
                .font(MJFont.ui(12 * metrics.scale, weight: .semibold)).foregroundStyle(MJColor.lightGold)
            ForEach(Array(waitSet.displayWaits.prefix(4).enumerated()), id: \.offset) { _, w in
                MahjongTileView(w.tile, width: 19 * metrics.scale)
            }
            Text("· \(waitSet.totalLive) live · \(pct(waitSet.nextDrawOdds)) next draw")
                .font(MJFont.ui(12 * metrics.scale, weight: .semibold)).foregroundStyle(MJColor.lightGold)
        }
    }

    private func pct(_ odds: Double) -> String { String(format: "%.1f%%", odds * 100) }
}

// MARK: - WaitChips

/// Folds at `.minimal` compression (its info survives inline in `AdviceLine`).
struct WaitChips: View {
    @Environment(CoachLiveSession.self) private var session
    @Environment(\.liveCompression) private var compression
    @Environment(\.liveControlMetrics) private var metrics

    private var waits: [(tile: Tile, seenCount: Int, liveCount: Int)] {
        session.advice?.best?.displayWaits ?? session.advice?.waitSet?.displayWaits ?? []
    }

    var body: some View {
        if !waits.isEmpty, compression != .minimal {
            HStack(spacing: 7 * metrics.scale) {
                ForEach(Array(waits.prefix(4).enumerated()), id: \.offset) { _, w in
                    chip(w)
                }
                if waits.count > 4 {
                    Text("+\(waits.count - 4)")
                        .font(MJFont.ui(11.5 * metrics.scale, weight: .semibold))
                        .foregroundStyle(MJColor.cream(0.6))
                        .padding(.horizontal, 8 * metrics.scale).padding(.vertical, 6 * metrics.scale)
                }
            }
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ w: (tile: Tile, seenCount: Int, liveCount: Int)) -> some View {
        HStack(spacing: 5 * metrics.scale) {
            MahjongTileView(w.tile, width: 19 * metrics.scale)
            SeenPips(seen: w.seenCount)
            Text("\(w.liveCount) live").font(MJFont.ui(11.5 * metrics.scale)).foregroundStyle(MJColor.cream(0.7))
        }
        .padding(.horizontal, 10 * metrics.scale).padding(.vertical, 6 * metrics.scale)
        .background(MJColor.gold(0.14), in: RoundedRectangle(cornerRadius: 11 * metrics.scale, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11 * metrics.scale, style: .continuous).strokeBorder(MJColor.gold(0.4), lineWidth: 1) }
    }
}

// MARK: - AdviceDetailSheet

/// The one surface for the rest of `CoachAdvice.options` — ranked list with
/// EV, win%, reason chips. Rehomes the deleted discard-trainer's depth
/// without new chrome (UI plan §10 — the one deliberate extension beyond the
/// mockup).
struct AdviceDetailSheet: View {
    @Environment(CoachLiveSession.self) private var session

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SheetGrabber().frame(maxWidth: .infinity).padding(.top, 10)
                    Text("Ranked discards").font(MJFont.serif(17, weight: .bold)).foregroundStyle(MJColor.creamHeading)

                    if let options = session.advice?.options, !options.isEmpty {
                        ForEach(options) { option in
                            row(option, isBest: option.id == session.advice?.best?.id)
                        }
                    } else if let waitSet = session.advice?.waitSet {
                        waitRow(waitSet)
                    } else {
                        Text("Watching the table for your next decision.")
                            .font(MJFont.ui(12)).foregroundStyle(MJColor.cream(0.6))
                    }
                }
                .padding(20)
                .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ option: RankedDiscard, isBest: Bool) -> some View {
        HStack(spacing: 10) {
            MahjongTileView(option.tile, width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(shantenLabel(option.shantenAfter)) · \(option.ukeireTotal) tiles")
                        .font(MJFont.ui(12, weight: .semibold)).foregroundStyle(MJColor.creamHeading)
                    if isBest { MJTag("BEST", kind: .best) }
                    if !option.meetsMinimum { MJTag("AVOID", kind: .avoid) }
                }
                if !option.reasons.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(option.reasons.prefix(2).enumerated()), id: \.offset) { _, reason in
                            MJTag(reason.englishText, kind: .detail)
                        }
                    }
                }
                if option.expectedFaan > 0 {
                    Text("EV \(String(format: "%.1f", option.expectedFaan)) faan")
                        .font(MJFont.ui(10.5)).foregroundStyle(MJColor.cream(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .mjCard(cornerRadius: 12)
        .overlay {
            if isBest {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MJColor.gold, lineWidth: 1.5)
            }
        }
    }

    private func waitRow(_ waitSet: WaitSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(shantenLabel(waitSet.shanten)) · \(waitSet.totalLive) live tiles")
                .font(MJFont.ui(13, weight: .semibold)).foregroundStyle(MJColor.creamHeading)
            if !waitSet.displayWaits.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(waitSet.displayWaits.enumerated()), id: \.offset) { _, w in
                        MahjongTileView(w.tile, width: 26)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mjCard()
    }
}

import SwiftUI
import DesignSystem
import MahjongCore
import EfficiencyEngine

/// Lane 3 · Coach — the discard trainer (spec screens 12–13), driven live by
/// `EfficiencyEngine`. Ranks every discard by shanten + ukeire and teaches the wait.
struct CoachView: View {
    @Environment(ScanCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var explaining: DiscardRow?

    private var session: ScanSession { coordinator.session }
    private var options: [EfficiencyEngine.DiscardOption] {
        // Table-aware: subtract the discard pond + opponents' melds so ukeire is live.
        EfficiencyEngine.rankDiscards(session.hand, tableSeen: session.seenHistogram)
    }

    private struct DiscardRow: Identifiable {
        let option: EfficiencyEngine.DiscardOption
        let tag: MJTag.Kind?
        var id: Int { option.discard.classIndex }
    }

    var body: some View {
        ZStack {
            CapturedBackdrop(photo: session.capturedPhoto, fallback: .content)
            VStack(spacing: 0) {
                header
                coachCountWarning
                tableReadRow
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        handTray
                        Text("Best discards").eyebrowStyle()
                        ForEach(rows) { row in
                            Button { explaining = row } label: { discardRowView(row) }
                                .buttonStyle(.plain)
                        }
                        valueOverlayCard
                    }
                    .padding(20)
                    .padding(.bottom, 104)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $explaining) { row in
            WaitQualitySheet(option: row.option, unseen: session.unseenCount)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(MJFont.ui(14, weight: .medium)).foregroundStyle(MJColor.gold)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Coach").font(MJFont.serif(17, weight: .bold)).foregroundStyle(MJColor.creamHeading)
            Spacer()
            StatusPill(shantenLabel(bestShanten))
        }
        .padding(.horizontal, 20).padding(.top, 16)
    }

    @ViewBuilder private var coachCountWarning: some View {
        if session.countStatus(for: .coach) != .valid {
            let need = 14 - 3 * session.myMelds.count
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(MJColor.amberLowConf)
                Text("Coach needs \(need) concealed tile\(need == 1 ? "" : "s") here — you have \(session.playable.count).")
                    .font(MJFont.ui(11.5, weight: .medium)).foregroundStyle(MJColor.cream(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(MJColor.amberLowConf.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 20).padding(.top, 8)
        }
    }

    /// Shows when the table pool is populated — signals the outs are live counts.
    @ViewBuilder private var tableReadRow: some View {
        if !session.tablePool.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(MJColor.gold(0.85))
                Text("Reading \(session.tablePool.count) table tile\(session.tablePool.count == 1 ? "" : "s") — outs below are live.")
                    .font(MJFont.ui(11, weight: .medium)).foregroundStyle(MJColor.cream(0.7))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 6)
        }
    }

    // MARK: Hand tray

    private var handTray: some View {
        let recIndex = options.first.flatMap { session.tiles.firstIndex(of: $0.discard) }
        return HStack(spacing: 3) {
            ForEach(Array(session.tiles.enumerated()), id: \.offset) { i, tile in
                MahjongTileView(tile, theme: .jade, width: 20)
                    .overlay {
                        if i == recIndex {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(MJColor.gold, lineWidth: 2).padding(-2)
                                .shadow(color: MJColor.gold(0.6), radius: 5)
                        }
                    }
            }
            // Exposed melds sit locked to the right, dimmed — not discardable.
            ForEach(Array(session.myMelds.enumerated()), id: \.offset) { _, meld in
                Rectangle().fill(MJColor.gold(0.3)).frame(width: 1, height: 22).padding(.horizontal, 1)
                ForEach(Array(meld.tiles.enumerated()), id: \.offset) { _, t in
                    MahjongTileView(t, theme: .jade, width: 20).opacity(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Discard rows

    private func discardRowView(_ row: DiscardRow) -> some View {
        HStack(spacing: 10) {
            MahjongTileView(row.option.discard, theme: .jade, width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(shantenLabel(row.option.shantenAfter)) · \(row.option.ukeireCount) tiles")
                        .font(MJFont.ui(12, weight: .semibold))
                        .foregroundStyle(MJColor.creamHeading)
                    if let tag = row.tag {
                        MJTag(tag == .best ? "BEST" : "AVOID", kind: tag)
                    }
                }
                Text(note(for: row))
                    .font(MJFont.ui(10, weight: .regular))
                    .foregroundStyle(MJColor.cream(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(MJColor.cream(0.35))
        }
        .mjCard(cornerRadius: 12, selected: false)
        .overlay {
            if row.tag == .best {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MJColor.gold, lineWidth: 1.5)
            }
        }
    }

    private var valueOverlayCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Value, not just speed").font(MJFont.ui(12, weight: .semibold)).foregroundStyle(MJColor.amberWarn)
            Text("HK needs a faan minimum, so Coach weights the line that can actually win — not just the fastest one to tenpai.")
                .font(MJFont.ui(10.5)).foregroundStyle(MJColor.cream(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(MJColor.amberLowConf.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(MJColor.amberLowConf.opacity(0.25), lineWidth: 1) }
    }

    // MARK: Data

    private var rows: [DiscardRow] {
        guard let best = options.first else { return [] }
        var result = [DiscardRow(option: best, tag: .best)]
        if options.count > 2 { result.append(DiscardRow(option: options[1], tag: nil)) }
        if let worst = options.last, worst.discard != best.discard, worst.shantenAfter > best.shantenAfter {
            result.append(DiscardRow(option: worst, tag: .avoid))
        }
        return result
    }

    private var bestShanten: Int { options.first?.shantenAfter ?? 0 }

    private func shantenLabel(_ n: Int) -> String { n <= 0 ? "tenpai" : "\(n)-shanten" }

    private func note(for row: DiscardRow) -> String {
        if row.option.shantenAfter <= 0, row.option.ukeireCount == 0 {
            return "Dead wait — every winning tile is already on the table. Reshape if you can."
        }
        switch row.tag {
        case .best:  return "Best efficiency — \(row.option.ukeireCount) live tiles push the hand forward."
        case .avoid: return "Sets you back to \(shantenLabel(row.option.shantenAfter)) — breaks your shape."
        default:     return "Playable, but keeps fewer tiles working (\(row.option.ukeireCount) live)."
        }
    }
}

/// Screen 13 — wait quality: which tiles the chosen discard accepts.
private struct WaitQualitySheet: View {
    let option: EfficiencyEngine.DiscardOption
    let unseen: Int

    /// Rough per-draw chance, as a whole-percent string.
    private var oddsText: String {
        let p = EfficiencyEngine.winOdds(liveOuts: option.ukeireCount, unseen: unseen)
        return "\(Int((p * 100).rounded()))%"
    }

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SheetGrabber().frame(maxWidth: .infinity).padding(.top, 10)

                    HStack(spacing: 12) {
                        MahjongTileView(option.discard, theme: .jade, width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Discard \(option.discard.code)")
                                .font(MJFont.serif(16, weight: .bold)).foregroundStyle(MJColor.creamHeading)
                            Text(option.shantenAfter <= 0 ? "Reaches tenpai" : "Reaches \(option.shantenAfter)-shanten")
                                .font(MJFont.ui(12, weight: .medium)).foregroundStyle(MJColor.gold)
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("You then accept").eyebrowStyle()
                        if option.ukeireTiles.isEmpty {
                            Text("A completed hand — no tiles needed.").font(MJFont.ui(12)).foregroundStyle(MJColor.cream(0.7))
                        } else {
                            TileRow(option.ukeireTiles, theme: .jade, width: 26, spacing: 6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mjCard()

                    if option.ukeireCount == 0 {
                        Text("No live tiles remain for this wait — every copy is already on the table. It can't complete as-is.")
                            .font(MJFont.ui(11.5)).foregroundStyle(MJColor.amberWarn)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("\(option.ukeireCount) live tiles advance the hand — about \(oddsText) you draw one on your next pick.")
                            .font(MJFont.ui(11.5)).foregroundStyle(MJColor.cream(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
    }
}

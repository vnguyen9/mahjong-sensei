import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData

/// Unresolved-tile triage: Mine / Table / Not a tile (UI plan §12 #1). The
/// hand-tile-fix and events-tile-fix sheets reuse `CorrectionPicker`
/// (de-privatized from `CorrectView.swift`) directly — no new type needed
/// for those.
///
/// TODO: F — "drag tiles between MY HAND / TABLE on a frozen frame" (UI plan
/// §12 step 12) is explicitly out of scope for this workstream: it's a new
/// gesture surface (freeze a frame, drag-and-drop reassignment) layered on
/// top of this same Mine/Table/Not-a-tile triage, not an extension of it.
/// `assignUnresolved(_:to:)` below is the intent it would ultimately call —
/// wire the gesture to that when it's built.
struct UnresolvedAssignSheet: View {
    @Environment(CoachLiveSession.self) private var session

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            VStack(spacing: 14) {
                SheetGrabber().padding(.top, 10)
                Text("Unresolved tiles").font(MJFont.serif(15, weight: .bold)).foregroundStyle(MJColor.creamHeading)

                if session.unresolved.isEmpty {
                    Text("Nothing to resolve right now.")
                        .font(MJFont.ui(12)).foregroundStyle(MJColor.cream(0.6))
                        .padding(.top, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(session.unresolved) { item in
                                row(item)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ item: UnresolvedTile) -> some View {
        HStack(spacing: 12) {
            if let tile = item.tile {
                MahjongTileView(tile, width: 34)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(MJColor.cream(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 34, height: 46)
                    .overlay { Text("?").font(MJFont.ui(16, weight: .bold)).foregroundStyle(MJColor.cream(0.5)) }
            }
            VStack(spacing: 6) {
                GoldButton("Mine") { session.assignUnresolved(item.id, to: .mine) }
                SecondaryButton("Table") { session.assignUnresolved(item.id, to: .table) }
                TextLink("Not a tile") { session.dismissUnresolved(item.id) }
            }
        }
        .padding(12)
        .mjCard(cornerRadius: 12)
    }
}

/// 0–4 pip stepper for a Counts-tab tile (UI plan §12 #3).
///
/// Decoupled from `CoachLiveSession`: the initial count and the apply action
/// are injected, so this is reusable by other counters (e.g. Tracker) that
/// don't have a `CoachLiveSession` in their environment. `footer` is an
/// extension point for a stats block below the stepper (unused by CoachLive).
struct CountAdjustSheet<Footer: View>: View {
    let tile: Tile
    let initialCount: Int
    let onApply: (Int) -> Void
    @ViewBuilder var footer: () -> Footer
    @State private var count: Int = 0

    init(
        tile: Tile,
        initialCount: Int,
        onApply: @escaping (Int) -> Void,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.tile = tile
        self.initialCount = initialCount
        self.onApply = onApply
        self.footer = footer
    }

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            VStack(spacing: 16) {
                SheetGrabber().padding(.top, 10)
                MahjongTileView(tile, width: 34)
                Text(MahjongData.name(for: tile).english)
                    .font(MJFont.ui(14, weight: .semibold)).foregroundStyle(MJColor.creamHeading)

                HStack(spacing: 14) {
                    stepButton("minus", enabled: count > 0) { count = max(0, count - 1) }
                    SeenPips(seen: count, scale: 2)
                    stepButton("plus", enabled: count < 4) { count = min(4, count + 1) }
                }

                Text("Seen \(count) of 4 · \(4 - count) live")
                    .font(MJFont.ui(12)).foregroundStyle(MJColor.cream(0.65))

                GoldButton("Apply") {
                    onApply(count)
                }

                // Workstream F: one-tap "all four copies are accounted for"
                // shortcut — the stepper already covers "set an exact count"
                // (tap +/- to any of 0–4), so this is purely a shortcut to
                // the common "no more of these are live" case, not a
                // separate exact-count affordance. Reuses the same
                // `onApply` path as the stepper (`setSeenCount`/mock
                // equivalent) — no new session API needed.
                if count != 4 {
                    TextLink("Mark all dead") {
                        count = 4
                        onApply(4)
                    }
                }

                footer()
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            count = initialCount
        }
    }

    private func stepButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(enabled ? MJColor.gold : MJColor.cream(0.25))
                .frame(width: 44, height: 44)
                .background(MJColor.gold(0.1), in: Circle())
                .overlay { Circle().strokeBorder(MJColor.gold(enabled ? 0.35 : 0.12), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Fix who did what, or remove an event entirely (UI plan §12 #4). The tile
/// row taps into `CorrectionPicker` nested in the same sheet.
struct EventFixSheet: View {
    @Environment(CoachLiveSession.self) private var session
    let event: TableEvent
    @State private var pickingTile = false
    @State private var actor: Wind
    @State private var tiles: [Tile]

    init(event: TableEvent) {
        self.event = event
        _actor = State(initialValue: event.actor)
        _tiles = State(initialValue: event.tiles)
    }

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SheetGrabber().frame(maxWidth: .infinity).padding(.top, 10)
                    Text("Fix this event").font(MJFont.serif(15, weight: .bold)).foregroundStyle(MJColor.creamHeading)

                    HStack(spacing: 10) {
                        TileRow(tiles, width: 26, spacing: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(windEnglish(actor)).font(MJFont.ui(13, weight: .semibold)).foregroundStyle(MJColor.creamHeading)
                            Text(event.verb).font(MJFont.ui(11)).foregroundStyle(MJColor.cream(0.6))
                        }
                        Spacer(minLength: 0)
                    }
                    .mjCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tile").eyebrowStyle()
                        Button { pickingTile = true } label: {
                            HStack {
                                if let first = tiles.first { MahjongTileView(first, width: 28) }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(MJColor.cream(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                        .mjCard()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Who").eyebrowStyle()
                        HStack(spacing: 8) {
                            ForEach(Wind.allCases, id: \.self) { wind in
                                FilterChip("\(windGlyph(wind)) \(windEnglish(wind))", active: actor == wind) {
                                    actor = wind
                                    session.amendEvent(event.id, tile: nil, actor: wind)
                                }
                            }
                        }
                    }

                    Button(role: .destructive) {
                        session.deleteEvent(event.id)
                    } label: {
                        Label("Remove event", systemImage: "trash")
                            .font(MJFont.ui(13, weight: .semibold))
                            .foregroundStyle(MJColor.rustAvoid)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(MJColor.rustAvoid.opacity(0.5), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $pickingTile) {
            CorrectionPicker(current: tiles.first, confirmVerb: "Use", onConfirm: { tile in
                tiles = [tile]
                session.amendEvent(event.id, tile: tile, actor: nil)
                pickingTile = false
            }, onRemove: nil)
            .presentationDetents([.height(460)])
            .presentationBackground(.clear)
        }
    }
}

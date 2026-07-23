import SwiftUI
import UIKit
import DesignSystem
import MahjongCore

/// Lets the user pick a tile theme applied everywhere except pinned physical
/// surfaces (camera/AR overlays). "Auto" (the default, `nil`) keeps the app's
/// original split: Jade menus, Ivory game table.
struct TileThemeSettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private static let previewHand: [Tile] = [.p(5), .s(5), .m(7), .dragon(.green)]

    private var effectiveTheme: TileTheme { (app.tileTheme ?? .jade).theme }

    var body: some View {
        @Bindable var app = app
        return ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                MJBackHeader(title: "Appearance") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header

                        Text("Tile theme")
                            .font(MJFont.ui(13, weight: .semibold))
                            .foregroundStyle(MJColor.creamHeading)
                        Text("Applies everywhere — menus, Coach Live, and the game table. Camera and AR overlays keep their physical look.")
                            .font(MJFont.ui(12))
                            .foregroundStyle(MJColor.cream(0.6))
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            Button {
                                app.tileTheme = nil
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                TileThemeSettingRow(
                                    name: "Auto",
                                    subtitle: "Jade menus · Ivory game",
                                    preview: nil,
                                    selected: app.tileTheme == nil
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(app.tileTheme == nil ? "Selected" : "Not selected")

                            ForEach(TileThemeChoice.allCases, id: \.self) { choice in
                                Divider().overlay(MJColor.gold(0.12))
                                Button {
                                    app.tileTheme = choice
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    TileThemeSettingRow(
                                        name: choice.displayName,
                                        subtitle: nil,
                                        preview: choice.theme,
                                        selected: app.tileTheme == choice
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(app.tileTheme == choice ? "Selected" : "Not selected")
                            }
                        }
                        .mjCard(padding: 4)

                        Text("Tile back")
                            .font(MJFont.ui(13, weight: .semibold))
                            .foregroundStyle(MJColor.creamHeading)
                            .padding(.top, 8)
                        Text("The face-down cap shown on the wall, opponents' racks, and concealed melds.")
                            .font(MJFont.ui(12))
                            .foregroundStyle(MJColor.cream(0.6))
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            ForEach(Array(TileBackStyle.allCases.enumerated()), id: \.element) { index, back in
                                if index > 0 { Divider().overlay(MJColor.gold(0.12)) }
                                Button {
                                    app.tileBack = back
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    TileBackSettingRow(back: back, selected: app.tileBack == back)
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(app.tileBack == back ? "Selected" : "Not selected")
                            }
                        }
                        .mjCard(padding: 4)
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(spacing: 14) {
            TileRow(Self.previewHand, theme: effectiveTheme, width: 44, spacing: 4)
            MahjongTileBackView(width: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private struct TileThemeSettingRow: View {
    let name: String
    let subtitle: String?
    let preview: TileTheme?
    let selected: Bool

    private static let previewHand: [Tile] = [.p(5), .s(5), .m(7), .dragon(.green)]

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(MJFont.ui(14, weight: .medium))
                    .foregroundStyle(MJColor.creamHeading)
                if let subtitle {
                    Text(subtitle)
                        .font(MJFont.ui(11))
                        .foregroundStyle(MJColor.cream(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let preview {
                TileRow(Self.previewHand, theme: preview, width: 30, spacing: 2)
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.bold())
                    .foregroundStyle(MJColor.gold)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct TileBackSettingRow: View {
    let back: TileBackStyle
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(back.displayName)
                .font(MJFont.ui(14, weight: .medium))
                .foregroundStyle(MJColor.creamHeading)
            Spacer(minLength: 0)
            MahjongTileBackView(width: 34)
                .environment(\.tileBackStyle, back)
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.bold())
                    .foregroundStyle(MJColor.gold)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

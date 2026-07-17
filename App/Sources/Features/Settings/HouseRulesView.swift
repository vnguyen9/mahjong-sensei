import SwiftUI
import DesignSystem

/// Lane 5 · House Rules (spec screen 21). Preset tabs (Family / Club / Custom)
/// over grouped, editable-looking faan rows. Values are static for now — a real
/// per-row editor comes later — but every row reads as tappable.
struct HouseRulesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preset: Preset = .family

    enum Preset: Hashable { case family, club, custom }

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                MJBackHeader(title: "House Rules") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SegmentedToggle(selection: $preset,
                                        options: [(Preset.family, "Family"),
                                                  (Preset.club, "Club"),
                                                  (Preset.custom, "Custom")])
                            .frame(maxWidth: .infinity)

                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            groupCard(group)
                        }

                        Text("Presets set every value at once; tap a row to override it. House rules feed scoring, coaching, and the dictionary.")
                            .font(MJFont.ui(11))
                            .foregroundStyle(MJColor.cream(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Group card

    private func groupCard(_ group: RuleGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title).eyebrowStyle()
                .padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.offset) { i, rule in
                    ruleRow(rule)
                    if i < group.rows.count - 1 {
                        Divider().overlay(MJColor.gold(0.12))
                    }
                }
            }
            .mjCard(padding: 4)
        }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(rule.name)
                    .font(MJFont.ui(14, weight: .medium))
                    .foregroundStyle(MJColor.creamHeading)
                if let zh = rule.zh {
                    Text(zh)
                        .font(MJFont.serif(12, weight: .regular))
                        .foregroundStyle(MJColor.gold(0.55))
                }
            }
            Spacer(minLength: 8)
            Text(rule.value)
                .font(MJFont.ui(13, weight: .semibold))
                .foregroundStyle(MJColor.gold)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MJColor.cream(0.35))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Double-tap to edit"))
    }

    // MARK: Model

    private struct Rule { let name: String; let zh: String?; let value: String }
    private struct RuleGroup { let title: String; let rows: [Rule] }

    private var groups: [RuleGroup] {
        let limit = preset == .club ? "13 faan" : "10 faan"
        let conversion = preset == .club ? "Full-spicy" : "Half-spicy"
        return [
            RuleGroup(title: "Winning", rows: [
                Rule(name: "Minimum faan", zh: nil, value: "3"),
                Rule(name: "Limit cap", zh: nil, value: limit),
            ]),
            RuleGroup(title: "Ambiguous hands", rows: [
                Rule(name: "All Pungs", zh: "對對糊", value: "3 faan"),
                Rule(name: "Half Flush", zh: "混一色", value: "3 faan"),
                Rule(name: "Conversion", zh: nil, value: conversion),
            ]),
            RuleGroup(title: "Bonus & payments", rows: [
                Rule(name: "Flowers", zh: nil, value: "On"),
                Rule(name: "Self-draw", zh: nil, value: "All pay"),
                Rule(name: "Dealer double", zh: nil, value: "On"),
            ]),
        ]
    }
}

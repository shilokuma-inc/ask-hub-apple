import SwiftUI

/// 審査に出すシートの「スクショ」。基準の言語（最初に撮った言語）の差のある画面は Before / After を横に並べ、変わった所に枠を付ける。
/// ほかの言語は数だけ出して「まとめて OK」を選べ、開けば画面ごとに確かめられる。どの画面も「前のままにする」を選べる
struct StoreScreenshotsSection: View {
    let screenshots: Submission.StoreScreenshots
    /// 前のままにする画面
    @Binding var keep: Set<Submission.ShotKey>

    var body: some View {
        switch screenshots.state {
        case .notConfigured:
            EmptyView()
        case .capturing:
            Section {
                Label("撮っています", systemImage: "camera")
            } header: {
                Text("スクショ")
            }
        case .failed(let reason):
            Section {
                Text("撮れませんでした: \(reason)").foregroundStyle(.secondary)
            } header: {
                Text("スクショ")
            } footer: {
                Text("スクショは変えずに審査に出します")
            }
        case .captured:
            captured
        }
    }

    /// 最初に撮った言語（基準の言語）
    private var baseLocale: String? { screenshots.sets.first?.locale }

    @ViewBuilder private var captured: some View {
        let changed = screenshots.changedSets
        let base = changed.filter { $0.locale == baseLocale }
        let others = changed.filter { $0.locale != baseLocale }
        if changed.isEmpty {
            Section {
                Text("前回の App Store から変わっていません").foregroundStyle(.secondary)
            } header: {
                Text("スクショ")
            } footer: {
                skippedFooter
            }
        }
        ForEach(base) { set in
            Section {
                ForEach(set.changedShots) { shot in
                    ShotComparisonRow(shot: shot, keep: binding(for: set.key(shot)))
                }
                if set.removed > 0 {
                    Text("後ろの \(set.removed) 枚は撮ったものに無いので消します").appFont(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("スクショ · \(set.title)")
            } footer: {
                if set.id == base.last?.id, others.isEmpty { skippedFooter }
            }
        }
        if !others.isEmpty {
            Section {
                Toggle("ほかの言語もまとめて OK", isOn: allOthers(others))
                    .accessibilityIdentifier("store-screenshots-accept-others")
                NavigationLink {
                    OtherLocaleScreenshots(sets: others, keep: $keep)
                } label: {
                    LabeledContent("ほかの言語の差", value: "\(others.count) 組")
                }
            } header: {
                Text("スクショ · ほかの言語")
            } footer: {
                skippedFooter
            }
        }
    }

    @ViewBuilder private var skippedFooter: some View {
        if !screenshots.skipped.isEmpty {
            let lines = screenshots.skipped.map { "\(Submission.ScreenshotSet.displayName($0.displayType)): \($0.reason)" }
            Text("撮らなかったもの（App Store Connect のまま）\n" + lines.joined(separator: "\n"))
        }
    }

    private func binding(for key: Submission.ShotKey) -> Binding<Bool> {
        Binding { keep.contains(key) } set: { isOn in
            if isOn { keep.insert(key) } else { keep.remove(key) }
        }
    }

    /// ほかの言語の差のある画面を、まとめて替える（オン）か前のままにする（オフ）
    private func allOthers(_ sets: [Submission.ScreenshotSet]) -> Binding<Bool> {
        let keys = sets.flatMap { set in set.changedShots.map(set.key) }
        return Binding { keys.allSatisfy { !keep.contains($0) } } set: { isOn in
            if isOn { keep.subtract(keys) } else { keep.formUnion(keys) }
        }
    }
}

/// 1 枚の Before / After（After の変わった所に枠）と「前のままにする」
private struct ShotComparisonRow: View {
    let shot: Submission.Shot
    @Binding var keep: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(shot.index) 枚目 · \(shot.name)").appFont(.footnote, weight: .semibold).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                column("Before", shot.before, highlight: nil, empty: "前回は無い位置")
                column("After", shot.after, highlight: shot.area, empty: "撮れなかった")
            }
            Toggle("前のままにする", isOn: $keep)
                .accessibilityIdentifier("store-screenshot-keep-\(shot.index)")
        }
    }

    private func column(_ title: String, _ screenshot: Screenshot?, highlight: CGRect?, empty: String) -> some View {
        VStack(spacing: 4) {
            Text(title).appFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
            if let screenshot {
                ScreenshotView(screenshot: screenshot, highlight: highlight)
            } else {
                ContentUnavailableView(empty, systemImage: "rectangle.dashed").appFont(.caption).aspectRatio(9 / 16, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// ほかの言語の差のある画面（組ごと）
private struct OtherLocaleScreenshots: View {
    let sets: [Submission.ScreenshotSet]
    @Binding var keep: Set<Submission.ShotKey>

    var body: some View {
        Form {
            ForEach(sets) { set in
                Section {
                    ForEach(set.changedShots) { shot in
                        ShotComparisonRow(shot: shot, keep: Binding {
                            keep.contains(set.key(shot))
                        } set: { isOn in
                            if isOn { keep.insert(set.key(shot)) } else { keep.remove(set.key(shot)) }
                        })
                    }
                } header: {
                    Text(set.title)
                }
            }
        }
        .formStyle(.grouped)
        .pastelBackground()
        .navigationTitle("ほかの言語のスクショ")
    }
}

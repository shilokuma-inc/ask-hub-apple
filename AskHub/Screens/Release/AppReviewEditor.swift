import SwiftUI

/// 審査に出すシートの「App Review の情報」。案があるときだけ出し、「この案で直す」を外せば変えない。
/// デモアカウントのパスワードは扱わない（要るときは App Store Connect で入れる）
struct AppReviewEditor: View {
    let review: Submission.AppReview
    /// 送る直し。nil なら変えない
    @Binding var change: Submission.ReviewInfo?

    var body: some View {
        Section {
            Toggle("この案で直す", isOn: isChanging)
                .accessibilityIdentifier("app-review-change")
            if let value = change {
                TextEditor(text: Binding { value.notes ?? review.current.notes ?? "" } set: { change?.notes = $0 })
                    .frame(minHeight: 120)
                    .accessibilityIdentifier("app-review-notes")
                Toggle("デモアカウントが要る", isOn: Binding {
                    value.demoAccountRequired ?? review.current.demoAccountRequired ?? false
                } set: { change?.demoAccountRequired = $0 })
                if value.demoAccountRequired ?? review.current.demoAccountRequired ?? false {
                    TextField("デモアカウントの名前", text: Binding {
                        value.demoAccountName ?? review.current.demoAccountName ?? ""
                    } set: { change?.demoAccountName = $0 })
                }
            } else {
                Text(review.current.notes ?? "（審査メモは空です）").foregroundStyle(.secondary).lineLimit(6)
            }
        } header: {
            Text("App Review の情報")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        var lines = [review.reason]
        if let notes = change?.notes ?? (change == nil ? nil : review.current.notes) {
            lines.append("審査メモ \(notes.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count) / 4,000 バイト")
        }
        if change?.demoAccountRequired ?? review.current.demoAccountRequired ?? false {
            lines.append("デモアカウントのパスワードは、App Store Connect で入れてください（AskHub では扱いません）")
        }
        return lines.joined(separator: "。")
    }

    private var isChanging: Binding<Bool> {
        Binding { change != nil } set: { isOn in change = isOn ? (review.draft ?? Submission.ReviewInfo()) : nil }
    }

    /// 送れる長さか（司令塔と同じく、メモは UTF-8 のバイト）
    static func accepts(_ change: Submission.ReviewInfo?) -> Bool {
        guard let change else { return true }
        let notes = change.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = change.demoAccountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return notes.utf8.count <= Submission.ReviewInfo.notesLimit && name.unicodeScalars.count <= Submission.ReviewInfo.nameLimit
            && !name.contains(where: \.isNewline)
    }
}

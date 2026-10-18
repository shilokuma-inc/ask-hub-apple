import AskHubKit
import SwiftUI

/// 設定画面の「GitHub でサインイン」。コードを出し、GitHub の画面を開いて承認を待つ
struct GitHubSignInSection: View {
    let model: GitHubSignInModel
    @Environment(\.openURL)
    private var openURL

    var body: some View {
        Section {
            switch model.phase {
            case .idle, .signedIn, .failed:
                Button("GitHub でサインイン") { model.start() }
                    .accessibilityIdentifier("github-sign-in")

            case .requesting:
                HStack {
                    ProgressView()
                    Text("コードを発行しています")
                }
                Button("キャンセル", role: .cancel) { model.cancel() }

            case let .waiting(userCode, verificationURI):
                LabeledContent("コード") {
                    Text(userCode)
                        .font(.title2.monospaced().bold())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("github-user-code")
                }
                Button("GitHub を開いてコードを入力") { openURL(verificationURI) }
                HStack {
                    ProgressView()
                    Text("GitHub での承認を待っています")
                        .foregroundStyle(.secondary)
                }
                Button("キャンセル", role: .cancel) { model.cancel() }
            }

            if model.phase == .signedIn {
                Text("サインインしました")
                    .foregroundStyle(.secondary)
            } else if case let .failed(message) = model.phase {
                Text(message)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("GitHub アカウント")
        } footer: {
            Text("""
                GitHub の画面で表示されたコードを入力し、AskHub を承認してください。\
                トークンはこの端末の Keychain にだけ保存します。\
                アクセスをやめるときは、下の「トークンを削除」に加えて、GitHub の Settings → Applications で AskHub の承認を取り消してください。
                """)
        }
    }
}

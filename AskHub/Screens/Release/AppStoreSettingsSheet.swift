import SwiftUI

/// まだ決めていない決まった値を確かめて、App Store Connect に書くシート
struct AppStoreSettingsSheet: View {
    let setup: AppStoreSetup
    let onClose: () -> Void

    @Environment(ClientStore.self) private var store
    @State private var request = AppStoreSettingsRequest()
    @State private var categoryID = ""
    @State private var contentRights = 0
    @State private var privacyPolicyURL = ""
    @State private var supportURL = ""
    @State private var marketingURL = ""
    @State private var copyright = ""
    @State private var sending = SheetSendState()

    private func needs(_ kind: AppStoreSetup.ItemKind) -> Bool {
        setup.writableItems.contains { $0.kind == kind }
    }

    var body: some View {
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { submit() }
                    }
                }
                if needs(.price) || needs(.availability) {
                    Section {
                        if needs(.price) { Toggle("無料にする", isOn: $request.free) }
                        if needs(.availability) { Toggle("すべての国と地域に配信する", isOn: $request.everywhere) }
                    } header: {
                        Text("価格と配信の地域")
                    } footer: {
                        Text("有料にする・地域を絞るときは、App Store Connect で決めてください（有料には契約と口座が要ります）")
                    }
                }
                if needs(.category) {
                    Section {
                        Picker("カテゴリ", selection: $categoryID) {
                            Text("選んでください").tag("")
                            ForEach(AppStoreCategoryChoice.all) { choice in
                                Text(choice.label).tag(choice.id)
                            }
                        }
                        .accessibilityIdentifier("app-store-category")
                    } header: {
                        Text("カテゴリ")
                    }
                }
                if needs(.contentRights) {
                    Section {
                        Picker("コンテンツの権利", selection: $contentRights) {
                            Text("選んでください").tag(0)
                            Text("第三者のコンテンツを使わない").tag(1)
                            Text("第三者のコンテンツを使う（権利がある）").tag(2)
                        }
                    } header: {
                        Text("コンテンツの権利")
                    }
                }
                if needs(.privacyPolicy) {
                    Section {
                        URLField(prompt: "https://", text: $privacyPolicyURL, identifier: "app-store-privacy-policy")
                    } header: {
                        Text("プライバシーポリシーの URL")
                    } footer: {
                        Text("App Store Connect の言語のうち、まだ書いていない言語に書きます")
                    }
                }
                if needs(.supportUrl) {
                    Section {
                        URLField(prompt: "https://", text: $supportURL, identifier: "app-store-support-url")
                        URLField(prompt: "マーケティング URL（任意）", text: $marketingURL, identifier: "app-store-marketing-url")
                    } header: {
                        Text("サポート URL")
                    } footer: {
                        Text("初めての版の言語のうち、まだ書いていない言語に書きます。マーケティング URL は無くても審査に出せます")
                    }
                }
                if needs(.copyright) {
                    Section {
                        TextField("2026 Shilokuma Inc.", text: $copyright)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("app-store-copyright")
                    } header: {
                        Text("著作権表示")
                    } footer: {
                        Text("権利を得た年と、持ち主（会社名か個人名）を書きます。URL は入れません")
                    }
                }
                if needs(.reviewContact) {
                    Section {
                        Toggle("ほかのアプリの連絡先を写す", isOn: $request.copyReviewContact)
                            .accessibilityIdentifier("app-store-copy-review-contact")
                    } header: {
                        Text("App Review の連絡先")
                    } footer: {
                        Text("司令塔が、同じ鍵のほかのアプリの配信中か審査に出した版から、姓・名・電話番号・メールアドレスを写します。"
                            + "連絡先は AskHub に置きません。写せるアプリが無いときは、App Store Connect で入れてください")
                    }
                }
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("値を書く")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("書く", isSending: sending.isSending) { submit() }
                        .disabled(composed.isEmpty)
                }
            }
            .onAppear {
                // 無料・すべての地域・連絡先を写すは、まだ決めていなければ既定で選んでおく（書くのは「書く」を押したときだけ）
                if !sending.showsStatus {
                    request.free = needs(.price)
                    request.everywhere = needs(.availability)
                    request.copyReviewContact = needs(.reviewContact)
                    // 著作権表示は、今年を入れておく（持ち主は人が書く）
                    if needs(.copyright), copyright.isEmpty { copyright = "\(Calendar.current.component(.year, from: Date())) " }
                }
            }
        }
        .sheetSending(sending)
        .sheetSize(.page)
    }

    /// 選んだ値から作る中身（選んでいない欄は送らない）
    private var composed: AppStoreSettingsRequest {
        var composed = request
        composed.category = AppStoreCategoryChoice.all.first { $0.id == categoryID }
        composed.contentRights = switch contentRights {
        case 1: .doesNotUseThirdPartyContent
        case 2: .usesThirdPartyContent
        default: nil
        }
        composed.privacyPolicyURL = Self.entered(privacyPolicyURL)
        composed.supportURL = Self.entered(supportURL)
        composed.marketingURL = Self.entered(marketingURL)
        let text = copyright.trimmingCharacters(in: .whitespacesAndNewlines)
        // 年だけ（入れておいたまま）なら送らない
        composed.copyright = text.isEmpty || text.allSatisfy(\.isNumber) ? nil : text
        return composed
    }

    /// 入れた URL（空・`https://` のままなら nil）
    private static func entered(_ text: String) -> String? {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty || url == "https://" ? nil : url
    }

    private func submit() {
        if sending.submit(.applyAppStoreSettings(repositoryID: setup.repositoryID, request: composed), in: store) { onClose() }
    }
}

/// URL を入れる欄（自動の修正と大文字を止める）
private struct URLField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String

    var body: some View {
        TextField(prompt, text: $text)
            .textContentType(.URL)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier(identifier)
    }
}

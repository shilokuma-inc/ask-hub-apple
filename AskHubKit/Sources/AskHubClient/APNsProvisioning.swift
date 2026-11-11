import AskHubProtocol
import Foundation

/// iOS の実機の版の APNs の環境を、アプリに埋め込まれた provisioning profile（`embedded.mobileprovision`）から決める。
///
/// APNs は、署名の entitlement `aps-environment` の環境のトークンを返す。Xcode の自動の署名はこの値をビルドの構成（Debug・Release）ではなく
/// profile に合わせる（開発用の署名で作った Release の版も development になる）ので、ビルド設定からは決めない。
/// iOS には自分の署名の entitlement を読む API が無いので、署名に使った profile を読む
public enum APNsProvisioning {
    /// 埋め込みの profile（無ければ nil）から決める。profile が無いのは App Store・TestFlight の版（Apple が profile を外して配る）で、いつも production。
    /// profile があれば、その `Entitlements` の `aps-environment`。push の entitlement が無い・読めないときは nil
    public static func environment(embeddedProfile data: Data?) -> APNsEnvironment? {
        guard let data else { return .production }
        return (entitlements(inProfile: data)?["aps-environment"] as? String).flatMap(APNsEnvironment.init(rawValue:))
    }

    /// profile は署名（CMS）で包んだ XML の plist なので、`<?xml` から `</plist>` までを取り出して読む
    static func entitlements(inProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)
        return (plist as? [String: Any])?["Entitlements"] as? [String: Any]
    }
}

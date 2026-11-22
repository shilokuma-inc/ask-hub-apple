import Foundation

// App Asset Library の応答（`AppStoreConnectScreenshots`）

struct AppStoreConnectImageAttributes: Decodable {
    struct ImageAsset: Decodable {
        var templateUrl: String?
        var width: Int?
        var height: Int?
    }

    var referenceName: String?
    var state: String?
    var imageAsset: ImageAsset?
    var stateDetails: StateDetails?
}

/// 処理の様子の詳しいこと（失敗のわけ）。形が文書と違っても、画像を読めなくしないよう、読めなければ空にする
struct StateDetails: Decodable {
    struct Item: Decodable {
        var code: String?
        var message: String?
        var description: String?
    }

    /// 誤りの文（`code: message` を・でつなぐ）。無ければ nil
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case errors
    }

    init(from decoder: any Decoder) throws {
        let items = (try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([Item].self, forKey: .errors))
        let lines = (items ?? []).compactMap { item -> String? in
            let text = item.message ?? item.description
            switch (item.code, text) {
            case let (code?, text?): return "\(code): \(text)"
            case let (code?, nil): return code
            case let (nil, text?): return text
            default: return nil
            }
        }
        message = lines.isEmpty ? nil : String(lines.joined(separator: "・").prefix(500))
    }
}

struct AppStoreConnectImagesResponse: Decodable {
    var data: [AppStoreConnectResource<AppStoreConnectImageAttributes>]
}

/// 版の言語の配置（`include=image` で画像も入る）
struct AppStoreConnectPlacementsResponse: Decodable {
    struct Attributes: Decodable {
        var placementGroup: String?
    }

    struct Relationships: Decodable {
        var image: AppStoreConnectRelationship?
    }

    struct Item: Decodable {
        var id: String
        var attributes: Attributes?
        var relationships: Relationships?
    }

    struct Links: Decodable {
        var next: String?
    }

    var data: [Item]
    var included: [AppStoreConnectResource<AppStoreConnectImageAttributes>]?
    var links: Links?
}

/// リファレンスデータ（1 件に、配置グループなどの並びが入る）。文書では `data` が 1 件のオブジェクトだが、並びで返っても読む
struct AppStoreConnectRefDataResponse: Decodable {
    struct Group: Decodable {
        var placementProfileGroupId: String?
        var platform: String?
    }

    struct Attributes: Decodable {
        var placementProfileGroups: [Group]?
    }

    var data: [AppStoreConnectResource<Attributes>]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let one = try? container.decode(AppStoreConnectResource<Attributes>.self, forKey: .data) {
            data = [one]
        } else {
            data = try container.decode([AppStoreConnectResource<Attributes>].self, forKey: .data)
        }
    }
}

/// 画像の予約の応答（送る先と範囲）
struct AppStoreConnectImageReservation: Decodable {
    struct Header: Decodable {
        var name: String
        var value: String
    }

    struct Operation: Decodable {
        var method: String
        var url: String
        var length: Int
        var offset: Int
        var requestHeaders: [Header]?
    }

    struct Attributes: Decodable {
        var uploadOperations: [Operation]?
    }

    struct Resource: Decodable {
        var id: String
        var attributes: Attributes?
    }

    var data: Resource
}

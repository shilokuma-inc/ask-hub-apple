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

/// リファレンスデータ（1 件に、配置グループなどの並びが入る）
struct AppStoreConnectRefDataResponse: Decodable {
    struct Group: Decodable {
        var placementProfileGroupId: String?
        var platform: String?
    }

    struct Attributes: Decodable {
        var placementProfileGroups: [Group]?
    }

    var data: [AppStoreConnectResource<Attributes>]
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

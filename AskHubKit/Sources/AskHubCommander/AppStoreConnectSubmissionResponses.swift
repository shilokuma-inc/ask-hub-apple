import Foundation

// App Store Connect の審査の API の応答の形（読む欄だけ）

struct AppStoreConnectCreated: Decodable {
    struct Resource: Decodable {
        var id: String
    }

    var data: Resource
}

struct AppStoreConnectLink: Decodable {
    var id: String
}

struct AppStoreConnectRelationship: Decodable {
    var data: AppStoreConnectLink?
}

struct AppStoreConnectBuildsResponse: Decodable {
    struct Attributes: Decodable {
        var version: String?
        var uploadedDate: String?
        var expired: Bool?
        var usesNonExemptEncryption: Bool?
    }

    struct Relationships: Decodable {
        var preReleaseVersion: AppStoreConnectRelationship?
    }

    struct Item: Decodable {
        var id: String
        var attributes: Attributes?
        var relationships: Relationships?
    }

    struct TrainAttributes: Decodable {
        var platform: String?
        var version: String?
    }

    var data: [Item]
    var included: [AppStoreConnectResource<TrainAttributes>]?
}

struct AppStoreConnectLocalizationsResponse: Decodable {
    struct Attributes: Decodable {
        var locale: String?
        var whatsNew: String?
        var description: String?
        var keywords: String?
        var promotionalText: String?
    }

    var data: [AppStoreConnectResource<Attributes>]
}

struct AppStoreConnectSubmissionsResponse: Decodable {
    struct Attributes: Decodable {
        var platform: String?
        var state: String?
    }

    struct Relationships: Decodable {
        var appStoreVersionForReview: AppStoreConnectRelationship?
    }

    struct Item: Decodable {
        var id: String
        var attributes: Attributes?
        var relationships: Relationships?
    }

    var data: [Item]
}

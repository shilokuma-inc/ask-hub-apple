/// GraphQL の変数の値
public enum GraphQLVariable: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case strings([String])
    case null

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)

        case .int(let value):
            try container.encode(value)

        case .bool(let value):
            try container.encode(value)

        case .strings(let value):
            try container.encode(value)

        case .null:
            try container.encodeNil()
        }
    }
}

/// GraphQL の接続（connection）の `pageInfo`
public struct GraphQLPageInfo: Decodable, Equatable, Sendable {
    public var hasNextPage: Bool
    public var endCursor: String?

    public init(hasNextPage: Bool, endCursor: String?) {
        self.hasNextPage = hasNextPage
        self.endCursor = endCursor
    }
}

/// GraphQL のページングを最後まで追う。
///
/// `fetch` には前のページの `endCursor`（最初は `nil`）が渡されるので、クエリの `after` に使う。
/// `hasNextPage` が真なのにカーソルが進まない場合は、無限ループを避けるためエラーにする
public func collectGraphQLPages<T>(
    _ fetch: (_ after: String?) async throws -> (items: [T], pageInfo: GraphQLPageInfo)
) async throws -> [T] {
    var items: [T] = []
    var cursor: String?
    while true {
        let page = try await fetch(cursor)
        items += page.items
        guard page.pageInfo.hasNextPage else {
            return items
        }
        guard let next = page.pageInfo.endCursor, next != cursor else {
            throw GitHubError.invalidResponse
        }
        cursor = next
    }
}

struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: GraphQLVariable]
}

struct GraphQLResponse<T: Decodable>: Decodable {
    struct Error: Decodable {
        let message: String
    }

    let data: T?
    let errors: [Error]?
}

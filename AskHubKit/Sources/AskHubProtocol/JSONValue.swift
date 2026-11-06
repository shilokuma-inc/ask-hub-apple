import Foundation

/// プロトコルで扱う JSON の値。
///
/// 署名する文字列を RFC 8785 でそろえるため、数は整数だけを扱う（小数は ECMAScript の数の文字列化が要り、
/// 言語ごとの実装の差が出やすいので、プロトコルでは使わない）。整数は ECMAScript で正確に表せる範囲に限る。
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([Self])
    case object([String: Self])

    /// ECMAScript の Number で正確に表せる整数の最大値（2^53 - 1）
    public static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    public enum ParseError: Error, Equatable {
        case notJSON
        case nonInteger
        case integerOutOfRange
    }

    /// JSON の文字列を値に読む。小数と、安全に表せない大きさの整数は受け付けない。
    public init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }

    public init(parsing data: Data) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw Self.parseError(in: error) ?? ParseError.notJSON
        }
    }

    public subscript(key: String) -> Self? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var integerValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    /// 読み取りの失敗の中に、この型が投げた理由（小数・範囲外）があれば取り出す
    static func parseError(in error: any Error) -> ParseError? {
        if let error = error as? ParseError { return error }
        if case let DecodingError.dataCorrupted(context) = error, let error = context.underlyingError as? ParseError {
            return error
        }
        return nil
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            guard (-Self.maxSafeInteger...Self.maxSafeInteger).contains(value) else {
                throw Self.corrupted(decoder, .integerOutOfRange, "安全に表せない大きさの整数")
            }
            self = .integer(value)
        } else if (try? container.decode(Double.self)) != nil {
            throw Self.corrupted(decoder, .nonInteger, "整数でない数")
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            // 配列かどうかは読んでみないと分からない。中の要素が投げた理由（小数など）は握りつぶさずに伝える
            do {
                self = .array(try container.decode([Self].self))
                return
            } catch {
                if Self.parseError(in: error) != nil { throw error }
            }
            self = .object(try container.decode([String: Self].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    private static func corrupted(_ decoder: any Decoder, _ reason: ParseError, _ description: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: description, underlyingError: reason))
    }
}

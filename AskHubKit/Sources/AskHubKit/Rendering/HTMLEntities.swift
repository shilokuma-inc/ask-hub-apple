import Foundation

/// HTML の文字参照（`&amp;` `&#39;` `&#x1F600;`）のデコード
enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": "\u{00A0}"
    ]

    static func decode(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "&", let entity = decode(chars, at: index) {
                result.append(entity.text)
                index = entity.endIndex
            } else {
                result.append(chars[index])
                index += 1
            }
        }
        return result
    }

    /// `start` の `&` から始まる文字参照を 1 つ読む。解釈できなければ `nil`
    static func decode(_ chars: [Character], at start: Int) -> (text: String, endIndex: Int)? {
        var cursor = start + 1
        var body = ""
        while cursor < chars.count, body.count < 12, chars[cursor] != ";" {
            let char = chars[cursor]
            guard char.isLetter || char.isNumber || char == "#" else {
                return nil
            }
            body.append(char)
            cursor += 1
        }
        guard cursor < chars.count, chars[cursor] == ";", !body.isEmpty else {
            return nil
        }
        let text: String
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let scalarValue: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                scalarValue = UInt32(digits.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(digits, radix: 10)
            }
            guard let scalarValue, scalarValue != 0, let scalar = Unicode.Scalar(scalarValue) else {
                return nil
            }
            text = String(Character(scalar))
        } else {
            guard let decoded = named[body] else {
                return nil
            }
            text = decoded
        }
        return (text, cursor + 1)
    }
}

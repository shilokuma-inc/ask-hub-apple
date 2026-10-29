import Foundation

/// `extract-zip` の展開先の確かめ（Issue #771 の第三者レビュー）。
///
/// `AttachmentZipExtractor` は展開の前に展開先を消すので、サブコマンドを直接呼んでもホームなどを消さないよう、入口で最低限を確かめる。
/// 添付の置き場所の中かどうかは中継（`scripts/orchestrator/extract-attachment-zip.sh`）が確かめる。ここでは置き場所を知らなくても言える条件だけを見る。
/// パスはほかの zip の処理と同じく UTF-8 のバイト単位で比べる
enum AttachmentZipDestination {
    struct Refusal: Error, Equatable {
        let reason: String
    }

    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")

    /// 展開してよければ、リンクを解いた展開先の絶対パス（末尾の `/` なし）を返す。
    /// `homes` はホームとみなすディレクトリ（環境変数の `HOME` とアカウントのホーム）。それと同じか上の階層は断る
    static func resolve(_ path: String, homes: [String]) throws(Refusal) -> String {
        let components = try checkedComponents(of: path)
        let resolved = try resolvingLinks(components)
        try checkResolved(resolved, homes: homes)
        return resolved
    }

    /// 解く前の文字列で確かめ、`/` で区切った要素を返す（絶対パス・制御文字・`.` と `..`・展開先そのものがリンクでないこと）
    private static func checkedComponents(of path: String) throws(Refusal) -> [[UInt8]] {
        guard path.utf8.first == slash else {
            throw Refusal(reason: "展開先は絶対パスで指定してください: \(path)")
        }
        guard !path.unicodeScalars.contains(where: isControl) else {
            throw Refusal(reason: "展開先に制御文字があります")
        }
        let components = split(path)
        if components.contains(where: { $0 == [dot] || $0 == [dot, dot] }) {
            throw Refusal(reason: "展開先に . か .. の要素があります: \(path)")
        }
        // 末尾の / を落とした形で見る（`link.d/` はリンクの先を指すため）
        let trimmed = joined(components)
        if isSymbolicLink(trimmed) {
            throw Refusal(reason: "展開先がシンボリックリンクです: \(trimmed)")
        }
        return components
    }

    /// 展開先は無いことが多いので、あるところまで上ってリンクを解き、残りを足す
    private static func resolvingLinks(_ components: [[UInt8]]) throws(Refusal) -> String {
        var existing = components
        var rest: [[UInt8]] = []
        while !existing.isEmpty, !exists(joined(existing)) {
            rest.insert(existing.removeLast(), at: 0)
        }
        guard let realExisting = realPath(joined(existing)), isDirectory(realExisting) else {
            throw Refusal(reason: "展開先の親がディレクトリではありません: \(joined(existing))")
        }
        return joined(split(realExisting) + rest)
    }

    /// リンクを解いた後の形で確かめる（名前が `.d` で終わる・ホームかその上でない・git の work tree の中でない）
    private static func checkResolved(_ resolved: String, homes: [String]) throws(Refusal) {
        guard let name = split(resolved).last, name.count > 2, name.suffix(2).elementsEqual([dot, UInt8(ascii: "d")]) else {
            throw Refusal(reason: "展開先の名前は .d で終わるものにしてください（<ファイル名>.d）: \(resolved)")
        }
        for home in homes {
            let realHome = realPath(home) ?? home
            if resolved.utf8.elementsEqual(realHome.utf8) || realHome.utf8.starts(with: Array(resolved.utf8) + [slash]) {
                throw Refusal(reason: "展開先がホームかホームより上の階層です: \(resolved)")
            }
        }
        // git の work tree の中なら、checkout のファイルを消しかねないので断る（git は起動せず、親の方向に .git を探す）。
        // 展開先そのものは前の展開の残りで、zip の中の .git があるかもしれないので、親から探す
        var directory = Array(split(resolved).dropLast())
        while true {
            if exists(joined(directory + [Array(".git".utf8)])) {
                throw Refusal(reason: "展開先が git のリポジトリの中です: \(resolved)")
            }
            guard !directory.isEmpty else {
                return
            }
            directory.removeLast()
        }
    }

    private static func split(_ path: String) -> [[UInt8]] {
        Array(path.utf8).split(separator: slash).map(Array.init)
    }

    private static func joined(_ components: [[UInt8]]) -> String {
        let bytes = components.flatMap { [slash] + $0 }
        // 要素は UTF-8 の文字列を 0x2F で区切ったものなので、つなぎ直しても UTF-8 として読める
        // swiftlint:disable:next optional_data_string_conversion
        return bytes.isEmpty ? "/" : String(decoding: bytes, as: UTF8.self)
    }

    /// リンクをたどらずに、何かがあるか（壊れたリンクも「ある」とする）
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// `URL.resolvingSymlinksInPath()` は `/private` を外すので `realpath(3)` を使う
    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else {
            return nil
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// U+0000〜U+001F・U+007F〜U+009F・U+2028・U+2029
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
    }
}

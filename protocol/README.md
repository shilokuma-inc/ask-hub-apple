# protocol

AskHub のリニューアルのプロトコルを、言語に依存しない形で置く（`docs/renewal/protocol.md`）。
Swift（`AskHubKit` の `AskHubProtocol`）と、後から作る Kotlin のクライアントは、どちらもここを正本にしてテストする。

| 場所 | 中身 |
| --- | --- |
| `schemas/` | JSON Schema（draft 2020-12） |
| `vectors/identifiers.json` | パスに使う値（ULID・リポジトリの owner/name・鍵の id）と時刻の、受け付ける値と受け付けない値の例（`schemas/common.schema.json`） |
| `vectors/canonical-json.json` | RFC 8785 で JSON の値をそろえる例と、受け付けない値の例 |
| `vectors/intent-signature.json` | 人の意図の封筒の署名と、確かめた結果の例 |
| `vectors/marker.json` | コメントから目印を読む例と、目印を書く例 |

- `vectors/intent-signature.json` の秘密鍵は、テスト専用に固定の文字列から作ったもの。本番では使わない
- テスト用の例は、自分の実装とは別の手段で作る（そろえた文字列と本文のハッシュは Python の標準ライブラリ、署名は CryptoKit）。実装の出力をそのまま正解にしない

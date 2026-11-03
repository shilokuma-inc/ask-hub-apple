# protocol

AskHub のリニューアルのプロトコルを、言語に依存しない形で置く（`docs/renewal/protocol.md`）。
Swift（`AskHubKit` の `AskHubProtocol`）と、後から作る Kotlin のクライアントは、どちらもここを正本にしてテストする。

| 場所 | 中身 |
| --- | --- |
| `schemas/` | JSON Schema（draft 2020-12） |
| `vectors/identifiers.json` | パスに使う値（ULID・リポジトリの owner/name・Mac の名前・鍵の id）と時刻の、受け付ける値と受け付けない値の例（`schemas/common.schema.json`） |
| `vectors/canonical-json.json` | RFC 8785 で JSON の値をそろえる例と、受け付けない値の例 |
| `vectors/intent-signature.json` | 人の意図の封筒の署名と、確かめた結果の例 |
| `vectors/marker.json` | コメントから目印を読む例と、目印を書く例 |
| `vectors/key-ledger.json` | 公開鍵の記録の列を確かめる例（登録・取り消し・つながり・署名した鍵） |
| `vectors/stored-intent.json` | 状態リポジトリの `intents/` に置く人の意図（本文なし）を確かめる例 |
| `vectors/state/` | 状態リポジトリのファイルを読む例。スキーマに合うか（`schemaValid`）と、読む側の結果（`read`）を分けて持つ |

- `vectors/intent-signature.json`・`vectors/key-ledger.json` の秘密鍵は、テスト専用に固定の文字列から作ったもの。本番では使わない
- 例がスキーマに合うかも、テストで確かめる。Swift ではテストの中の小さな検証（`SchemaValidator`。外部の依存を足さないため、`schemas/` で使うキーワードだけに対応し、知らないキーワードは失敗にする）を使う
- スキーマの正規表現の `$` は、処理系によって末尾の改行の前でも合う。長さの決まった値は `maxLength` でも区切り、そうでない値は改行を含まないことを別に確かめる
- テスト用の例は、自分の実装とは別の手段で作る（そろえた文字列と本文のハッシュは Python の標準ライブラリ、署名は CryptoKit）。実装の出力をそのまま正解にしない

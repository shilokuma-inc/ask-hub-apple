#!/usr/bin/env python3
"""最新情報の確定（.github/workflows/release-notes.yml）の、検査とファイルの書き換え（Discussion #605 の Q5）。

結果は JSON で標準出力に出す（ワークフローは jq で読む）。人に向けた説明は標準エラーにも出す。

    python3 Tools/release_notes.py check --version 1.1.0                       # 確定してよい release ブランチかを確かめる
    WHATS_NEW='{"ja":"…"}' python3 Tools/release_notes.py apply --version 1.1.0 # whatsNew を書き、下書きを消す

- `check`: `release/<v>` があり、`v<v>` のタグが無いことを `git ls-remote <remote>` で確かめる。
  前の `v*` タグが 1 つも無い（初めてのリリース）なら `initial: true` と注意を返す
- `apply`: 環境変数（既定 `WHATS_NEW`）の JSON（言語コード → 本文）を検査し、`--root` の
  `AppStore/metadata/<言語>.json` の `whatsNew` を `{"version": <v>, "text": <本文>}` にして、下書き
  `AppStore/whats-new-draft.json` を消す。検査は書き込む前にすべての言語で行い、1 つでも問題があれば何も書かない。
  同じ内容で何度実行しても同じファイルになる（変化が無ければ `changed: false`）

`whats_new` の決まり: JSON のオブジェクト・キーは `AppStore/languages.json` の `language` をすべて（過不足なく）・
値は文字列・前後の空白を外して空でなく 4000 字（Python の `len`）まで・テンプレートの仮の文言（`TODO:`）を含まない。
本文は前後の空白を外して書く。

終了コード: 0 = 成功（`ok: true`）/ 1 = 失敗・確定できない（`ok: false`。`error` に理由、`problems` に検査の指摘）/
2 = 引数の誤り。どの終了コードでも、標準出力には JSON を 1 つ出す。外の依存は無い（標準ライブラリだけ）。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_prepare import (  # noqa: E402
    DRAFT_FILE,
    RELEASE_VERSION,
    ROOT,
    WHATS_NEW_LIMIT,
    Failure,
    JsonArgumentParser,
    UsageError,
    emit,
    language_codes,
    remote_refs,
    version_key,
)

METADATA_DIR = "AppStore/metadata"

#: upload_metadata.py が App Store Connect への書き込みを止める、テンプレートの仮の文言
PLACEHOLDER = "TODO:"


class InvalidWhatsNew(Failure):
    """`whats_new` の検査で見つかった問題（すべてを `problems` に並べる）。"""

    def __init__(self, problems: list[str]):
        super().__init__(f"whats_new に問題があります（{len(problems)} 件）: {' / '.join(problems)}")
        self.problems = problems


# MARK: check


def initial_warning(version: str) -> str:
    return (
        f"前の v* タグが無い初めてのリリース（{version}）です。App Store Connect は最初のバージョンに最新情報（whatsNew）を持たないので、"
        "Metadata/App Store は最初のバージョンには whatsNew を書き込みません（JSON には確定した本文を残し、GitHub Release の本文に使います）。"
    )


def check_release(version: str, release_branches: list[str], tags: list[str]) -> dict:
    """確定してよいか。release_branches は `release/` を除いた名前、tags は `v` を含むタグ名。"""
    branch, tag = f"release/{version}", f"v{version}"
    if tag in tags:
        raise Failure(f"タグ {tag} がすでにあります（{version} はリリース済みです）。リリースした後の最新情報は確定し直せません。")
    if version not in release_branches:
        raise Failure(f"{branch} がありません。先にリリース準備（Release/Prepare）で release ブランチを作ってください。")
    released = [key for key in (version_key(name[1:]) for name in tags if name.startswith("v")) if key]
    result = {"ok": True, "version": version, "branch": branch, "tag": tag, "initial": not released,
              "messages": [f"{branch} があり、{tag} のタグはまだありません。"], "warnings": []}
    if not released:
        result["warnings"].append(initial_warning(version))
    return result


def command_check(args: argparse.Namespace) -> dict:
    branches, tags = remote_refs(Path(args.root), args.remote)
    return check_release(args.version, branches, tags)


# MARK: apply


def _reject_duplicates(pairs: list[tuple[str, object]]) -> dict:
    keys = [key for key, _ in pairs]
    duplicated = sorted({key for key in keys if keys.count(key) > 1})
    if duplicated:
        raise InvalidWhatsNew([f"同じ言語が 2 回以上あります: {', '.join(duplicated)}"])
    return dict(pairs)


def parse_whats_new(raw: str, languages: list[str], limit: int = WHATS_NEW_LIMIT) -> dict[str, str]:
    """`whats_new` の JSON を検査し、言語 → 前後の空白を外した本文を `languages` の順で返す。"""
    try:
        value = json.loads(raw, object_pairs_hook=_reject_duplicates)
    except json.JSONDecodeError as error:
        raise InvalidWhatsNew([f"JSON として読めません（{error.lineno} 行 {error.colno} 列: {error.msg}）"]) from None
    if not isinstance(value, dict):
        raise InvalidWhatsNew(['言語コード → 本文の JSON のオブジェクト（例: {"ja": "…"}）にしてください'])

    problems = []
    unknown = [key for key in value if key not in languages]
    if unknown:
        problems.append(f"AppStore/languages.json に無い言語があります: {', '.join(unknown)}（使える言語: {', '.join(languages)}）")
    missing = [language for language in languages if language not in value]
    if missing:
        problems.append(f"本文の無い言語があります: {', '.join(missing)}（AppStore/languages.json のすべての言語を書いてください）")

    texts: dict[str, str] = {}
    for language in languages:
        if language not in value:
            continue
        text = value[language]
        if not isinstance(text, str):
            problems.append(f"{language}: 本文は文字列にしてください")
            continue
        text = text.strip()
        if not text:
            problems.append(f"{language}: 本文が空です")
        elif len(text) > limit:
            problems.append(f"{language}: 本文が {len(text)} 字あります（上限 {limit} 字）")
        elif PLACEHOLDER in text:
            problems.append(f"{language}: テンプレートの仮の文言（{PLACEHOLDER}）が残っています")
        else:
            texts[language] = text
    if problems:
        raise InvalidWhatsNew(problems)
    return texts


def dump_json(value: dict) -> str:
    """AppStore/ の JSON と同じ書式（2 字の字下げ・日本語はそのまま・末尾に改行）。"""
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def apply_notes(root: Path, version: str, raw_whats_new: str) -> dict:
    """検査してから、言語ごとの whatsNew を書き、下書きを消す。問題があれば何も書かない。"""
    languages = language_codes(root)
    texts = parse_whats_new(raw_whats_new, languages)

    # 書く前に、すべての言語のファイルを読めることを確かめる（一部の言語だけを書き換えて止まらない）
    planned: list[tuple[str, Path, str, str]] = []
    for language in languages:
        path = root / METADATA_DIR / f"{language}.json"
        if not path.is_file():
            raise Failure(f"{METADATA_DIR}/{language}.json がありません（AppStore/languages.json の言語ごとに必要です）。")
        current = path.read_text(encoding="utf-8")
        try:
            metadata = json.loads(current)
        except json.JSONDecodeError as error:
            raise Failure(f"{METADATA_DIR}/{language}.json が JSON として読めません（{error}）。") from None
        if not isinstance(metadata, dict):
            raise Failure(f"{METADATA_DIR}/{language}.json がオブジェクトではありません。")
        # 既存のキーの順は保つ（whatsNew が無ければ末尾に足す）
        metadata["whatsNew"] = {"version": version, "text": texts[language]}
        planned.append((language, path, current, dump_json(metadata)))

    results = []
    for language, path, current, updated in planned:
        if updated != current:
            path.write_text(updated, encoding="utf-8")
        results.append({"language": language, "length": len(texts[language]), "changed": updated != current})

    draft = root / DRAFT_FILE
    draft_removed = draft.is_file()
    if draft_removed:
        draft.unlink()

    changed = draft_removed or any(result["changed"] for result in results)
    messages = [f"{METADATA_DIR}/{result['language']}.json の whatsNew を {version} の本文（{result['length']} 字）"
                f"{'にしました' if result['changed'] else 'のまま変えていません（同じ内容）'}。" for result in results]
    messages.append(f"下書き {DRAFT_FILE} を消しました。" if draft_removed else f"下書き {DRAFT_FILE} はもうありません。")
    return {"ok": True, "version": version, "languages": results, "draftRemoved": draft_removed,
            "changed": changed, "messages": messages}


def command_apply(args: argparse.Namespace) -> dict:
    raw = os.environ.get(args.whats_new_env)
    if raw is None:
        raise Failure(f"環境変数 {args.whats_new_env} に whats_new の JSON を入れてください。")
    return apply_notes(Path(args.root), args.version, raw)


# MARK: 入口


def build_parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(ROOT), help="リポジトリのルート（既定はこのファイルの 1 つ上）")
    commands = parser.add_subparsers(dest="command", required=True, parser_class=JsonArgumentParser)

    check = commands.add_parser("check", help="確定してよい release ブランチかを確かめる")
    check.add_argument("--version", required=True)
    check.add_argument("--remote", default="origin")

    apply = commands.add_parser("apply", help="whatsNew を書き、下書きを消す")
    apply.add_argument("--version", required=True)
    apply.add_argument("--whats-new-env", default="WHATS_NEW",
                       help="whats_new の JSON を入れた環境変数の名前（既定 WHATS_NEW。シェルの引数に本文を載せないため）")
    return parser


COMMANDS = {"check": command_check, "apply": command_apply}


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except UsageError as error:
        emit({"ok": False, "error": f"引数の誤り: {error}"})
        parser.print_usage(sys.stderr)
        return 2
    failure = {"command": args.command, "ok": False, "version": args.version}
    if not RELEASE_VERSION.match(args.version):
        emit({**failure, "error": f"バージョンは MAJOR.MINOR.PATCH の形で指定してください（{args.version}）"})
        return 2
    try:
        result = COMMANDS[args.command](args)
    except InvalidWhatsNew as error:
        emit({**failure, "error": str(error), "problems": error.problems})
        return 1
    except Failure as error:
        emit({**failure, "error": str(error)})
        return 1
    except Exception as error:  # noqa: BLE001  JSON を出さずに落ちない
        traceback.print_exc(file=sys.stderr)
        emit({**failure, "error": f"{type(error).__name__}: {error}"})
        return 1
    emit({"command": args.command, **result})
    return 0


if __name__ == "__main__":
    sys.exit(main())

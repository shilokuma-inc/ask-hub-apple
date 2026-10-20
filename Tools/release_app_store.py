#!/usr/bin/env python3
"""リリースのワークフローから呼ぶ、App Store Connect のバージョンとビルドの操作（Discussion #605 の Q4・Q7）。

結果は JSON で標準出力に出す（ワークフローは jq で読む）。人に向けた説明は標準エラーにも出す。

    python3 Tools/release_app_store.py prepare --version 1.1.0       # バージョンを用意する（無ければ作る）
    python3 Tools/release_app_store.py attach-build --version 1.1.0  # 処理が終わった最新のビルドを紐付ける
    python3 Tools/release_app_store.py status --version 1.1.0        # 状態を見て、配信済みかを判定する

`--platforms`（既定 `IOS,MAC_OS`）で対象を選ぶ。App Store Connect のアプリに macOS のプラットフォームが
無いとき（バージョンが 1 つも無いとき）は、そのプラットフォームを `platform-missing` として飛ばし、
iOS だけで続ける（プラットフォームの追加は Web でしかできない）。`--optional-platforms`（既定 `MAC_OS`）
に無いプラットフォームが無いときは失敗にする。

`--dry-run` を付けると読むだけで、何も作らない・書き換えない（結果の status は、実行したらどうなるか）。

終了コード: 0 = 成功（`ok: true`）/ 1 = 失敗（`ok: false`。`error` に理由）/
2 = 引数の誤り（バージョンの形の誤りを含む。`ok: false`。App Store Connect は呼ばない）。
どの終了コードでも、標準出力には JSON を 1 つ出す（ワークフローは終了コードを見ずに `ok` で判定してよい）。
1 つのプラットフォームで API が失敗しても（409 など）、ほかのプラットフォームは続けて結果に残す
（失敗したプラットフォームは `status: "error"`。`httpStatus` に HTTP のステータスコード）。

ビルドは `versionString` とプラットフォームだけで選ぶ。`develop` の `MARKETING_VERSION` がリリースと同じだと、
`develop` から上がったビルドを紐付けうるので、リリース準備（release-prepare.yml）は `develop` の `MARKETING_VERSION`
より大きいバージョンでしか始めない。前の `v*` タグが無い初回だけは同じ値も許し、Job Summary で注意を出す
（docs/release.md の「リリース準備」の「バージョンの決まり」）。

認証は upload_metadata.py と同じ（`--key-id` / `--issuer-id` / `--private-key`、または環境変数
APP_STORE_CONNECT_KEY_ID / APP_STORE_CONNECT_ISSUER_ID / APP_STORE_CONNECT_PRIVATE_KEY_PATH）。
PyJWT が要る: `python3 -m pip install pyjwt cryptography`
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_store_connect import (  # noqa: E402
    PLATFORM_IOS,
    PLATFORM_MAC_OS,
    PLATFORM_NAMES,
    ApiError,
    AppStoreConnect,
    is_editable,
    is_released,
    version_state,
)

#: リリースのバージョンの形（ゴールの「既定の設計」: MAJOR.MINOR.PATCH）
RELEASE_VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")

#: App Store Connect にある既存のバージョンの形（自動で作られる `1.0` のように 2 つのこともある）
EXISTING_VERSION = re.compile(r"^[0-9]+(\.[0-9]+){0,2}$")

DEFAULT_PLATFORMS = f"{PLATFORM_IOS},{PLATFORM_MAC_OS}"
DEFAULT_OPTIONAL_PLATFORMS = PLATFORM_MAC_OS


class Blocked(Exception):
    """人の判断・作業が要るので、それ以上進めない。"""


class UsageError(Exception):
    """引数の誤り（終了コード 2）。"""


#: 引数の誤りの終了コード（argparse と同じ）
EXIT_USAGE = 2


def version_key(version_string: str) -> tuple[int, int, int] | None:
    """比べるための (MAJOR, MINOR, PATCH)。`1.0` は `1.0.0` とみなす。形が違えば None。"""
    if not EXISTING_VERSION.match(version_string):
        return None
    parts = [int(part) for part in version_string.split(".")]
    while len(parts) < 3:
        parts.append(0)
    return parts[0], parts[1], parts[2]


def platform_name(platform: str) -> str:
    return PLATFORM_NAMES.get(platform, platform)


def describe_version(version: dict) -> dict:
    attributes = version.get("attributes", {})
    return {
        "versionId": version.get("id"),
        "versionString": attributes.get("versionString"),
        "appStoreState": attributes.get("appStoreState"),
        "appVersionState": attributes.get("appVersionState"),
        "state": version_state(attributes),
        "editable": is_editable(attributes),
        "released": is_released(attributes),
    }


def describe_build(build: dict) -> dict:
    attributes = build.get("attributes", {})
    return {
        "id": build.get("id"),
        "buildNumber": attributes.get("version"),
        "uploadedDate": attributes.get("uploadedDate"),
    }


def platform_missing(platform: str) -> dict:
    name = platform_name(platform)
    return {
        "status": "platform-missing",
        "message": (
            f"App Store Connect のアプリに {name} のプラットフォームがありません（{name} のバージョンが 1 つもありません）。"
            f"App Store Connect の Web でプラットフォームを追加すると、次の実行から {name} も扱います"
            "（docs/release.md の「macOS 版のアップロード」）。"
        ),
    }


# MARK: サブコマンド


def prepare_platform(client: AppStoreConnect, app_id: str, version_string: str, platform: str,
                     other_editable: str) -> dict:
    """そのプラットフォームに `version_string` のバージョンを用意する。"""
    name = platform_name(platform)
    versions = client.app_store_versions(app_id, platform)
    if not versions:
        return platform_missing(platform)

    for version in versions:
        if version["attributes"]["versionString"] == version_string:
            result = {"status": "exists", **describe_version(version)}
            result["message"] = f"{name} のバージョン {version_string} はすでにあります（{result['state']}）。"
            return result

    editable = [v for v in versions if is_editable(v["attributes"])]
    if len(editable) > 1:
        names = ", ".join(v["attributes"]["versionString"] for v in editable)
        raise Blocked(f"{name} に編集できるバージョンが複数あります（{names}）。App Store Connect で 1 つにしてください。")

    if editable:
        # 編集できるバージョンはプラットフォームごとに 1 つしか持てないので、新しくは作れない。
        # 前のリリースの準備の残りや、プラットフォームの追加で自動で作られた 1.0 などが残っている
        current = editable[0]
        current_string = current["attributes"]["versionString"]
        current_key = version_key(current_string)
        target_key = version_key(version_string)
        if other_editable == "fail":
            raise Blocked(
                f"{name} に編集できるバージョン {current_string} が残っています（--other-editable fail）。"
                f"App Store Connect で {version_string} に書き換えるか、消してから再実行してください。"
            )
        if current_key is None or target_key is None or current_key > target_key:
            raise Blocked(
                f"{name} に編集できるバージョン {current_string} が残っていて、{version_string} より新しいか形が違うため書き換えません。"
                "App Store Connect で確かめてから再実行してください。"
            )
        updated = client.update_version_string(current["id"], version_string)
        merged = {**current, "attributes": {**current["attributes"], **updated.get("attributes", {})}}
        result = {"status": "renamed", **describe_version(merged), "previousVersionString": current_string}
        result["message"] = (
            f"{name} の編集できるバージョン {current_string} を {version_string} に書き換えました"
            "（入力済みの説明文・スクリーンショットはそのまま残ります）。"
        )
        return result

    created = client.create_version(app_id, version_string, platform)
    result = {"status": "created", **describe_version(created)}
    result["message"] = f"{name} のバージョン {version_string} を作りました。"
    return result


def attach_build_platform(client: AppStoreConnect, app_id: str, version_string: str,
                          platform: str) -> dict:
    """処理が終わった最新のビルドを、そのプラットフォームのバージョンに紐付ける。"""
    name = platform_name(platform)
    versions = client.app_store_versions(app_id, platform)
    if not versions:
        return platform_missing(platform)
    version = next((v for v in versions if v["attributes"]["versionString"] == version_string), None)
    if version is None:
        return {
            "status": "version-missing",
            "message": f"{name} にバージョン {version_string} がありません（prepare を先に実行します）。",
        }

    result = describe_version(version)
    attached = client.attached_build_id(version["id"])
    builds = client.valid_builds(app_id, version_string, platform)
    result["attachedBuildId"] = attached
    if not builds:
        result.update(status="waiting-for-build",
                      message=f"{name} の {version_string} の処理が終わったビルドはまだありません。")
        return result

    latest = builds[0]
    result["build"] = describe_build(latest)
    if attached == latest["id"]:
        result.update(status="already-attached",
                      message=f"{name} の {version_string} には最新のビルド {result['build']['buildNumber']} が紐付いています。")
        return result
    if not result["editable"]:
        # 審査中・配信済みなどはビルドを差し替えられない（人が提出した後は触らない）
        result.update(status="locked",
                      message=f"{name} の {version_string} は {result['state']} のため、ビルドを紐付けません。")
        return result

    client.attach_build(version["id"], latest["id"])
    result.update(status="attached", previousBuildId=attached, attachedBuildId=latest["id"],
                  message=f"{name} の {version_string} にビルド {result['build']['buildNumber']} を紐付けました。")
    return result


def status_platform(client: AppStoreConnect, app_id: str, version_string: str, platform: str) -> dict:
    name = platform_name(platform)
    versions = client.app_store_versions(app_id, platform)
    if not versions:
        return platform_missing(platform)
    version = next((v for v in versions if v["attributes"]["versionString"] == version_string), None)
    if version is None:
        return {
            "status": "version-missing",
            "message": f"{name} にバージョン {version_string} がありません（配信の判定には含めません）。",
        }
    result = describe_version(version)
    result["attachedBuildId"] = client.attached_build_id(version["id"])
    if result["released"]:
        result.update(status="released", message=f"{name} の {version_string} は配信済みです（{result['state']}）。")
    else:
        result.update(status="not-released", message=f"{name} の {version_string} はまだ配信されていません（{result['state']}）。")
    return result


#: サブコマンド → プラットフォームごとの処理（client, app_id, version_string, platform, other_editable）
COMMANDS = {
    "prepare": prepare_platform,
    "attach-build": lambda client, app_id, version_string, platform, _: attach_build_platform(
        client, app_id, version_string, platform),
    "status": lambda client, app_id, version_string, platform, _: status_platform(
        client, app_id, version_string, platform),
}


def run(client: AppStoreConnect, command: str, bundle: str, version_string: str,
        platforms: list[str], optional_platforms: set[str], other_editable: str = "rename") -> dict:
    """サブコマンドを実行し、標準出力に出す JSON の中身を返す。"""
    result: dict = {
        "command": command,
        "ok": True,
        "version": version_string,
        "bundleId": bundle,
        "dryRun": client.dry_run,
        "platforms": {},
        "messages": [],
    }
    app = client.find_app(bundle)
    result["appId"] = app["id"]

    failures: list[str] = []
    for platform in platforms:
        try:
            entry = COMMANDS[command](client, app["id"], version_string, platform, other_editable)
        except Blocked as blocked:
            entry = {"status": "blocked", "message": str(blocked)}
            failures.append(entry["message"])
        except ApiError as error:
            # 1 つのプラットフォームの失敗（macOS の 409 など）で、ほかのプラットフォームの結果を消さない
            entry = {"status": "error", "message": f"{platform_name(platform)}: {error}",
                     "httpStatus": error.status}
            failures.append(entry["message"])
        if entry["status"] == "platform-missing" and platform not in optional_platforms:
            entry["message"] += f" {platform_name(platform)} は必須のため止めます。"
            failures.append(entry["message"])
        result["platforms"][platform] = entry
        result["messages"].append(entry["message"])

    if command == "status":
        # 作ったプラットフォーム（バージョンがあるもの）すべてで配信済みなら、リリース後作業を始めてよい
        statuses = [entry["status"] for entry in result["platforms"].values()]
        considered = [s for s in statuses if s in ("released", "not-released")]
        # 状態を読めなかったプラットフォームがあるときは、配信済みと判定しない（次の実行で読み直す）
        unknown = any(s in ("error", "blocked") for s in statuses)
        result["released"] = not unknown and bool(considered) and all(s == "released" for s in considered)

    if failures:
        result["ok"] = False
        result["error"] = " / ".join(failures)
    return result


def parse_platforms(raw: str) -> list[str]:
    platforms = [item.strip().upper() for item in raw.split(",") if item.strip()]
    unknown = [item for item in platforms if item not in PLATFORM_NAMES]
    if unknown or not platforms:
        raise argparse.ArgumentTypeError(
            f"プラットフォームは {', '.join(PLATFORM_NAMES)} から選んでください（{raw}）"
        )
    return list(dict.fromkeys(platforms))


class JsonArgumentParser(argparse.ArgumentParser):
    """引数の誤りでも、標準出力の JSON をそろえるため、終了せずに UsageError を投げる。"""

    def error(self, message: str):  # type: ignore[override]
        raise UsageError(message)


def build_parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=sorted(COMMANDS))
    parser.add_argument("--version", required=True, dest="version_string",
                        help="リリースのバージョン（MAJOR.MINOR.PATCH）")
    parser.add_argument("--platforms", type=parse_platforms, default=parse_platforms(DEFAULT_PLATFORMS),
                        help=f"対象のプラットフォーム（カンマ区切り。既定 {DEFAULT_PLATFORMS}）")
    parser.add_argument("--optional-platforms", type=parse_platforms,
                        default=parse_platforms(DEFAULT_OPTIONAL_PLATFORMS),
                        help="App Store Connect に無くても失敗にしないプラットフォーム"
                             f"（既定 {DEFAULT_OPTIONAL_PLATFORMS}）")
    parser.add_argument("--other-editable", choices=("rename", "fail"), default="rename",
                        help="prepare で、別の versionString の編集できるバージョンが残っているときの扱い。"
                             "rename: リリースのバージョンより古ければ書き換える（既定） / fail: 止める")
    parser.add_argument("--bundle-id", help="省略すると Configs/Project.xcconfig から読む")
    parser.add_argument("--key-id", default=os.environ.get("APP_STORE_CONNECT_KEY_ID"))
    parser.add_argument("--issuer-id", default=os.environ.get("APP_STORE_CONNECT_ISSUER_ID"))
    parser.add_argument("--private-key", type=Path, default=os.environ.get("APP_STORE_CONNECT_PRIVATE_KEY_PATH"),
                        help="App Store Connect API Key の .p8")
    parser.add_argument("--dry-run", action="store_true", help="読むだけで、何も作らない・書き換えない")
    return parser


def emit(result: dict) -> None:
    for message in result.get("messages", []):
        print(message, file=sys.stderr)
    if result.get("error"):
        print(f"失敗: {result['error']}", file=sys.stderr)
    print(json.dumps(result, ensure_ascii=False, indent=2))


def main(argv: list[str] | None = None, client: AppStoreConnect | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except UsageError as error:
        emit({"command": None, "ok": False, "version": None, "platforms": {}, "messages": [],
              "error": f"引数の誤り: {error}"})
        parser.print_usage(sys.stderr)
        return EXIT_USAGE
    failure = {"command": args.command, "ok": False, "version": args.version_string,
               "platforms": {}, "messages": []}

    if not RELEASE_VERSION.match(args.version_string):
        emit({**failure, "error": f"バージョンは MAJOR.MINOR.PATCH の形で指定してください（{args.version_string}）"})
        return EXIT_USAGE

    try:
        if args.bundle_id:
            bundle = args.bundle_id
        else:
            from app_store_config import bundle_id
            bundle = bundle_id()
        if client is None:
            missing = [name for name, value in
                       [("--key-id", args.key_id), ("--issuer-id", args.issuer_id),
                        ("--private-key", args.private_key)] if not value]
            if missing:
                raise SystemExit(f"認証情報が足りません: {', '.join(missing)}")
            client = AppStoreConnect(args.key_id, args.issuer_id, Path(args.private_key).read_text(),
                                     dry_run=args.dry_run)
        result = run(client, args.command, bundle, args.version_string, args.platforms,
                     set(args.optional_platforms), args.other_editable)
    except ApiError as error:
        emit({**failure, "error": str(error), "httpStatus": error.status})
        return 1
    except SystemExit as error:  # find_app などが SystemExit(メッセージ) で止まる
        if isinstance(error.code, int) or error.code is None:
            raise
        emit({**failure, "error": str(error.code)})
        return 1
    except OSError as error:  # .p8 が無い・読めないなど
        emit({**failure, "error": f"ファイルを読めません: {error}"})
        return 1
    except Exception as error:  # noqa: BLE001  鍵の形の誤り（PyJWT）など。JSON を出さずに落ちない
        traceback.print_exc(file=sys.stderr)
        emit({**failure, "error": f"{type(error).__name__}: {error}"})
        return 1

    emit(result)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())

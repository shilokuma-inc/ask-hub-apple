#!/usr/bin/env python3
"""App Store Connect のプラットフォーム（iOS / macOS）ごとの反映先のバージョンを決める共通処理。

メタデータ（`upload_metadata.py`）とスクリーンショット（`upload_screenshots.py`）の両方から使う。
App Store Connect のバージョンはプラットフォームごとに別にあり（同じ `versionString` でも iOS と macOS で 2 つ）、
macOS のプラットフォームをアプリに追加するまでは macOS のバージョンが 1 つも無い（追加は Web でしかできない）。
macOS のバージョンが無いあいだも iOS の反映は止めたくないので、「反映先が無い」ことを止めずに見分けられるようにする。
"""

from __future__ import annotations

import sys

#: App Store Connect の platform の値 → 表示名
PLATFORMS = {"IOS": "iOS", "MAC_OS": "macOS"}

#: 配信を終えて、もう反映先にならない状態（配信済みは `app_store_connect.is_released` で見る）。
#: これ以外の編集できない状態（審査中・公開待ちなど）は人が直すことなので、飛ばさずに止める
FINISHED_STATES = {"REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"}

#: 反映先が無くて飛ばしたときに出す文言。ワークフローはこの文言でログを探し、Job Summary に知らせる
SKIPPED_MARKER = "の反映を飛ばしました"


#: 飛ばした理由（missing_version_reason）を見分ける文言。skipped_hint が理由ごとに人がすることを選ぶのに使う
PLATFORM_NOT_ADDED = "のプラットフォームを追加していない"
VERSION_NOT_FOUND = "にバージョン"
NO_EDITABLE_VERSION = "編集できる状態のバージョンがありません"


def platform_label(platform: str) -> str:
    if platform not in PLATFORMS:
        raise SystemExit(f"platform は {' / '.join(PLATFORMS)} のどれかにしてください: {platform}")
    return PLATFORMS[platform]


def missing_version_reason(client, app_id: str, version_string: str | None, platform: str) -> str | None:
    """反映先の候補になるバージョンが無ければ、その理由を返す（あれば None）。

    `AppStoreConnect.find_version` が「見つからない」で止まる場合だけを拾う。
    見つかったが審査中などで編集できない・候補が複数あるといった、人が直すべき場合は None を返し、
    `find_version` にそのまま止めさせる。バージョンを指定しないときに飛ばすのは、
    どのバージョンも配信を終えた（`FINISHED_STATES`）ときだけにする（審査中・公開待ちがあれば止める）。
    """
    from app_store_connect import is_editable, is_released, version_state

    label = platform_label(platform)
    versions = client.get_all(
        f"/v1/apps/{app_id}/appStoreVersions",
        {"filter[platform]": platform, "limit": 50},
    )
    if not versions:
        return (f"App Store Connect のアプリに {label} のバージョンがありません"
                f"（{label} {PLATFORM_NOT_ADDED}）")
    if version_string:
        if any(v["attributes"]["versionString"] == version_string for v in versions):
            return None
        return f"{label} {VERSION_NOT_FOUND} {version_string} がありません"
    if any(is_editable(v["attributes"]) for v in versions):
        return None
    if not all(is_released(v["attributes"]) or version_state(v["attributes"]) in FINISHED_STATES
               for v in versions):
        return None
    states = ", ".join(sorted({version_state(v["attributes"]) for v in versions}))
    return f"{label} に{NO_EDITABLE_VERSION}（いまある状態: {states}）"


def is_first_version(client, app_id: str, version: dict, platform: str) -> bool:
    """`version` がそのプラットフォームの最初のバージョン（ほかに配信した・配信を終えたバージョンが無い）か。

    App Store Connect は最初のバージョンに最新情報（`whatsNew`）の欄を持たない（Web の画面にも出ない）。
    最初のバージョンに `whatsNew` を送ると、同じ言語の説明文などの書き込みごと弾かれうるので、`upload_metadata.py` は
    最初のバージョンには `whatsNew` を送らない。iOS と macOS は別に数える（macOS を後から足すと、macOS の最初のバージョンになる）。
    """
    from app_store_connect import is_released, version_state

    platform_label(platform)
    versions = client.get_all(
        f"/v1/apps/{app_id}/appStoreVersions",
        {"filter[platform]": platform, "limit": 50},
    )
    return not any(
        is_released(other["attributes"]) or version_state(other["attributes"]) in FINISHED_STATES
        for other in versions if other.get("id") != version.get("id")
    )


def skipped_message(platform: str, reason: str) -> str:
    return f"{platform_label(platform)} {SKIPPED_MARKER}: {reason}"


def skipped_hint(message: str) -> str:
    """飛ばしたときのログの行（skipped_message）から、反映するために人がすることを返す（Job Summary に載せる）。

    理由によってすることが違う（プラットフォームの追加・そのバージョンの作成・新しいバージョンの作成）ので、
    理由によらず「プラットフォームを追加して」と案内しない。
    """
    if PLATFORM_NOT_ADDED in message:
        return ("App Store Connect でアプリに macOS のプラットフォームを追加し、macOS のバージョン（iOS と同じバージョン番号）を"
                "用意してから再実行してください（docs/release.md の「macOS 版のアップロード」）。")
    if NO_EDITABLE_VERSION in message:
        return ("macOS には配信を終えたバージョンしかありません。App Store Connect で macOS の新しいバージョン"
                "（iOS と同じバージョン番号）を作ってから再実行してください。")
    if VERSION_NOT_FOUND in message:
        return ("指定したバージョン番号の macOS のバージョンがありません。App Store Connect で同じ番号の macOS のバージョンを作るか、"
                "app_version を見直してから再実行してください。")
    return "理由を確かめ、App Store Connect の macOS のバージョンを用意してから再実行してください。"


def main(argv: list[str]) -> int:
    """ワークフローから使う。`hint <ログの行>` で、飛ばした理由に合う「人がすること」を 1 行で出す。"""
    if len(argv) != 2 or argv[0] != "hint":
        print("使い方: python3 Tools/app_store_platform.py hint '<macOS の反映を飛ばしました: … の行>'", file=sys.stderr)
        return 2
    print(skipped_hint(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

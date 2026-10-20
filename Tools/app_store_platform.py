#!/usr/bin/env python3
"""App Store Connect のプラットフォーム（iOS / macOS）ごとの反映先のバージョンを決める共通処理。

メタデータ（`upload_metadata.py`）とスクリーンショット（`upload_screenshots.py`）の両方から使う。
App Store Connect のバージョンはプラットフォームごとに別にあり（同じ `versionString` でも iOS と macOS で 2 つ）、
macOS のプラットフォームをアプリに追加するまでは macOS のバージョンが 1 つも無い（追加は Web でしかできない）。
macOS のバージョンが無いあいだも iOS の反映は止めたくないので、「反映先が無い」ことを止めずに見分けられるようにする。
"""

from __future__ import annotations

#: App Store Connect の platform の値 → 表示名
PLATFORMS = {"IOS": "iOS", "MAC_OS": "macOS"}

#: 配信を終えて、もう反映先にならない状態（配信済みは `app_store_connect.is_released` で見る）。
#: これ以外の編集できない状態（審査中・公開待ちなど）は人が直すことなので、飛ばさずに止める
FINISHED_STATES = {"REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"}

#: 反映先が無くて飛ばしたときに出す文言。ワークフローはこの文言でログを探し、Job Summary に知らせる
SKIPPED_MARKER = "の反映を飛ばしました"


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
                f"（{label} のプラットフォームを追加していない）")
    if version_string:
        if any(v["attributes"]["versionString"] == version_string for v in versions):
            return None
        return f"{label} にバージョン {version_string} がありません"
    if any(is_editable(v["attributes"]) for v in versions):
        return None
    if not all(is_released(v["attributes"]) or version_state(v["attributes"]) in FINISHED_STATES
               for v in versions):
        return None
    states = ", ".join(sorted({version_state(v["attributes"]) for v in versions}))
    return f"{label} に編集できる状態のバージョンがありません（いまある状態: {states}）"


def skipped_message(platform: str, reason: str) -> str:
    return f"{platform_label(platform)} {SKIPPED_MARKER}: {reason}"

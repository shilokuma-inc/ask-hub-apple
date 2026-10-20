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
    `find_version` にそのまま止めさせる。
    """
    from app_store_connect import EDITABLE_STATES

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
    if any(v["attributes"]["appStoreState"] in EDITABLE_STATES for v in versions):
        return None
    states = ", ".join(sorted({v["attributes"]["appStoreState"] for v in versions}))
    return f"{label} に編集できる状態のバージョンがありません（いまある状態: {states}）"


def skipped_message(platform: str, reason: str) -> str:
    return f"{platform_label(platform)} {SKIPPED_MARKER}: {reason}"

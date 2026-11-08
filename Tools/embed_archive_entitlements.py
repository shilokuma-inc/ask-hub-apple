#!/usr/bin/env python3
"""署名せずに作った archive の .app に、プロジェクトの entitlements をアドホック署名で埋め込む（`_archive.yml` の iOS）。

Export した IPA に、その entitlements が残ったかも確かめる（`check`）。

iOS は `CODE_SIGNING_ALLOWED=NO` でアーカイブする（アドホック署名のビルドは、push の entitlement（`aps-environment`）が
provisioning profile を要するため「requires a provisioning profile」で止まる）。ところが Export は、archive の実行ファイルの
署名にある entitlement だけを引き継いで配布用に署名し直し、profile からは足さない。署名の無い archive のままでは、
TestFlight の版に `aps-environment` が入らず、通知の登録（`registerForRemoteNotifications`）が失敗する。

そこで archive の後に、ビルドの設定（`xcodebuild -showBuildSettings`）で `$(VAR)` を展開した `CODE_SIGN_ENTITLEMENTS` で
.app をアドホック署名する。値は Export が配布用の profile に合わせて書き換える（App Store なら production）。
.app の中に署名の要るもの（App Extension・Framework）を足したら、それぞれを先に署名する必要がある（codesign が止まって分かる）。

    python3 Tools/embed_archive_entitlements.py embed build.xcarchive \\
        --project AskHub.xcodeproj --scheme AskHub --sdk iphoneos --configuration Release
    python3 Tools/embed_archive_entitlements.py check build.xcarchive export/AskHub.ipa   # Export の後
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

#: entitlements の値の中の `$(NAME)` / `${NAME}`（Xcode がビルドの設定で展開する書き方）
VARIABLE = re.compile(r"\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]")


def expand(value, settings: dict[str, str]):
    """entitlements（plist を読んだもの）の文字列の `$(NAME)` を、ビルドの設定の値に置き換える。

    設定に無い名前があれば止める。Xcode は空にするが、`aps-environment` が空のまま署名されると気づけない。
    """
    if isinstance(value, str):
        missing = sorted({name for name in VARIABLE.findall(value) if name not in settings})
        if missing:
            raise SystemExit(f"entitlements の {', '.join(missing)} がビルドの設定にありません: {value}")
        return VARIABLE.sub(lambda match: settings[match.group(1)], value)
    if isinstance(value, list):
        return [expand(item, settings) for item in value]
    if isinstance(value, dict):
        return {key: expand(item, settings) for key, item in value.items()}
    return value


def app_build_settings(entries: list[dict], product_name: str) -> dict[str, str]:
    """`xcodebuild -showBuildSettings -json` の結果から、archive の .app（`AskHub.app`）を作るターゲットの設定を選ぶ。"""
    matches = [entry["buildSettings"] for entry in entries
               if entry.get("buildSettings", {}).get("FULL_PRODUCT_NAME") == product_name]
    if len(matches) != 1:
        raise SystemExit(f"{product_name} を作るターゲットが 1 つに決まりません（{len(matches)} 件）")
    return matches[0]


def archived_app(archive: Path) -> Path:
    """archive の Info.plist の ApplicationPath（`Applications/AskHub.app`）から .app の場所を返す。"""
    info = plistlib.loads((archive / "Info.plist").read_bytes())
    return archive / "Products" / info["ApplicationProperties"]["ApplicationPath"]


def signed_entitlements(app: Path) -> dict | None:
    """.app の署名にある entitlements。署名が無ければ None。"""
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)],
                            capture_output=True, check=False)
    if result.returncode != 0:
        return None
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def embed(args: argparse.Namespace) -> int:
    app = archived_app(args.archive)
    # 署名済み（macOS のアドホック署名の archive など）を上書きすると、Xcode が埋め込んだ entitlement（sandbox など）が消える
    if signed_entitlements(app) is not None:
        raise SystemExit(f"{app.name} はすでに署名されています。署名の無い archive（CODE_SIGNING_ALLOWED=NO）にだけ使います")

    output = subprocess.run(
        ["xcodebuild", "-showBuildSettings", "-json", "-project", args.project, "-scheme", args.scheme,
         "-sdk", args.sdk, "-configuration", args.configuration],
        capture_output=True, text=True, check=True,
    ).stdout
    settings = app_build_settings(json.loads(output), app.name)
    path = settings.get("CODE_SIGN_ENTITLEMENTS", "")
    if not path:
        print(f"{app.name} の CODE_SIGN_ENTITLEMENTS が空なので、埋め込まずに終わります")
        return 0
    entitlements = expand(plistlib.loads((Path(settings["SRCROOT"]) / path).read_bytes()), settings)

    with tempfile.NamedTemporaryFile(suffix=".entitlements") as file:
        file.write(plistlib.dumps(entitlements))
        file.flush()
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der",
                        "--entitlements", file.name, str(app)], check=True)

    if signed_entitlements(app) != entitlements:
        raise SystemExit(f"{app.name} の署名の entitlements が、埋め込もうとしたものと違います")
    for key, value in sorted(entitlements.items()):
        print(f"{app.name} に埋め込みました: {key} = {value}")
    return 0


def check(args: argparse.Namespace) -> int:
    """Export した IPA の署名に、archive の署名の entitlement がすべて残っているかを確かめる。

    配布用の profile に無い entitlement（App ID の Push Notifications が無効など）を Export が落とすと、
    通知が届かなくなって初めて気づくことになるので、ここで止める。
    """
    archived = signed_entitlements(archived_app(args.archive)) or {}
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(["ditto", "-x", "-k", str(args.ipa), directory], check=True)
        apps = list((Path(directory) / "Payload").glob("*.app"))
        if len(apps) != 1:
            raise SystemExit(f"{args.ipa.name} の Payload に .app が 1 つに決まりません（{len(apps)} 件）")
        exported = signed_entitlements(apps[0]) or {}
    for key, value in sorted(exported.items()):
        print(f"{args.ipa.name}: {key} = {value}")
    missing = sorted(set(archived) - set(exported))
    if missing:
        raise SystemExit(f"{args.ipa.name} に {', '.join(missing)} がありません。"
                         "配布用の profile に入っているか（App ID の capability が有効か）を確かめてください")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="archive の .app に entitlements を埋め込み、Export した IPA に残ったかを確かめる")
    commands = parser.add_subparsers(dest="command", required=True)
    embed_parser = commands.add_parser("embed", help="署名の無い archive の .app に entitlements をアドホック署名で埋め込む")
    embed_parser.add_argument("archive", type=Path, help="xcodebuild archive で作った .xcarchive")
    embed_parser.add_argument("--project", required=True)
    embed_parser.add_argument("--scheme", required=True)
    embed_parser.add_argument("--sdk", required=True)
    embed_parser.add_argument("--configuration", required=True)
    embed_parser.set_defaults(handler=embed)
    check_parser = commands.add_parser("check", help="Export した IPA に archive の entitlements が残ったかを確かめる")
    check_parser.add_argument("archive", type=Path)
    check_parser.add_argument("ipa", type=Path)
    check_parser.set_defaults(handler=check)
    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

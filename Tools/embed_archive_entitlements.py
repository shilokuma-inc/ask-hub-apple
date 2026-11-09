#!/usr/bin/env python3
"""archive の .app に、プロジェクトの entitlements をアドホック署名で埋め込む（`_archive.yml` の iOS と macOS）。

Export した IPA・pkg に、その entitlements が残ったかも確かめる（`check`）。

Export は、archive の実行ファイルの署名にある entitlement だけを引き継いで配布用に署名し直し、profile からは足さない。
ところが push の entitlement（iOS は `aps-environment`、macOS は `com.apple.developer.aps-environment`）は provisioning profile を要し、
アドホック署名のビルドは「requires a provisioning profile」で止まるので、archive のビルドでは付けられない。
そのままでは TestFlight の版に push の entitlement が入らず、通知の登録（`registerForRemoteNotifications`）が失敗する。

- iOS は `CODE_SIGNING_ALLOWED=NO` でアーカイブする。署名の無い .app を、ビルドの設定（`xcodebuild -showBuildSettings`）で
  `$(VAR)` を展開した `CODE_SIGN_ENTITLEMENTS` でアドホック署名する
- macOS はアドホック署名（`CODE_SIGN_STYLE=Manual`）でアーカイブする（署名しないと、`ENABLE_APP_SANDBOX` などから作られる
  entitlement が埋め込まれない）。`CODE_SIGN_ENTITLEMENTS` は自動の署名のときだけ push のファイルになる（`Configs/Project.xcconfig`）ので、
  ここではプロジェクトの既定（Automatic）の設定で読み、archive の署名の entitlement に足して署名し直す

値は Export が配布用の profile に合わせて書き換える（App Store なら production）。
.app の中に署名の要るもの（App Extension・Framework）を足したら、それぞれを先に署名する必要がある（codesign が止まって分かる）。

    python3 Tools/embed_archive_entitlements.py embed build.xcarchive \\
        --project AskHub.xcodeproj --scheme AskHub --sdk iphoneos --configuration Release
    python3 Tools/embed_archive_entitlements.py check build.xcarchive export/AskHub.ipa   # Export の後（macOS は export/AskHub.pkg）
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


def merge(signed: dict, added: dict, app_name: str) -> dict:
    """archive の署名の entitlements に、プロジェクトの entitlements を足す。同じキーで値が違えば止める。"""
    conflicts = sorted(key for key in signed.keys() & added.keys() if signed[key] != added[key])
    if conflicts:
        raise SystemExit(f"{app_name} の署名の {', '.join(conflicts)} が、プロジェクトの entitlements と違います")
    return {**signed, **added}


def embed(args: argparse.Namespace) -> int:
    """archive の .app を、`CODE_SIGN_ENTITLEMENTS` を展開した entitlements でアドホック署名する。

    署名済み（macOS のアドホック署名の archive）なら、その署名の entitlements（sandbox など）に足して署名し直す。
    上書きすると Xcode が埋め込んだ entitlement が消えるため。
    `CODE_SIGN_ENTITLEMENTS` が空なら何もしない。署名の後に、埋め込んだ entitlements と署名の中身が同じかを確かめる。
    """
    app = archived_app(args.archive)
    signed = signed_entitlements(app)

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
    # 署名し直すときは、archive の署名の識別子とフラグ（macOS の Hardened Runtime）を残す
    preserve = [] if signed is None else ["--preserve-metadata=identifier,flags"]
    if signed is not None:
        entitlements = merge(signed, entitlements, app.name)

    with tempfile.NamedTemporaryFile(suffix=".entitlements") as file:
        file.write(plistlib.dumps(entitlements))
        file.flush()
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", *preserve,
                        "--entitlements", file.name, str(app)], check=True)

    if signed_entitlements(app) != entitlements:
        raise SystemExit(f"{app.name} の署名の entitlements が、埋め込もうとしたものと違います")
    for key, value in sorted(entitlements.items()):
        print(f"{app.name} に埋め込みました: {key} = {value}")
    return 0


def packaged_app(package: Path, directory: Path) -> Path:
    """Export した IPA・pkg を directory に展開し、中の .app（入れ子の .app は除く）を返す。"""
    if package.suffix == ".pkg":
        # 展開先は無い場所を指定する（あると pkgutil が止まる）。Payload の中身もファイルに展開される
        expanded = directory / "expanded"
        subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        apps = [app for app in expanded.rglob("*.app") if not any(parent.suffix == ".app" for parent in app.parents)]
    else:
        subprocess.run(["ditto", "-x", "-k", str(package), str(directory)], check=True)
        apps = list((directory / "Payload").glob("*.app"))
    if len(apps) != 1:
        raise SystemExit(f"{package.name} の中に .app が 1 つに決まりません（{len(apps)} 件）")
    return apps[0]


def check(args: argparse.Namespace) -> int:
    """Export した IPA・pkg の署名に、archive の署名の entitlement がすべて残っているかを確かめる。

    配布用の profile に無い entitlement（App ID の Push Notifications が無効など）を Export が落とすと、
    通知が届かなくなって初めて気づくことになるので、ここで止める。
    """
    archived = signed_entitlements(archived_app(args.archive)) or {}
    with tempfile.TemporaryDirectory() as directory:
        exported = signed_entitlements(packaged_app(args.package, Path(directory))) or {}
    for key, value in sorted(exported.items()):
        print(f"{args.package.name}: {key} = {value}")
    missing = sorted(set(archived) - set(exported))
    if missing:
        raise SystemExit(f"{args.package.name} に {', '.join(missing)} がありません。"
                         "配布用の profile に入っているか（App ID の capability が有効か）を確かめてください")
    return 0


def main(argv: list[str]) -> int:
    """`embed` か `check` を流す（使い方はモジュールの説明）。"""
    parser = argparse.ArgumentParser(description="archive の .app に entitlements を埋め込み、Export した IPA・pkg に残ったかを確かめる")
    commands = parser.add_subparsers(dest="command", required=True)
    embed_parser = commands.add_parser("embed", help="archive の .app に entitlements をアドホック署名で埋め込む")
    embed_parser.add_argument("archive", type=Path, help="xcodebuild archive で作った .xcarchive")
    embed_parser.add_argument("--project", required=True)
    embed_parser.add_argument("--scheme", required=True)
    embed_parser.add_argument("--sdk", required=True)
    embed_parser.add_argument("--configuration", required=True)
    embed_parser.set_defaults(handler=embed)
    check_parser = commands.add_parser("check", help="Export した IPA・pkg に archive の entitlements が残ったかを確かめる")
    check_parser.add_argument("archive", type=Path)
    check_parser.add_argument("package", type=Path, help="Export した IPA（iOS）か pkg（macOS）")
    check_parser.set_defaults(handler=check)
    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

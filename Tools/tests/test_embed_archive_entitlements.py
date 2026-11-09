"""Tools/embed_archive_entitlements.py のテスト。

xcodebuild と codesign は、PATH の先頭に置く偽物（シェルスクリプト）に差し替える（ubuntu のランナーでも流れる）。
偽の codesign は、署名に渡された entitlements をファイルに残し、`-d` でそれを返す。
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS))

import embed_archive_entitlements  # noqa: E402

#: codesign の偽物。署名の entitlements を $CODESIGN_STATE に、署名の引数を $CODESIGN_ARGS に残す。無ければ「署名されていない」で失敗する
FAKE_CODESIGN = r"""#!/bin/bash
if [ "$1" = "-d" ]; then
  if [ ! -e "$CODESIGN_STATE" ]; then
    echo "code object is not signed at all" >&2
    exit 1
  fi
  cat "$CODESIGN_STATE"
  exit 0
fi
printf '%s\n' "$@" > "$CODESIGN_ARGS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--entitlements" ]; then cp "$2" "$CODESIGN_STATE"; fi
  shift
done
"""

#: xcodebuild の偽物。-showBuildSettings -json の結果として $BUILD_SETTINGS を出す
FAKE_XCODEBUILD = r"""#!/bin/bash
cat "$BUILD_SETTINGS"
"""

ENTITLEMENTS = {"aps-environment": "$(APS_ENVIRONMENT)"}


def settings_entry(product: str, **settings: str) -> dict:
    return {"target": product, "buildSettings": {"FULL_PRODUCT_NAME": product, **settings}}


class ExpandTests(unittest.TestCase):
    def test_expands_both_forms_in_nested_values(self):
        value = {"a": "$(APS_ENVIRONMENT)", "b": ["${TEAM}.group", "x"], "c": True}
        self.assertEqual(
            embed_archive_entitlements.expand(value, {"APS_ENVIRONMENT": "production", "TEAM": "ABC"}),
            {"a": "production", "b": ["ABC.group", "x"], "c": True},
        )

    def test_missing_setting_stops(self):
        with self.assertRaises(SystemExit) as raised:
            embed_archive_entitlements.expand({"a": "$(APS_ENVIRONMENT)"}, {})
        self.assertIn("APS_ENVIRONMENT", str(raised.exception))


class AppBuildSettingsTests(unittest.TestCase):
    def test_picks_target_that_builds_the_app(self):
        entries = [settings_entry("AskHubTests.xctest"), settings_entry("AskHub.app", APS_ENVIRONMENT="production")]
        self.assertEqual(embed_archive_entitlements.app_build_settings(entries, "AskHub.app")["APS_ENVIRONMENT"],
                         "production")

    def test_no_match_stops(self):
        with self.assertRaises(SystemExit):
            embed_archive_entitlements.app_build_settings([settings_entry("Other.app")], "AskHub.app")


class MainTests(unittest.TestCase):
    def setUp(self):
        """偽の xcodebuild・codesign を PATH の先頭に置き、署名の無い archive と entitlements のファイルを用意する。"""
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, script in (("codesign", FAKE_CODESIGN), ("xcodebuild", FAKE_XCODEBUILD)):
            (bin_dir / name).write_text(script)
            (bin_dir / name).chmod(0o755)

        self.archive = self.tmp / "build.xcarchive"
        (self.archive / "Products/Applications/AskHub.app").mkdir(parents=True)
        (self.archive / "Info.plist").write_bytes(
            plistlib.dumps({"ApplicationProperties": {"ApplicationPath": "Applications/AskHub.app"}}))
        self.source = self.tmp / "src"
        (self.source / "AskHub").mkdir(parents=True)
        (self.source / "AskHub/AskHub-iOS.entitlements").write_bytes(plistlib.dumps(ENTITLEMENTS))

        self.state = self.tmp / "signed.plist"
        self.args = self.tmp / "codesign-args.txt"
        self.settings = self.tmp / "settings.json"
        self.write_settings(CODE_SIGN_ENTITLEMENTS="AskHub/AskHub-iOS.entitlements", APS_ENVIRONMENT="production")
        patcher = mock.patch.dict(os.environ, {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "CODESIGN_STATE": str(self.state),
            "CODESIGN_ARGS": str(self.args),
            "BUILD_SETTINGS": str(self.settings),
        })
        patcher.start()
        self.addCleanup(patcher.stop)

    def write_settings(self, **settings: str):
        self.settings.write_text(json.dumps([settings_entry("AskHub.app", SRCROOT=str(self.source), **settings)]))

    def run_main(self) -> int:
        with contextlib.redirect_stdout(io.StringIO()):
            return embed_archive_entitlements.main([
                "embed", str(self.archive), "--project", "AskHub.xcodeproj", "--scheme", "AskHub",
                "--sdk", "iphoneos", "--configuration", "Release",
            ])

    def signed_arguments(self) -> list[str]:
        return self.args.read_text().splitlines()

    def test_signs_with_expanded_entitlements(self):
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(plistlib.loads(self.state.read_bytes()), {"aps-environment": "production"})
        self.assertFalse(any(argument.startswith("--preserve-metadata") for argument in self.signed_arguments()))

    def test_adds_to_signed_entitlements(self):
        # macOS のアドホック署名の archive。上書きすると Xcode が埋め込んだ entitlement（sandbox など）が消えるので、足して署名し直す
        self.state.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(plistlib.loads(self.state.read_bytes()),
                         {"com.apple.security.app-sandbox": True, "aps-environment": "production"})
        # 署名し直すと Hardened Runtime のフラグが消えるので、archive の署名から残す
        self.assertIn("--preserve-metadata=identifier,flags", self.signed_arguments())

    def test_conflicting_signed_entitlement_stops(self):
        self.state.write_bytes(plistlib.dumps({"aps-environment": "development"}))
        with self.assertRaises(SystemExit) as raised:
            self.run_main()
        self.assertIn("aps-environment", str(raised.exception))
        self.assertEqual(plistlib.loads(self.state.read_bytes()), {"aps-environment": "development"})

    def test_no_entitlements_leaves_app_unsigned(self):
        self.write_settings(CODE_SIGN_ENTITLEMENTS="")
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(self.state.exists())


class CheckTests(unittest.TestCase):
    """Export した IPA・pkg に、archive の署名の entitlement が残ったか。ditto・pkgutil と codesign は差し替える。"""

    def run_check(self, archived: dict | None, exported: dict | None, package: str = "AskHub.ipa",
                  apps: tuple[str, ...] = ("AskHub.app",)) -> int:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        archive = tmp / "build.xcarchive"
        archive.mkdir()
        (archive / "Info.plist").write_bytes(
            plistlib.dumps({"ApplicationProperties": {"ApplicationPath": "Applications/AskHub.app"}}))

        def fake_expand(command, check):
            """IPA・pkg を展開した代わりに、展開先に空の .app を作る（IPA は Payload/、pkg は component の Payload/ の下）。"""
            root = Path(command[-1]) / ("AskHub.pkg/Payload" if command[0] == "pkgutil" else "Payload")
            for app in apps:
                (root / app).mkdir(parents=True)

        def fake_signed_entitlements(app: Path):
            """archive の中の .app には archived を、IPA の .app には exported を返す。"""
            return archived if app.is_relative_to(archive) else exported

        with mock.patch.object(embed_archive_entitlements.subprocess, "run", side_effect=fake_expand), \
                mock.patch.object(embed_archive_entitlements, "signed_entitlements", side_effect=fake_signed_entitlements), \
                contextlib.redirect_stdout(io.StringIO()):
            return embed_archive_entitlements.main(["check", str(archive), str(tmp / package)])

    def test_passes_when_exported_keeps_archived_keys(self):
        # 値は Export が profile に合わせて書き換える（development → production）ので、キーだけを比べる
        exported = {"aps-environment": "production", "application-identifier": "TEAM.jp.shilokuma.AskHub"}
        self.assertEqual(self.run_check({"aps-environment": "development"}, exported), 0)

    def test_stops_when_export_dropped_entitlement(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_check({"aps-environment": "production"}, {"application-identifier": "TEAM.jp.shilokuma.AskHub"})
        self.assertIn("aps-environment", str(raised.exception))

    def test_checks_app_in_pkg(self):
        # macOS の pkg。入れ子の .app（ヘルパーなど）は数えない
        archived = {"com.apple.developer.aps-environment": "production", "com.apple.security.app-sandbox": True}
        apps = ("AskHub.app", "AskHub.app/Contents/Library/Helper.app")
        self.assertEqual(self.run_check(archived, archived, package="AskHub.pkg", apps=apps), 0)
        with self.assertRaises(SystemExit) as raised:
            self.run_check(archived, {"com.apple.security.app-sandbox": True}, package="AskHub.pkg")
        self.assertIn("com.apple.developer.aps-environment", str(raised.exception))

    def test_pkg_without_app_stops(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_check({}, {}, package="AskHub.pkg", apps=())
        self.assertIn("AskHub.pkg", str(raised.exception))


if __name__ == "__main__":
    unittest.main()

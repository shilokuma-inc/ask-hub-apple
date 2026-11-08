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

#: codesign の偽物。署名の entitlements を $CODESIGN_STATE に残す。無ければ「署名されていない」で失敗する
FAKE_CODESIGN = r"""#!/bin/bash
if [ "$1" = "-d" ]; then
  if [ ! -e "$CODESIGN_STATE" ]; then
    echo "code object is not signed at all" >&2
    exit 1
  fi
  cat "$CODESIGN_STATE"
  exit 0
fi
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
        self.settings = self.tmp / "settings.json"
        self.write_settings(CODE_SIGN_ENTITLEMENTS="AskHub/AskHub-iOS.entitlements", APS_ENVIRONMENT="production")
        patcher = mock.patch.dict(os.environ, {
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "CODESIGN_STATE": str(self.state),
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

    def test_signs_with_expanded_entitlements(self):
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(plistlib.loads(self.state.read_bytes()), {"aps-environment": "production"})

    def test_refuses_signed_app(self):
        # macOS のアドホック署名の archive などを上書きすると、Xcode が埋め込んだ entitlement が消える
        self.state.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
        with self.assertRaises(SystemExit):
            self.run_main()
        self.assertEqual(plistlib.loads(self.state.read_bytes()), {"com.apple.security.app-sandbox": True})

    def test_no_entitlements_leaves_app_unsigned(self):
        self.write_settings(CODE_SIGN_ENTITLEMENTS="")
        self.assertEqual(self.run_main(), 0)
        self.assertFalse(self.state.exists())


class CheckTests(unittest.TestCase):
    """Export した IPA に、archive の署名の entitlement が残ったか。ditto と codesign は差し替える。"""

    def run_check(self, archived: dict | None, exported: dict | None) -> int:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        archive = tmp / "build.xcarchive"
        archive.mkdir()
        (archive / "Info.plist").write_bytes(
            plistlib.dumps({"ApplicationProperties": {"ApplicationPath": "Applications/AskHub.app"}}))

        def fake_ditto(command, check):
            (Path(command[-1]) / "Payload/AskHub.app").mkdir(parents=True)

        def fake_signed_entitlements(app: Path):
            return archived if app.is_relative_to(archive) else exported

        with mock.patch.object(embed_archive_entitlements.subprocess, "run", side_effect=fake_ditto), \
                mock.patch.object(embed_archive_entitlements, "signed_entitlements", side_effect=fake_signed_entitlements), \
                contextlib.redirect_stdout(io.StringIO()):
            return embed_archive_entitlements.main(["check", str(archive), str(tmp / "AskHub.ipa")])

    def test_passes_when_exported_keeps_archived_keys(self):
        # 値は Export が profile に合わせて書き換える（development → production）ので、キーだけを比べる
        exported = {"aps-environment": "production", "application-identifier": "TEAM.jp.shilokuma.AskHub"}
        self.assertEqual(self.run_check({"aps-environment": "development"}, exported), 0)

    def test_stops_when_export_dropped_entitlement(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_check({"aps-environment": "production"}, {"application-identifier": "TEAM.jp.shilokuma.AskHub"})
        self.assertIn("aps-environment", str(raised.exception))


if __name__ == "__main__":
    unittest.main()

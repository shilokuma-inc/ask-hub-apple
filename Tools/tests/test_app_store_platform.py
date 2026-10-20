"""メタデータ・スクリーンショットの反映先のプラットフォーム（iOS / macOS）の扱いのテスト。

App Store Connect にはつながない（HTTP は差し替える）。PyJWT も import しない
（`app_store_connect` は PyJWT をトークンを作る関数の中でだけ import する）。

    python3 -m unittest discover -s Tools/tests -t .
"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS))

import app_store_config  # noqa: E402
import app_store_connect  # noqa: E402
import app_store_platform  # noqa: E402
import upload_metadata  # noqa: E402
import upload_screenshots  # noqa: E402


def version(version_string: str, state: str, identifier: str = "v1") -> dict:
    return {"id": identifier, "attributes": {"versionString": version_string, "appStoreState": state}}


class FakeClient:
    """`get_all` だけを持つ App Store Connect の代わり。呼ばれた path と params を残す。"""

    def __init__(self, versions: list[dict]):
        self.versions = versions
        self.calls: list[tuple[str, dict]] = []

    def get_all(self, path: str, params: dict | None = None) -> list[dict]:
        self.calls.append((path, dict(params or {})))
        return self.versions


class FindVersionTests(unittest.TestCase):
    def make_client(self, versions: list[dict]) -> tuple[app_store_connect.AppStoreConnect, list[str]]:
        client = app_store_connect.AppStoreConnect("key", "issuer", "private-key")
        urls: list[str] = []

        def fake_request(method: str, url: str, payload: dict | None = None) -> dict:
            urls.append(url)
            return {"data": versions}

        client._request = fake_request  # type: ignore[method-assign]
        return client, urls

    def test_default_platform_is_ios(self):
        client, urls = self.make_client([version("1.1.0", "PREPARE_FOR_SUBMISSION")])
        found = client.find_version("app", None)
        self.assertEqual(found["attributes"]["versionString"], "1.1.0")
        self.assertIn("filter%5Bplatform%5D=IOS", urls[0])

    def test_mac_os_platform_is_passed_to_filter(self):
        client, urls = self.make_client([version("1.1.0", "PREPARE_FOR_SUBMISSION")])
        client.find_version("app", "1.1.0", "MAC_OS")
        self.assertIn("filter%5Bplatform%5D=MAC_OS", urls[0])


class MissingVersionReasonTests(unittest.TestCase):
    def test_no_versions_means_platform_not_added(self):
        client = FakeClient([])
        reason = app_store_platform.missing_version_reason(client, "app", None, "MAC_OS")
        self.assertIn("macOS のバージョンがありません", reason)
        self.assertEqual(client.calls[0][1]["filter[platform]"], "MAC_OS")

    def test_requested_version_missing(self):
        client = FakeClient([version("1.0.0", "READY_FOR_SALE")])
        reason = app_store_platform.missing_version_reason(client, "app", "1.1.0", "MAC_OS")
        self.assertIn("バージョン 1.1.0 がありません", reason)

    def test_requested_version_exists_even_if_not_editable(self):
        # 審査中などで編集できないのは人が直すことなので、飛ばさずに find_version に止めさせる
        client = FakeClient([version("1.1.0", "WAITING_FOR_REVIEW")])
        self.assertIsNone(app_store_platform.missing_version_reason(client, "app", "1.1.0", "MAC_OS"))

    def test_no_editable_version(self):
        client = FakeClient([version("1.0.0", "READY_FOR_SALE")])
        reason = app_store_platform.missing_version_reason(client, "app", None, "MAC_OS")
        self.assertIn("編集できる状態のバージョンがありません", reason)
        self.assertIn("READY_FOR_SALE", reason)

    def test_finished_versions_only(self):
        client = FakeClient([version("1.0.0", "REPLACED_WITH_NEW_VERSION", "v1"),
                             version("1.1.0", "READY_FOR_SALE", "v2")])
        reason = app_store_platform.missing_version_reason(client, "app", None, "MAC_OS")
        self.assertIn("編集できる状態のバージョンがありません", reason)

    def test_version_in_review_is_not_skipped(self):
        # バージョンを指定しないとき（ワークフローの既定）も、審査中・公開待ちは飛ばさずに find_version に止めさせる
        for state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE"):
            with self.subTest(state=state):
                client = FakeClient([version("1.0.0", "READY_FOR_SALE", "v1"), version("1.1.0", state, "v2")])
                self.assertIsNone(app_store_platform.missing_version_reason(client, "app", None, "MAC_OS"))

    def test_app_version_state_is_preferred(self):
        # appVersionState だけを持つバージョンも見分ける（appStoreState は非推奨）
        in_review = {"id": "v1", "attributes": {"versionString": "1.1.0", "appVersionState": "IN_REVIEW"}}
        self.assertIsNone(app_store_platform.missing_version_reason(FakeClient([in_review]), "app", None, "MAC_OS"))
        released = {"id": "v1", "attributes": {"versionString": "1.0.0", "appVersionState": "READY_FOR_DISTRIBUTION"}}
        reason = app_store_platform.missing_version_reason(FakeClient([released]), "app", None, "MAC_OS")
        self.assertIn("READY_FOR_DISTRIBUTION", reason)

    def test_multiple_editable_versions_are_not_skipped(self):
        # 候補が複数あるのは人が直すことなので、飛ばさずに find_version に止めさせる
        client = FakeClient([version("1.1.0", "PREPARE_FOR_SUBMISSION", "v1"),
                             version("1.2.0", "REJECTED", "v2")])
        self.assertIsNone(app_store_platform.missing_version_reason(client, "app", None, "MAC_OS"))

    def test_editable_version_exists(self):
        client = FakeClient([version("1.0.0", "READY_FOR_SALE"), version("1.1.0", "PREPARE_FOR_SUBMISSION")])
        self.assertIsNone(app_store_platform.missing_version_reason(client, "app", None, "MAC_OS"))

    def test_skipped_message_contains_marker(self):
        message = app_store_platform.skipped_message("MAC_OS", "理由")
        # ワークフローはこの文言でログを探す（app-store-metadata.yml・app-store-screenshots.yml）
        self.assertIn("macOS の反映を飛ばしました", message)

    def test_skipped_hint_depends_on_reason(self):
        # 理由によって人がすることが違う（理由によらずプラットフォームの追加を案内しない）
        def hint(versions: list[dict], version_string: str | None) -> str:
            reason = app_store_platform.missing_version_reason(FakeClient(versions), "app", version_string, "MAC_OS")
            return app_store_platform.skipped_hint(app_store_platform.skipped_message("MAC_OS", reason))

        self.assertIn("プラットフォームを追加", hint([], None))
        finished = hint([version("1.0.0", "READY_FOR_SALE")], None)
        self.assertIn("配信を終えたバージョンしかありません", finished)
        self.assertNotIn("プラットフォームを追加", finished)
        missing = hint([version("1.0.0", "READY_FOR_SALE")], "1.1.0")
        self.assertIn("指定したバージョン番号", missing)
        self.assertNotIn("プラットフォームを追加", missing)
        self.assertIn("再実行", app_store_platform.skipped_hint("macOS の反映を飛ばしました: ほかの理由"))

    def test_hint_command(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = app_store_platform.main(["hint", "macOS の反映を飛ばしました: macOS に編集できる状態のバージョンがありません"])
        self.assertEqual(status, 0)
        self.assertIn("配信を終えたバージョンしかありません", output.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(app_store_platform.main([]), 2)

    def test_unknown_platform(self):
        with self.assertRaises(SystemExit):
            app_store_platform.platform_label("TV_OS")


SCREENSHOTS = {
    "scenes": [{"file": "01_action", "scene": "action"}],
    "displayTypes": {
        "APP_IPHONE_67": {"label": "iPhone 6.9 inch", "devices": ["iPhone 17 Pro Max"], "sizes": ["1320x2868"]},
        "APP_IPHONE_61": {"label": "iPhone 6.3 inch", "deriveFrom": "APP_IPHONE_67", "sizes": ["1206x2622"]},
        "APP_DESKTOP": {"label": "Mac", "platform": "MAC_OS", "sizes": ["2880x1800", "1280x800"]},
        "APP_IPAD_PRO_129": {"label": "iPad", "sizes": ["2048x2732"]},
    },
}


class FirstVersionTests(unittest.TestCase):
    def test_only_version_is_first(self):
        target = version("1.0.0", "PREPARE_FOR_SUBMISSION", "v1")
        client = FakeClient([target])
        self.assertTrue(app_store_platform.is_first_version(client, "app", target, "MAC_OS"))
        self.assertEqual(client.calls, [("/v1/apps/app/appStoreVersions", {"filter[platform]": "MAC_OS", "limit": 50})])

    def test_rejected_or_unreleased_others_do_not_count(self):
        target = version("1.0.0", "PREPARE_FOR_SUBMISSION", "v2")
        client = FakeClient([version("0.9.0", "DEVELOPER_REJECTED", "v1"), target])
        self.assertTrue(app_store_platform.is_first_version(client, "app", target, "IOS"))

    def test_released_or_finished_version_means_update(self):
        target = version("1.1.0", "PREPARE_FOR_SUBMISSION", "v2")
        for state in ("READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE"):
            with self.subTest(state=state):
                client = FakeClient([version("1.0.0", state, "v1"), target])
                self.assertFalse(app_store_platform.is_first_version(client, "app", target, "IOS"))

    def test_app_version_state_is_used(self):
        target = version("1.1.0", "PREPARE_FOR_SUBMISSION", "v2")
        released = {"id": "v1", "attributes": {"versionString": "1.0.0", "appVersionState": "READY_FOR_DISTRIBUTION"}}
        self.assertFalse(app_store_platform.is_first_version(FakeClient([released, target]), "app", target, "IOS"))


class ScreenshotConfigTests(unittest.TestCase):
    def patch_config(self, config: dict):
        return mock.patch.object(app_store_config, "_screenshots_config", return_value=config)

    def test_platform_defaults_to_ios(self):
        with self.patch_config(SCREENSHOTS):
            self.assertEqual(app_store_config.display_type_platform("APP_IPHONE_67"), "IOS")
            self.assertEqual(app_store_config.display_type_platform("APP_IPHONE_61"), "IOS")
            self.assertEqual(app_store_config.display_type_platform("APP_DESKTOP"), "MAC_OS")

    def test_capture_method(self):
        with self.patch_config(SCREENSHOTS):
            self.assertEqual(app_store_config.capture_method("APP_IPHONE_67"), "simulator")
            self.assertEqual(app_store_config.capture_method("APP_IPHONE_61"), "derive")
            self.assertEqual(app_store_config.capture_method("APP_DESKTOP"), "macos-unit-test")
            # devices の無い iOS の表示サイズは撮れない
            self.assertIsNone(app_store_config.capture_method("APP_IPAD_PRO_129"))

    def test_matrix_captures_mac_and_skips_display_types_without_capture_method(self):
        with self.patch_config(SCREENSHOTS):
            result = app_store_config.matrix()
        self.assertEqual(
            [(entry["display_type"], entry["method"], entry["runs_on"]) for entry in result["capture"]],
            [("APP_IPHONE_67", "simulator", "macos-latest"), ("APP_DESKTOP", "macos-unit-test", "macos-latest")],
        )
        self.assertEqual([entry["display_type"] for entry in result["derive"]], ["APP_IPHONE_61"])
        self.assertEqual(
            [(entry["display_type"], entry["platform"]) for entry in result["upload"]],
            [("APP_IPHONE_67", "IOS"), ("APP_IPHONE_61", "IOS"), ("APP_DESKTOP", "MAC_OS")],
        )
        self.assertEqual([entry["display_type"] for entry in result["skipped"]], ["APP_IPAD_PRO_129"])

    def test_matrix_with_only_mac(self):
        with self.patch_config(SCREENSHOTS):
            result = app_store_config.matrix(["APP_DESKTOP"])
        self.assertEqual([entry["display_type"] for entry in result["capture"]], ["APP_DESKTOP"])
        self.assertEqual(result["derive"], [])
        self.assertEqual(result["upload"], [{"display_type": "APP_DESKTOP", "label": "Mac", "platform": "MAC_OS"}])
        self.assertEqual(result["skipped"], [])

    def test_unknown_platform_is_rejected(self):
        config = {"scenes": [], "displayTypes": {"X": {"label": "X", "platform": "TV_OS", "sizes": ["1x1"]}}}
        with self.patch_config(config), self.assertRaises(SystemExit):
            app_store_config.display_type("X")

    def test_malformed_sizes_are_rejected(self):
        config = {"scenes": [], "displayTypes": {"X": {"label": "X", "sizes": ["2880*1800"]}}}
        with self.patch_config(config), self.assertRaises(SystemExit):
            app_store_config.display_type("X")

    def test_derive_from_another_platform_is_rejected(self):
        config = {"scenes": [], "displayTypes": {
            "APP_IPHONE_67": {"label": "iPhone", "devices": ["iPhone 17 Pro Max"], "sizes": ["1320x2868"]},
            "APP_DESKTOP": {"label": "Mac", "platform": "MAC_OS", "deriveFrom": "APP_IPHONE_67", "sizes": ["2880x1800"]},
        }}
        with self.patch_config(config), self.assertRaises(SystemExit):
            app_store_config.display_type("APP_DESKTOP")

    def test_repository_config_has_mac_display_type(self):
        # リポジトリの AppStore/screenshots.json そのもの
        entry = app_store_config.display_type("APP_DESKTOP")
        self.assertEqual(app_store_config.display_type_platform("APP_DESKTOP"), "MAC_OS")
        self.assertEqual(entry["sizes"][0], "2880x1800")
        result = app_store_config.matrix()
        self.assertIn("APP_DESKTOP", [capture["display_type"] for capture in result["capture"]])
        self.assertEqual(result["skipped"], [])


class ResolvePlatformTests(unittest.TestCase):
    def test_platform_comes_from_display_type(self):
        with mock.patch.object(app_store_config, "_screenshots_config", return_value=SCREENSHOTS):
            self.assertEqual(upload_screenshots.resolve_platform("APP_DESKTOP", None), "MAC_OS")
            self.assertEqual(upload_screenshots.resolve_platform("APP_IPHONE_67", "IOS"), "IOS")

    def test_mismatched_platform_is_rejected(self):
        with mock.patch.object(app_store_config, "_screenshots_config", return_value=SCREENSHOTS):
            with self.assertRaises(SystemExit):
                upload_screenshots.resolve_platform("APP_DESKTOP", "IOS")


class FakeAppStoreConnect:
    """upload_metadata.main から使う App Store Connect の代わり。書き込みは記録するだけ。"""

    versions: list[dict] = []
    instances: list["FakeAppStoreConnect"] = []

    def __init__(self, key_id, issuer_id, private_key, dry_run=False):
        self.dry_run = dry_run
        self.find_version_calls: list[tuple] = []
        self.patches: list[str] = []
        self.payloads: list[dict] = []
        FakeAppStoreConnect.instances.append(self)

    def find_app(self, bundle_id):
        return {"id": "app", "attributes": {"name": "AskHub", "bundleId": bundle_id}}

    def get_all(self, path, params=None):
        return list(self.versions)

    def find_version(self, app_id, version_string, platform="IOS"):
        self.find_version_calls.append((app_id, version_string, platform))
        return self.versions[0]

    def localization_entries(self, version_id):
        return {"ja": {"id": "loc", "attributes": {}}}

    def patch(self, path, payload):
        self.patches.append(path)
        self.payloads.append(payload)


class UploadMetadataMainTests(unittest.TestCase):
    def run_main(self, *arguments: str) -> tuple[int, str]:
        FakeAppStoreConnect.instances = []
        with tempfile.NamedTemporaryFile("w", suffix=".p8") as key:
            key.write("dummy")
            key.flush()
            argv = ["upload_metadata.py", "--bundle-id", "jp.example.App",
                    "--key-id", "key", "--issuer-id", "issuer", "--private-key", key.name, *arguments]
            output = io.StringIO()
            with mock.patch.object(sys, "argv", argv), \
                    mock.patch.object(app_store_connect, "AppStoreConnect", FakeAppStoreConnect), \
                    contextlib.redirect_stdout(output):
                status = upload_metadata.main()
        return status, output.getvalue()

    def test_default_targets_ios(self):
        FakeAppStoreConnect.versions = [version("1.1.0", "PREPARE_FOR_SUBMISSION")]
        status, output = self.run_main("--dry-run")
        self.assertEqual(status, 0)
        self.assertEqual(FakeAppStoreConnect.instances[0].find_version_calls, [("app", None, "IOS")])
        self.assertIn("/ iOS", output)

    def test_mac_os_without_version_is_skipped(self):
        FakeAppStoreConnect.versions = []
        status, output = self.run_main("--platform", "MAC_OS", "--missing-version", "skip")
        self.assertEqual(status, 0)
        self.assertIn("macOS の反映を飛ばしました", output)
        self.assertEqual(FakeAppStoreConnect.instances[0].find_version_calls, [])
        self.assertEqual(FakeAppStoreConnect.instances[0].patches, [])

    def test_mac_os_with_version_is_written(self):
        FakeAppStoreConnect.versions = [version("1.1.0", "PREPARE_FOR_SUBMISSION")]
        status, output = self.run_main("--platform", "MAC_OS", "--missing-version", "skip")
        self.assertEqual(status, 0)
        client = FakeAppStoreConnect.instances[0]
        self.assertEqual(client.find_version_calls, [("app", None, "MAC_OS")])
        self.assertEqual(client.patches, ["/v1/appStoreVersionLocalizations/loc"])
        self.assertIn("/ macOS", output)

    def metadata_dir(self, whats_new_version: str) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name)
        (path / "shared.json").write_text('{"supportUrl": "https://example.com"}', encoding="utf-8")
        (path / "ja.json").write_text(
            '{"description": "説明", "keywords": ["a"], "whatsNew": {"version": "%s", "text": "最新情報"}}'
            % whats_new_version, encoding="utf-8")
        return path

    def written_attributes(self) -> dict:
        payloads = FakeAppStoreConnect.instances[0].payloads
        self.assertEqual(len(payloads), 1)
        return payloads[0]["data"]["attributes"]

    def test_whats_new_is_written_to_update(self):
        FakeAppStoreConnect.versions = [version("1.1.0", "PREPARE_FOR_SUBMISSION", "v2"),
                                        version("1.0.0", "READY_FOR_SALE", "v1")]
        status, output = self.run_main("--metadata-dir", str(self.metadata_dir("1.1.0")))
        self.assertEqual(status, 0)
        self.assertEqual(self.written_attributes()["whatsNew"], "最新情報")
        self.assertNotIn("最初のバージョン", output)

    def test_whats_new_is_not_written_to_first_version(self):
        FakeAppStoreConnect.versions = [version("1.0.0", "PREPARE_FOR_SUBMISSION")]
        status, output = self.run_main("--metadata-dir", str(self.metadata_dir("1.0.0")))
        self.assertEqual(status, 0)
        attributes = self.written_attributes()
        self.assertNotIn("whatsNew", attributes)
        self.assertEqual(attributes["description"], "説明")
        self.assertIn("1.0.0 は iOS の最初のバージョンなので、whatsNew は書き込みません", output)


if __name__ == "__main__":
    unittest.main()

"""Tools/app_store_connect.py のテスト。HTTP は偽物に差し替え、PyJWT も使わない。"""

from __future__ import annotations

import sys
import unittest
from unittest import mock

from .fake_app_store_connect import API, FakeAppStoreConnect, http_error

import app_store_connect  # noqa: E402  (fake_app_store_connect が Tools/ を sys.path に足す)
from app_store_connect import ApiError, AppStoreConnect, is_editable, is_released, version_state


def make_client(fake: FakeAppStoreConnect, dry_run: bool = False) -> AppStoreConnect:
    return AppStoreConnect("key", "issuer", "private", dry_run=dry_run,
                           urlopen=fake.urlopen, sleep=fake.sleeps.append)


class ClientTestCase(unittest.TestCase):
    def setUp(self) -> None:
        patcher = mock.patch.object(app_store_connect, "make_token", return_value="test-token")
        patcher.start()
        self.addCleanup(patcher.stop)
        self.fake = FakeAppStoreConnect()
        self.client = make_client(self.fake)


class ImportTests(unittest.TestCase):
    def test_PyJWTをimportせずに読み込める(self) -> None:
        self.assertNotIn("jwt", sys.modules)


class PagingTests(ClientTestCase):
    def test_次のページを最後までたどる(self) -> None:
        self.fake.page_size = 2
        for minor in range(5):
            self.fake.add_version("IOS", f"1.{minor}.0", "READY_FOR_SALE")

        versions = self.client.app_store_versions(self.fake.app_id)

        self.assertEqual([v["attributes"]["versionString"] for v in versions],
                         ["1.0.0", "1.1.0", "1.2.0", "1.3.0", "1.4.0"])
        self.assertEqual(len(self.fake.requests), 3)

    def test_プラットフォームで絞り込む(self) -> None:
        self.fake.add_version("IOS", "1.0.0", "READY_FOR_SALE")
        self.fake.add_version("MAC_OS", "1.0", "PREPARE_FOR_SUBMISSION")

        versions = self.client.app_store_versions(self.fake.app_id, "MAC_OS")

        self.assertEqual([v["attributes"]["versionString"] for v in versions], ["1.0"])
        self.assertEqual(self.fake.requests[0][2]["filter[platform]"], "MAC_OS")

    def test_find_versionは既定でIOSを探す(self) -> None:
        self.fake.add_version("IOS", "1.1.0", "PREPARE_FOR_SUBMISSION")
        self.fake.add_version("MAC_OS", "1.2.0", "PREPARE_FOR_SUBMISSION")

        self.assertEqual(self.client.find_version(self.fake.app_id, None)["attributes"]["versionString"], "1.1.0")
        self.assertEqual(
            self.client.find_version(self.fake.app_id, None, "MAC_OS")["attributes"]["versionString"], "1.2.0")


class RateLimitTests(ClientTestCase):
    def test_429はRetryAfterの秒数を待って再試行する(self) -> None:
        self.fake.failures.append(http_error(f"{API}/v1/apps", 429, headers={"Retry-After": "3"}))

        app = self.client.find_app(self.fake.bundle_id)

        self.assertEqual(app["id"], self.fake.app_id)
        self.assertEqual(self.fake.sleeps, [3.0])
        self.assertEqual(len(self.fake.requests), 2)

    def test_RetryAfterが無ければ倍々に待つ(self) -> None:
        self.fake.failures.extend(http_error(f"{API}/v1/apps", 429) for _ in range(2))

        self.client.find_app(self.fake.bundle_id)

        self.assertEqual(self.fake.sleeps, [10.0, 20.0])

    def test_再試行の上限を超えたら失敗する(self) -> None:
        self.fake.failures.extend(
            http_error(f"{API}/v1/apps", 429, headers={"Retry-After": "1"})
            for _ in range(app_store_connect.RATE_LIMIT_RETRIES + 1))

        with self.assertRaises(ApiError) as context:
            self.client.find_app(self.fake.bundle_id)

        self.assertEqual(context.exception.status, 429)
        self.assertIn("Retry-After: 1", str(context.exception))
        self.assertEqual(len(self.fake.sleeps), app_store_connect.RATE_LIMIT_RETRIES)

    def test_RetryAfterが長すぎるときは待たずに失敗する(self) -> None:
        self.fake.failures.append(http_error(f"{API}/v1/apps", 429, headers={"Retry-After": "3600"}))

        with self.assertRaises(ApiError):
            self.client.find_app(self.fake.bundle_id)

        self.assertEqual(self.fake.sleeps, [])

    def test_429以外の失敗は再試行しない(self) -> None:
        self.fake.failures.append(http_error(f"{API}/v1/apps", 409))

        with self.assertRaises(ApiError) as context:
            self.client.find_app(self.fake.bundle_id)

        self.assertEqual(context.exception.status, 409)
        self.assertEqual(len(self.fake.requests), 1)


class VersionTests(ClientTestCase):
    def test_バージョンを作る(self) -> None:
        created = self.client.create_version(self.fake.app_id, "1.1.0", "MAC_OS")

        self.assertEqual(created["attributes"]["versionString"], "1.1.0")
        method, path, payload = self.fake.writes()[0]
        self.assertEqual((method, path), ("POST", "/v1/appStoreVersions"))
        self.assertEqual(payload["data"]["attributes"], {"platform": "MAC_OS", "versionString": "1.1.0"})
        self.assertEqual(payload["data"]["relationships"]["app"]["data"]["id"], self.fake.app_id)

    def test_versionStringを書き換える(self) -> None:
        version_id = self.fake.add_version("IOS", "1.0", "PREPARE_FOR_SUBMISSION")

        self.client.update_version_string(version_id, "1.1.0")

        self.assertEqual(self.fake.versions[version_id]["attributes"]["versionString"], "1.1.0")

    def test_dry_runでは書き込まない(self) -> None:
        client = make_client(self.fake, dry_run=True)
        version_id = self.fake.add_version("IOS", "1.0", "PREPARE_FOR_SUBMISSION")

        client.create_version(self.fake.app_id, "1.1.0")
        client.update_version_string(version_id, "1.1.0")
        client.attach_build(version_id, "build-x")

        self.assertEqual(self.fake.writes(), [])


class BuildTests(ClientTestCase):
    def test_処理済みのビルドを新しい順に返す(self) -> None:
        old = self.fake.add_build("IOS", "1.1.0", "10", "2026-10-01T00:00:00Z")
        new = self.fake.add_build("IOS", "1.1.0", "12", "2026-10-03T00:00:00Z")
        self.fake.add_build("IOS", "1.1.0", "13", "2026-10-04T00:00:00Z", state="PROCESSING")
        self.fake.add_build("IOS", "1.1.0", "9", "2026-10-05T00:00:00Z", expired=True)
        self.fake.add_build("MAC_OS", "1.1.0", "11", "2026-10-06T00:00:00Z")
        self.fake.add_build("IOS", "1.0.0", "8", "2026-10-07T00:00:00Z")

        builds = self.client.valid_builds(self.fake.app_id, "1.1.0", "IOS")

        self.assertEqual([b["id"] for b in builds], [new, old])
        query = self.fake.requests[0][2]
        self.assertEqual(query["filter[app]"], self.fake.app_id)
        self.assertEqual(query["filter[processingState]"], "VALID")

    def test_紐付けを読み書きする(self) -> None:
        version_id = self.fake.add_version("IOS", "1.1.0", "PREPARE_FOR_SUBMISSION")
        build_id = self.fake.add_build("IOS", "1.1.0", "10", "2026-10-01T00:00:00Z")

        self.assertIsNone(self.client.attached_build_id(version_id))
        self.client.attach_build(version_id, build_id)

        self.assertEqual(self.client.attached_build_id(version_id), build_id)
        method, path, payload = self.fake.writes()[0]
        self.assertEqual((method, path), ("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build"))
        self.assertEqual(payload, {"data": {"type": "builds", "id": build_id}})


class StateTests(unittest.TestCase):
    def test_appVersionStateを優先する(self) -> None:
        attributes = {"appStoreState": "PREPARE_FOR_SUBMISSION", "appVersionState": "WAITING_FOR_REVIEW"}
        self.assertEqual(version_state(attributes), "WAITING_FOR_REVIEW")
        self.assertFalse(is_editable(attributes))
        self.assertEqual(version_state({"appStoreState": "REJECTED"}), "REJECTED")
        self.assertTrue(is_editable({"appStoreState": "REJECTED"}))

    def test_配信済みの判定(self) -> None:
        released = [
            {"appVersionState": "READY_FOR_DISTRIBUTION", "appStoreState": "READY_FOR_SALE"},
            {"appVersionState": "READY_FOR_DISTRIBUTION"},
            {"appStoreState": "READY_FOR_SALE"},
            {"appStoreState": "REPLACED_WITH_NEW_VERSION"},
            {"appVersionState": "REPLACED_WITH_NEW_VERSION"},
        ]
        not_released = [
            {"appVersionState": "PENDING_DEVELOPER_RELEASE", "appStoreState": "PENDING_DEVELOPER_RELEASE"},
            {"appVersionState": "PROCESSING_FOR_DISTRIBUTION", "appStoreState": "PROCESSING_FOR_APP_STORE"},
            {"appVersionState": "WAITING_FOR_REVIEW"},
            {"appStoreState": "PREPARE_FOR_SUBMISSION"},
            {},
        ]
        for attributes in released:
            self.assertTrue(is_released(attributes), attributes)
        for attributes in not_released:
            self.assertFalse(is_released(attributes), attributes)


if __name__ == "__main__":
    unittest.main()

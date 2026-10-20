"""Tools/release_app_store.py のテスト。HTTP は偽物に差し替え、PyJWT も使わない。"""

from __future__ import annotations

import contextlib
import http.client
import io
import json
import socket
import sys
import types
import unittest
import urllib.error
from unittest import mock

from .fake_app_store_connect import API, FakeAppStoreConnect, FakeResponse, http_error

import app_store_connect  # noqa: E402  (fake_app_store_connect が Tools/ を sys.path に足す)
import release_app_store
from app_store_connect import AppStoreConnect

#: setUp で差し替える前の本物（トークンの作成の失敗を確かめるテストで使う）
REAL_MAKE_TOKEN = app_store_connect.make_token


class ReleaseTestCase(unittest.TestCase):
    def setUp(self) -> None:
        patcher = mock.patch.object(app_store_connect, "make_token", return_value="test-token")
        patcher.start()
        self.addCleanup(patcher.stop)
        self.fake = FakeAppStoreConnect()

    def invoke(self, *args: str, dry_run: bool = False) -> tuple[int, dict]:
        client = AppStoreConnect("key", "issuer", "private", dry_run=dry_run,
                                 urlopen=self.fake.urlopen, sleep=self.fake.sleeps.append)
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = release_app_store.main([*args, "--bundle-id", self.fake.bundle_id], client=client)
        return code, json.loads(stdout.getvalue())


class PrepareTests(ReleaseTestCase):
    def test_バージョンを作りmacOSが無ければ飛ばして続ける(self) -> None:
        self.fake.add_version("IOS", "1.0.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION")

        code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 0)
        self.assertTrue(result["ok"])
        self.assertEqual(result["platforms"]["IOS"]["status"], "created")
        self.assertEqual(result["platforms"]["IOS"]["versionString"], "1.1.0")
        self.assertEqual(result["platforms"]["MAC_OS"]["status"], "platform-missing")
        self.assertIn("macOS のプラットフォームがありません", result["platforms"]["MAC_OS"]["message"])
        self.assertEqual([w[:2] for w in self.fake.writes()], [("POST", "/v1/appStoreVersions")])

    def test_同じバージョンがあれば何もしない(self) -> None:
        self.fake.add_version("IOS", "1.1.0", "PREPARE_FOR_SUBMISSION", "PREPARE_FOR_SUBMISSION")
        self.fake.add_version("MAC_OS", "1.1.0", "WAITING_FOR_REVIEW", "WAITING_FOR_REVIEW")

        code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 0)
        self.assertEqual(result["platforms"]["IOS"]["status"], "exists")
        self.assertEqual(result["platforms"]["MAC_OS"]["status"], "exists")
        self.assertFalse(result["platforms"]["MAC_OS"]["editable"])
        self.assertEqual(self.fake.writes(), [])

    def test_古い編集できるバージョンは書き換える(self) -> None:
        version_id = self.fake.add_version("MAC_OS", "1.0", "PREPARE_FOR_SUBMISSION", "PREPARE_FOR_SUBMISSION")
        self.fake.add_version("IOS", "1.1.0", "PREPARE_FOR_SUBMISSION")

        code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 0)
        mac = result["platforms"]["MAC_OS"]
        self.assertEqual(mac["status"], "renamed")
        self.assertEqual(mac["previousVersionString"], "1.0")
        self.assertEqual(mac["versionId"], version_id)
        self.assertEqual(self.fake.versions[version_id]["attributes"]["versionString"], "1.1.0")

    def test_新しい編集できるバージョンは書き換えずに止める(self) -> None:
        self.fake.add_version("IOS", "2.0.0", "PREPARE_FOR_SUBMISSION")

        code, result = self.invoke("prepare", "--version", "1.1.0", "--platforms", "IOS")

        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        self.assertEqual(result["platforms"]["IOS"]["status"], "blocked")
        self.assertIn("2.0.0", result["error"])
        self.assertEqual(self.fake.writes(), [])

    def test_other_editableがfailなら古くても止める(self) -> None:
        self.fake.add_version("IOS", "1.0.1", "REJECTED")

        code, result = self.invoke("prepare", "--version", "1.1.0", "--other-editable", "fail")

        self.assertEqual(code, 1)
        self.assertEqual(result["platforms"]["IOS"]["status"], "blocked")
        self.assertEqual(self.fake.writes(), [])

    def test_iOSが無ければ失敗にする(self) -> None:
        self.fake.add_version("MAC_OS", "1.0.0", "READY_FOR_SALE")

        code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertEqual(result["platforms"]["IOS"]["status"], "platform-missing")
        self.assertEqual(result["platforms"]["MAC_OS"]["status"], "created")
        self.assertIn("必須", result["error"])

    def test_dry_runでは作らない(self) -> None:
        self.fake.add_version("IOS", "1.0.0", "READY_FOR_SALE")
        self.fake.add_version("MAC_OS", "1.0", "PREPARE_FOR_SUBMISSION")

        code, result = self.invoke("prepare", "--version", "1.1.0", dry_run=True)

        self.assertEqual(code, 0)
        self.assertTrue(result["dryRun"])
        self.assertEqual(result["platforms"]["IOS"]["status"], "created")
        self.assertEqual(result["platforms"]["MAC_OS"]["status"], "renamed")
        self.assertEqual(self.fake.writes(), [])

    def test_バージョンの形が違えば呼ばずに失敗する(self) -> None:
        code, result = self.invoke("prepare", "--version", "1.1")

        self.assertEqual(code, 2)
        self.assertFalse(result["ok"])
        self.assertEqual(self.fake.requests, [])

    def test_APIの失敗はJSONで返す(self) -> None:
        self.fake.add_version("IOS", "1.0.0", "READY_FOR_SALE")
        self.fake.failures.append(http_error(f"{API}/v1/apps", 401))

        code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertEqual(result["httpStatus"], 401)
        self.assertIn("401", result["error"])


class AttachBuildTests(ReleaseTestCase):
    def test_最新の処理済みのビルドを紐付ける(self) -> None:
        version_id = self.fake.add_version("IOS", "1.1.0", "PREPARE_FOR_SUBMISSION")
        self.fake.add_build("IOS", "1.1.0", "10", "2026-10-01T00:00:00Z")
        latest = self.fake.add_build("IOS", "1.1.0", "11", "2026-10-02T00:00:00Z")

        code, result = self.invoke("attach-build", "--version", "1.1.0")

        self.assertEqual(code, 0)
        ios = result["platforms"]["IOS"]
        self.assertEqual(ios["status"], "attached")
        self.assertEqual(ios["build"]["buildNumber"], "11")
        self.assertIsNone(ios["previousBuildId"])
        self.assertEqual(self.fake.attachments[version_id], latest)
        self.assertEqual(result["platforms"]["MAC_OS"]["status"], "platform-missing")

    def test_古いビルドが紐付いていれば最新に差し替える(self) -> None:
        version_id = self.fake.add_version("IOS", "1.1.0", "PREPARE_FOR_SUBMISSION")
        old = self.fake.add_build("IOS", "1.1.0", "10", "2026-10-01T00:00:00Z")
        latest = self.fake.add_build("IOS", "1.1.0", "11", "2026-10-02T00:00:00Z")
        self.fake.attachments[version_id] = old

        _, result = self.invoke("attach-build", "--version", "1.1.0", "--platforms", "IOS")

        self.assertEqual(result["platforms"]["IOS"]["status"], "attached")
        self.assertEqual(result["platforms"]["IOS"]["previousBuildId"], old)
        self.assertEqual(self.fake.attachments[version_id], latest)

    def test_最新が紐付いていれば何もしない(self) -> None:
        version_id = self.fake.add_version("IOS", "1.1.0", "PREPARE_FOR_SUBMISSION")
        self.fake.attachments[version_id] = self.fake.add_build("IOS", "1.1.0", "11", "2026-10-02T00:00:00Z")

        _, result = self.invoke("attach-build", "--version", "1.1.0", "--platforms", "IOS")

        self.assertEqual(result["platforms"]["IOS"]["status"], "already-attached")
        self.assertEqual(self.fake.writes(), [])

    def test_ビルドがまだ無ければ待つ(self) -> None:
        self.fake.add_version("IOS", "1.1.0", "PREPARE_FOR_SUBMISSION")
        self.fake.add_build("IOS", "1.1.0", "11", "2026-10-02T00:00:00Z", state="PROCESSING")

        code, result = self.invoke("attach-build", "--version", "1.1.0", "--platforms", "IOS")

        self.assertEqual(code, 0)
        self.assertEqual(result["platforms"]["IOS"]["status"], "waiting-for-build")

    def test_審査中のバージョンは触らない(self) -> None:
        version_id = self.fake.add_version("IOS", "1.1.0", "WAITING_FOR_REVIEW", "WAITING_FOR_REVIEW")
        old = self.fake.add_build("IOS", "1.1.0", "10", "2026-10-01T00:00:00Z")
        self.fake.add_build("IOS", "1.1.0", "11", "2026-10-02T00:00:00Z")
        self.fake.attachments[version_id] = old

        _, result = self.invoke("attach-build", "--version", "1.1.0", "--platforms", "IOS")

        self.assertEqual(result["platforms"]["IOS"]["status"], "locked")
        self.assertEqual(self.fake.attachments[version_id], old)

    def test_バージョンが無ければ知らせる(self) -> None:
        self.fake.add_version("IOS", "1.0.0", "READY_FOR_SALE")

        code, result = self.invoke("attach-build", "--version", "1.1.0", "--platforms", "IOS")

        self.assertEqual(code, 0)
        self.assertEqual(result["platforms"]["IOS"]["status"], "version-missing")


class StatusTests(ReleaseTestCase):
    def test_作ったプラットフォームがすべて配信済みならreleased(self) -> None:
        self.fake.add_version("IOS", "1.1.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
        self.fake.add_version("MAC_OS", "1.1.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION")

        code, result = self.invoke("status", "--version", "1.1.0")

        self.assertEqual(code, 0)
        self.assertTrue(result["released"])
        self.assertEqual(result["platforms"]["MAC_OS"]["status"], "released")

    def test_片方がまだならreleasedではない(self) -> None:
        self.fake.add_version("IOS", "1.1.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
        self.fake.add_version("MAC_OS", "1.1.0", "PENDING_DEVELOPER_RELEASE", "PENDING_DEVELOPER_RELEASE")

        _, result = self.invoke("status", "--version", "1.1.0")

        self.assertFalse(result["released"])
        self.assertEqual(result["platforms"]["MAC_OS"]["status"], "not-released")

    def test_macOSのプラットフォームやバージョンが無ければiOSだけで判定する(self) -> None:
        self.fake.add_version("IOS", "1.1.0", "READY_FOR_SALE")
        _, missing_platform = self.invoke("status", "--version", "1.1.0")

        self.fake.add_version("MAC_OS", "1.0.0", "READY_FOR_SALE")
        _, missing_version = self.invoke("status", "--version", "1.1.0")

        self.assertTrue(missing_platform["released"])
        self.assertEqual(missing_platform["platforms"]["MAC_OS"]["status"], "platform-missing")
        self.assertTrue(missing_version["released"])
        self.assertEqual(missing_version["platforms"]["MAC_OS"]["status"], "version-missing")

    def test_どこにもバージョンが無ければreleasedではない(self) -> None:
        self.fake.add_version("IOS", "1.0.0", "READY_FOR_SALE")

        _, result = self.invoke("status", "--version", "1.1.0", "--platforms", "IOS")

        self.assertFalse(result["released"])
        self.assertEqual(self.fake.writes(), [])


class FailureTests(ReleaseTestCase):
    """どの失敗でも標準出力に JSON が 1 つ出て、ほかのプラットフォームの結果が消えないこと（#621 のレビュー）。"""

    def run_main(self, *args: str) -> tuple[int, dict, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = release_app_store.main(list(args))
        return code, json.loads(stdout.getvalue()), stderr.getvalue()

    def test_片方のプラットフォームのAPIの失敗でももう片方の結果を残す(self) -> None:
        self.fake.add_version("IOS", "1.0.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
        self.fake.add_version("MAC_OS", "1.0.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
        # macOS のバージョンの作成だけを 409 にする（iOS は作れる）
        self.fake.route_failures.append((
            lambda method, path, query, payload: method == "POST" and path == "/v1/appStoreVersions"
            and payload["data"]["attributes"]["platform"] == "MAC_OS",
            http_error(f"{API}/v1/appStoreVersions", 409)))

        code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        self.assertEqual(result["platforms"]["IOS"]["status"], "created")
        self.assertEqual(result["platforms"]["MAC_OS"]["status"], "error")
        self.assertEqual(result["platforms"]["MAC_OS"]["httpStatus"], 409)
        self.assertIn("macOS", result["error"])

    def test_一覧の取得が失敗したプラットフォームだけをerrorにする(self) -> None:
        self.fake.add_version("IOS", "1.1.0", "PREPARE_FOR_SUBMISSION", "PREPARE_FOR_SUBMISSION")
        self.fake.route_failures.append((
            lambda method, path, query, payload: path.endswith("/appStoreVersions")
            and query.get("filter[platform]") == "MAC_OS",
            http_error(f"{API}/v1/apps", 500)))

        code, result = self.invoke("status", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertEqual(result["platforms"]["IOS"]["status"], "not-released")
        self.assertEqual(result["platforms"]["MAC_OS"]["status"], "error")
        self.assertFalse(result["released"])

    def test_片方の状態を読めなければ配信済みにしない(self) -> None:
        self.fake.add_version("IOS", "1.1.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
        self.fake.route_failures.append((
            lambda method, path, query, payload: query.get("filter[platform]") == "MAC_OS",
            http_error(f"{API}/v1/apps", 503)))

        code, result = self.invoke("status", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertEqual(result["platforms"]["IOS"]["status"], "released")
        self.assertFalse(result["released"])

    def test_通信の失敗はJSONで返す(self) -> None:
        self.fake.failures.append(urllib.error.URLError("Name or service not known"))

        code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        self.assertIn("通信に失敗しました", result["error"])
        self.assertIsNone(result["httpStatus"])

    def test_タイムアウトはJSONで返す(self) -> None:
        self.fake.failures.append(socket.timeout("timed out"))

        code, result = self.invoke("status", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertIn("timed out", result["error"])

    def test_応答の途中で切れてもJSONで返す(self) -> None:
        # IncompleteRead は http.client.HTTPException の子で、OSError ではない（第三者レビューの提案 7）
        class Truncated(FakeResponse):
            def read(self) -> bytes:
                raise http.client.IncompleteRead(b'{"data": [', 100)

        self.fake.urlopen = lambda request, timeout=None: Truncated(None)

        code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        self.assertIn("通信に失敗しました", result["error"])
        self.assertIn("IncompleteRead", result["error"])
        self.assertIsNone(result["httpStatus"])

    def test_エラーの本文の途中で切れてもステータスを残す(self) -> None:
        self.fake.add_version("IOS", "1.0.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
        error = http_error(f"{API}/v1/appStoreVersions", 500)
        error.read = mock.Mock(side_effect=http.client.IncompleteRead(b"{", 10))  # type: ignore[method-assign]
        self.fake.route_failures.append((
            lambda method, path, query, payload: method == "POST" and path == "/v1/appStoreVersions", error))

        code, result = self.invoke("prepare", "--version", "1.1.0", "--platforms", "IOS")

        self.assertEqual(code, 1)
        self.assertEqual(result["platforms"]["IOS"]["status"], "error")
        self.assertEqual(result["platforms"]["IOS"]["httpStatus"], 500)

    def test_トークンを作れなければJSONで返す(self) -> None:
        # 鍵の形の誤り（PyJWT・cryptography の例外）も ApiError にそろえる。PyJWT は偽物の jwt モジュールに差し替える
        fake_jwt = types.ModuleType("jwt")

        def encode(*args, **kwargs):
            raise ValueError("Could not deserialize key data.")

        fake_jwt.encode = encode  # type: ignore[attr-defined]
        with mock.patch.dict(sys.modules, {"jwt": fake_jwt}), \
                mock.patch.object(app_store_connect, "make_token", side_effect=REAL_MAKE_TOKEN):
            with self.assertRaises(app_store_connect.ApiError) as raised:
                REAL_MAKE_TOKEN("key", "issuer", "not a key")
            code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertIsNone(raised.exception.status)
        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        self.assertIn("トークンを作れませんでした", result["error"])
        self.assertIn("ValueError", result["error"])
        self.assertNotIn("not a key", result["error"])
        self.assertEqual(self.fake.requests, [])

    def test_JSONでない応答はJSONで返す(self) -> None:
        broken = FakeResponse(None)
        broken._raw = b"<html>Bad Gateway</html>"
        self.fake.urlopen = lambda request, timeout=None: broken

        code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertIn("JSON ではありません", result["error"])

    def test_鍵のファイルが無ければJSONで返す(self) -> None:
        code, result, _ = self.run_main(
            "prepare", "--version", "1.1.0", "--bundle-id", self.fake.bundle_id,
            "--key-id", "key", "--issuer-id", "issuer", "--private-key", "/nonexistent/AuthKey.p8")

        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        self.assertIn("ファイルを読めません", result["error"])

    def test_思わぬ例外でもJSONで返す(self) -> None:
        with mock.patch.object(release_app_store, "run", side_effect=KeyError("attributes")):
            code, result = self.invoke("prepare", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertIn("KeyError", result["error"])

    def test_引数の誤りは終了コード2でJSONを返す(self) -> None:
        code, result, stderr = self.run_main("prepare", "--version", "1.1.0", "--platforms", "WATCH_OS")

        self.assertEqual(code, 2)
        self.assertFalse(result["ok"])
        self.assertIn("引数の誤り", result["error"])
        self.assertIn("usage", stderr)

    def test_サブコマンドの誤りも終了コード2(self) -> None:
        code, result, _ = self.run_main("publish", "--version", "1.1.0")

        self.assertEqual(code, 2)
        self.assertFalse(result["ok"])


class ImportTests(unittest.TestCase):
    def test_PyJWTをimportしない(self) -> None:
        self.assertNotIn("jwt", sys.modules)


if __name__ == "__main__":
    unittest.main()

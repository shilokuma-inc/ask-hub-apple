"""App Store Connect API の代わりに応答する、テスト用の偽物（ネットワークに出ない）。

`AppStoreConnect(urlopen=fake.urlopen, sleep=fake.sleeps.append)` のように差し替えて使う。
"""

from __future__ import annotations

import io
import json
import sys
import urllib.error
import urllib.parse
from email.message import Message
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

API = "https://api.appstoreconnect.apple.com"


class FakeResponse:
    def __init__(self, payload: dict | None):
        self._raw = json.dumps(payload).encode() if payload is not None else b""

    def read(self) -> bytes:
        return self._raw

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *exc) -> None:
        return None


def http_error(url: str, code: int, payload: dict | None = None,
               headers: dict | None = None) -> urllib.error.HTTPError:
    message = Message()
    for key, value in (headers or {}).items():
        message[key] = value
    body = io.BytesIO(json.dumps(payload or {"errors": [{"status": str(code)}]}).encode())
    return urllib.error.HTTPError(url, code, "error", message, body)


class FakeAppStoreConnect:
    """アプリ 1 つ・バージョン・ビルド・紐付けを持つ、App Store Connect の最小限の偽物。"""

    def __init__(self, bundle_id: str = "jp.example.App", page_size: int = 200):
        self.bundle_id = bundle_id
        self.app_id = "app-1"
        self.page_size = page_size
        #: id → appStoreVersions のリソース
        self.versions: dict[str, dict] = {}
        #: id → builds のリソース（attributes に platform・preReleaseVersion を持たせる）
        self.builds: dict[str, dict] = {}
        #: version id → build id
        self.attachments: dict[str, str] = {}
        #: 送られたリクエスト（method, path, query, payload）
        self.requests: list[tuple[str, str, dict, dict | None]] = []
        #: 先頭から順に返す、割り込みの失敗（HTTPError）
        self.failures: list[urllib.error.HTTPError] = []
        self.sleeps: list[float] = []
        self._next_id = 1

    # MARK: データの用意

    def add_version(self, platform: str, version_string: str, app_store_state: str,
                    app_version_state: str | None = None) -> str:
        version_id = f"ver-{self._next_id}"
        self._next_id += 1
        attributes = {"platform": platform, "versionString": version_string,
                      "appStoreState": app_store_state}
        if app_version_state is not None:
            attributes["appVersionState"] = app_version_state
        self.versions[version_id] = {"type": "appStoreVersions", "id": version_id, "attributes": attributes}
        return version_id

    def add_build(self, platform: str, version_string: str, build_number: str,
                  uploaded: str, state: str = "VALID", expired: bool = False) -> str:
        build_id = f"build-{self._next_id}"
        self._next_id += 1
        self.builds[build_id] = {
            "type": "builds", "id": build_id,
            "attributes": {"version": build_number, "uploadedDate": uploaded,
                           "processingState": state, "expired": expired},
            "_platform": platform, "_version": version_string,
        }
        return build_id

    def writes(self) -> list[tuple[str, str, dict | None]]:
        return [(method, path, payload) for method, path, _, payload in self.requests if method != "GET"]

    # MARK: urlopen の代わり

    def urlopen(self, request, timeout=None):
        url = request.full_url
        parsed = urllib.parse.urlparse(url)
        query = dict(urllib.parse.parse_qsl(parsed.query))
        payload = json.loads(request.data) if request.data else None
        self.requests.append((request.get_method(), parsed.path, query, payload))
        if not url.startswith(API):
            raise AssertionError(f"App Store Connect 以外に送ろうとしました: {url}")
        if request.get_header("Authorization") != "Bearer test-token":
            raise AssertionError("Authorization ヘッダーがありません")
        if self.failures:
            raise self.failures.pop(0)
        return FakeResponse(self._route(request.get_method(), parsed.path, query, payload, url))

    def _page(self, items: list[dict], query: dict, path: str) -> dict:
        offset = int(query.get("cursor", "0"))
        limit = min(int(query.get("limit", "200")), self.page_size)
        page = items[offset:offset + limit]
        links: dict = {}
        if offset + limit < len(items):
            next_query = {**query, "cursor": str(offset + limit)}
            links["next"] = f"{API}{path}?{urllib.parse.urlencode(next_query)}"
        return {"data": page, "links": links}

    def _route(self, method: str, path: str, query: dict, payload: dict | None, url: str) -> dict | None:
        parts = path.strip("/").split("/")
        if method == "GET" and path == "/v1/apps":
            apps = [{"type": "apps", "id": self.app_id,
                     "attributes": {"bundleId": self.bundle_id, "name": "Example"}}]
            return self._page([a for a in apps if a["attributes"]["bundleId"] == query.get("filter[bundleId]")],
                              query, path)
        if method == "GET" and parts[:2] == ["v1", "apps"] and parts[3:] == ["appStoreVersions"]:
            platform = query.get("filter[platform]")
            items = [v for v in self.versions.values()
                     if platform is None or v["attributes"]["platform"] == platform]
            return self._page(items, query, path)
        if method == "POST" and path == "/v1/appStoreVersions":
            attributes = payload["data"]["attributes"]
            version_id = self.add_version(attributes["platform"], attributes["versionString"],
                                          "PREPARE_FOR_SUBMISSION", "PREPARE_FOR_SUBMISSION")
            return {"data": self.versions[version_id]}
        if parts[:2] == ["v1", "appStoreVersions"] and len(parts) == 3:
            version = self.versions.get(parts[2])
            if version is None:
                raise http_error(url, 404)
            if method == "PATCH":
                version["attributes"].update(payload["data"]["attributes"])
            return {"data": version}
        if parts[:2] == ["v1", "appStoreVersions"] and parts[3:] == ["relationships", "build"]:
            if method == "PATCH":
                self.attachments[parts[2]] = payload["data"]["id"]
                return None
            build_id = self.attachments.get(parts[2])
            return {"data": {"type": "builds", "id": build_id} if build_id else None}
        if method == "GET" and path == "/v1/builds":
            items = [
                {k: v for k, v in b.items() if not k.startswith("_")} for b in self.builds.values()
                if b["_platform"] == query.get("filter[preReleaseVersion.platform]")
                and b["_version"] == query.get("filter[preReleaseVersion.version]")
                and b["attributes"]["processingState"] == query.get("filter[processingState]")
                and str(b["attributes"]["expired"]).lower() == query.get("filter[expired]")
            ]
            # 偽物は sort を無視する（クライアントが並べ直すことを確かめるため）
            return self._page(items, query, path)
        raise AssertionError(f"想定していないリクエスト: {method} {path}")

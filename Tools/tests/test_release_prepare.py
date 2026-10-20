"""Tools/release_prepare.py のテスト。git は一時ディレクトリのリポジトリで動かし、GitHub API は偽物に差し替える。"""

from __future__ import annotations

import contextlib
import datetime
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
import urllib.error
from email.message import Message
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import release_prepare  # noqa: E402
from release_prepare import Failure, GitHub, check_release, whats_new_text  # noqa: E402

XCCONFIG = """// バージョン
MARKETING_VERSION = 1.0.0 // 表示するバージョン
CURRENT_PROJECT_VERSION = 1
"""

LANGUAGES = {"languages": [{"language": "ja", "appleLanguage": "ja", "appleLocale": "ja_JP", "storeLocale": "ja"}]}

GIT_ENV = {
    "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.com",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
}


class Repo:
    """GitHub のマージコミットをまねた履歴を持つ、一時ディレクトリの git リポジトリ。"""

    def __init__(self, path: Path):
        self.path = path
        self.git("init", "-q", "-b", "develop")
        (path / "Configs").mkdir()
        (path / "Configs" / "Project.xcconfig").write_text(XCCONFIG, encoding="utf-8")
        (path / "AppStore").mkdir()
        (path / "AppStore" / "languages.json").write_text(json.dumps(LANGUAGES), encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "最初のコミット")

    def git(self, *args: str) -> str:
        env = {**os.environ, **GIT_ENV}
        return subprocess.run(["git", *args], cwd=self.path, env=env, check=True,
                              capture_output=True, text=True).stdout

    def commit(self, name: str) -> None:
        (self.path / f"{name}.txt").write_text(name, encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", name)

    def merge_pr(self, into: str, number: int, branch: str, title: str) -> None:
        """`branch` を into から切ってコミットし、GitHub と同じメッセージで into にマージする。"""
        self.git("checkout", "-q", "-B", branch, into)
        self.commit(branch.replace("/", "-"))
        self.git("checkout", "-q", into)
        self.git("merge", "-q", "--no-ff", branch, "-m", f"Merge pull request #{number} from org/{branch}", "-m", title)


class RepoTestCase(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Repo(Path(directory.name))


def fake_github(pulls: dict[int, dict], calls: list[str] | None = None, failures: list[Exception] | None = None):
    def urlopen(request, timeout=None):
        url = request.full_url
        assert url.startswith("https://api.github.com/repos/org/app/pulls/"), url
        assert request.get_header("Authorization") == "Bearer token"
        if calls is not None:
            calls.append(url)
        if failures:
            raise failures.pop(0)
        number = int(url.rsplit("/", 1)[1])
        if number not in pulls:
            raise urllib.error.HTTPError(url, 404, "not found", Message(), io.BytesIO(b"{}"))
        body = json.dumps(pulls[number]).encode()

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return None

        return Response(body)
    return urlopen


def rate_limited(url: str = "https://api.github.com/repos/org/app/pulls/1", retry_after: str | None = None):
    headers = Message()
    headers["X-RateLimit-Remaining"] = "0"
    if retry_after is not None:
        headers["Retry-After"] = retry_after
    return urllib.error.HTTPError(url, 403, "rate limited", headers, io.BytesIO(b"{}"))


# MARK: check


class CheckReleaseTests(unittest.TestCase):
    def test_新しいバージョンなら始めてよくMARKETING_VERSIONを書き換える(self) -> None:
        result = check_release("1.1.0", "1.0.0", [], ["v0.9.0"])

        self.assertTrue(result["ok"])
        self.assertEqual(result["branch"], "release/1.1.0")
        self.assertEqual(result["tag"], "v1.1.0")
        self.assertTrue(result["bumpVersion"])

    def test_タグがあれば止める(self) -> None:
        with self.assertRaisesRegex(Failure, "v1.1.0 がすでにあります"):
            check_release("1.1.0", "1.0.0", ["1.1.0"], ["v1.1.0"])

    def test_releaseブランチがあれば止める(self) -> None:
        with self.assertRaisesRegex(Failure, "resume"):
            check_release("1.1.0", "1.0.0", ["1.1.0"], [])

    def test_resumeならreleaseブランチの続きから行う(self) -> None:
        result = check_release("1.1.0", "1.1.0", ["1.1.0"], [], resume=True)

        self.assertTrue(result["ok"])
        self.assertTrue(result["resume"])
        self.assertFalse(result["bumpVersion"])

    def test_resumeでreleaseブランチが無ければ止める(self) -> None:
        with self.assertRaisesRegex(Failure, "ありません"):
            check_release("1.1.0", "1.0.0", [], [], resume=True)

    def test_タグの無いほかのreleaseブランチがあれば止める(self) -> None:
        with self.assertRaisesRegex(Failure, "release/1.0.5"):
            check_release("1.1.0", "1.0.0", ["1.0.5", "0.9.0"], ["v0.9.0"])

    def test_タグのあるreleaseブランチは終わったものとして数えない(self) -> None:
        result = check_release("1.2.0", "1.1.0", ["1.1.0"], ["v1.1.0"])

        self.assertTrue(result["ok"])

    def test_developと同じバージョンは止める(self) -> None:
        # ビルドはバージョンとプラットフォームだけで選ぶので、develop のビルドを紐付けうる（#621 のレビュー）
        with self.assertRaisesRegex(Failure, "見分けられません"):
            check_release("1.0.0", "1.0.0", [], [])

    def test_developより小さいバージョンは止める(self) -> None:
        with self.assertRaisesRegex(Failure, "より大きく"):
            check_release("0.9.0", "1.0.0", [], [])

    def test_リリース済みの最新より小さいバージョンは止める(self) -> None:
        with self.assertRaisesRegex(Failure, "v1.2.0"):
            check_release("1.1.0", "1.0.0", [], ["v1.2.0"])

    def test_developのMARKETING_VERSIONの形が違えば止める(self) -> None:
        with self.assertRaisesRegex(Failure, "形ではありません"):
            check_release("1.1.0", "1.0", [], [])


class MarketingVersionTests(RepoTestCase):
    def test_コメントを除いて読む(self) -> None:
        self.assertEqual(release_prepare.marketing_version(XCCONFIG), "1.0.0")
        self.assertIsNone(release_prepare.marketing_version("// MARKETING_VERSION = 9.9.9\n"))

    def test_書き換えるとコメントとほかの行は残る(self) -> None:
        path = self.repo.path / "Configs" / "Project.xcconfig"

        result = release_prepare.set_marketing_version(path, "1.1.0")

        self.assertTrue(result["changed"])
        self.assertEqual(result["previous"], "1.0.0")
        self.assertEqual(path.read_text(encoding="utf-8"), XCCONFIG.replace("= 1.0.0 //", "= 1.1.0 //"))

    def test_同じなら書き換えない(self) -> None:
        path = self.repo.path / "Configs" / "Project.xcconfig"

        result = release_prepare.set_marketing_version(path, "1.0.0")

        self.assertFalse(result["changed"])
        self.assertEqual(path.read_text(encoding="utf-8"), XCCONFIG)

    def test_行が1つでなければ止める(self) -> None:
        path = self.repo.path / "Configs" / "Project.xcconfig"
        path.write_text(XCCONFIG + "MARKETING_VERSION = 2.0.0\n", encoding="utf-8")

        with self.assertRaisesRegex(Failure, "1 つではありません"):
            release_prepare.set_marketing_version(path, "1.1.0")


class CheckCommandTests(RepoTestCase):
    def setUp(self) -> None:
        super().setUp()
        remote = self.repo.path / "remote.git"
        self.repo.git("init", "-q", "--bare", str(remote))
        self.repo.git("remote", "add", "origin", str(remote))
        self.repo.git("push", "-q", "origin", "develop")
        self.repo.git("fetch", "-q", "origin")

    def run_main(self, *args: str) -> tuple[int, dict]:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = release_prepare.main(["--root", str(self.repo.path), *args])
        return code, json.loads(stdout.getvalue())

    def test_リモートのrefsとdevelopのMARKETING_VERSIONを読む(self) -> None:
        code, result = self.run_main("check", "--version", "1.1.0")

        self.assertEqual(code, 0)
        self.assertEqual(result["developVersion"], "1.0.0")
        self.assertTrue(result["bumpVersion"])

    def test_リモートにreleaseブランチがあれば止める(self) -> None:
        self.repo.git("push", "-q", "origin", "develop:refs/heads/release/1.1.0")

        code, result = self.run_main("check", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        self.assertIn("release/1.1.0 がすでにあります", result["error"])

    def test_注釈付きのタグも見つける(self) -> None:
        self.repo.git("tag", "-a", "v1.1.0", "-m", "1.1.0")
        self.repo.git("push", "-q", "origin", "v1.1.0")

        code, result = self.run_main("check", "--version", "1.1.0")

        self.assertEqual(code, 1)
        self.assertIn("v1.1.0", result["error"])

    def test_バージョンの形が違えば終了コード2(self) -> None:
        code, result = self.run_main("check", "--version", "v1.1.0")

        self.assertEqual(code, 2)
        self.assertFalse(result["ok"])

    def test_引数の誤りは終了コード2でJSONを返す(self) -> None:
        code, result = self.run_main("check")

        self.assertEqual(code, 2)
        self.assertIn("引数の誤り", result["error"])


# MARK: draft


class WhatsNewTextTests(unittest.TestCase):
    def test_箇条書きにする(self) -> None:
        self.assertEqual(whats_new_text(["A", "B"]), ("・A\n・B", 0))

    def test_載せるものが無ければ決まった文にする(self) -> None:
        self.assertEqual(whats_new_text([]), (release_prepare.FALLBACK_TEXT, 0))

    def test_上限を超える分はほかN件にまとめる(self) -> None:
        text, omitted = whats_new_text(["あ" * 10] * 10, limit=40)

        self.assertLessEqual(len(text), 40)
        self.assertEqual(text, "・" + "あ" * 10 + "\n・" + "あ" * 10 + "\n・ほか 8 件")
        self.assertEqual(omitted, 8)

    def test_上限ちょうどまで載せる(self) -> None:
        titles = ["あ" * 10, "い" * 10]
        text, omitted = whats_new_text(titles, limit=len("・" + "あ" * 10 + "\n・" + "い" * 10))

        self.assertEqual(omitted, 0)
        self.assertEqual(text.count("\n"), 1)

    def test_本番の上限に収まる(self) -> None:
        text, omitted = whats_new_text([f"変更 {i} " + "あ" * 80 for i in range(200)])

        self.assertLessEqual(len(text), release_prepare.WHATS_NEW_LIMIT)
        self.assertGreater(omitted, 0)
        self.assertTrue(text.endswith(f"・ほか {omitted} 件"))


NOW = datetime.datetime(2026, 10, 20, 1, 2, 3, tzinfo=datetime.timezone.utc)


def build_draft(repo: Repo, pulls: dict[int, dict] | None = None, token: str | None = "token",
                failures: list[Exception] | None = None, calls: list[str] | None = None,
                version: str = "1.1.0") -> dict:
    github = GitHub("org/app", token, urlopen=fake_github(pulls or {}, calls, failures),
                    sleep=lambda seconds: None)
    return release_prepare.build_draft(repo.path, version, "org/app", "HEAD", github, now=NOW)


class DraftTests(unittest.TestCase):
    """同じ履歴を読むだけのテスト（git の操作は遅いので、履歴はクラスで 1 度だけ作る）。"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.directory = tempfile.TemporaryDirectory()
        cls.repo = Repo(Path(cls.directory.name))
        cls.build_history(cls.repo)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.directory.cleanup()

    @staticmethod
    def build_history(repo: Repo) -> None:
        """v1.0.0 のあとに、直接の PR・epic（子 PR 3 つ）・release の取り込み・develop の取り込みを積む。"""
        repo.git("tag", "v0.9.0")
        repo.merge_pr("develop", 1, "feat/old", "【FEAT】前のリリースに入った機能")
        repo.git("tag", "-a", "v1.0.0", "-m", "1.0.0")
        repo.merge_pr("develop", 2, "fix/issue-2-crash", "【FIX】起動時に落ちる不具合を直す")
        repo.git("checkout", "-q", "-b", "epic/inbox", "develop")
        repo.merge_pr("epic/inbox", 3, "feat/issue-3-filter", "【FEAT】受信箱を絞り込めるようにする")
        repo.merge_pr("epic/inbox", 4, "ci/issue-4-workflow", "【CI】ワークフローを足す")
        repo.merge_pr("develop", 5, "docs/readme", "【DOCS】README を直す")
        repo.git("checkout", "-q", "epic/inbox")
        repo.git("merge", "-q", "--no-ff", "develop", "-m", "Merge remote-tracking branch 'origin/develop' into HEAD")
        repo.merge_pr("epic/inbox", 6, "perf/issue-6-speed", "【PERF】一覧の表示を速くする")
        repo.git("checkout", "-q", "develop")
        repo.git("merge", "-q", "--no-ff", "epic/inbox", "-m", "Merge pull request #7 from org/epic/inbox",
                 "-m", "【FEAT】epic/inbox を develop に取り込む")
        repo.merge_pr("develop", 8, "release/1.0.0", "【CHORE】release/1.0.0 を develop に取り込む")
        repo.merge_pr("develop", 9, "hotfix-no-type", "種類の無いタイトル")

    def draft(self, pulls: dict[int, dict] | None = None, **options) -> dict:
        return build_draft(self.repo, pulls, **options)

    def test_前のタグからのPRをdevelopに入った順に並べepicは子PRに開く(self) -> None:
        draft = self.draft(token=None)

        self.assertEqual(draft["schemaVersion"], 1)
        self.assertEqual(draft["version"], "1.1.0")
        self.assertEqual(draft["generatedAt"], "2026-10-20T01:02:03Z")
        self.assertEqual(draft["base"]["tag"], "v1.0.0")
        self.assertFalse(draft["initial"])
        numbers = [pull["number"] for pull in draft["pullRequests"]]
        # develop に入った順。epic（#7）は、epic が入った位置で中の子 PR（#3・#4・#6）に開く。
        # release の取り込み（#8）と前のリリースの #1 は載せない
        self.assertEqual(numbers, [2, 5, 3, 4, 6, 9])
        by_number = {pull["number"]: pull for pull in draft["pullRequests"]}
        self.assertEqual(by_number[3]["epic"], 7)
        self.assertIsNone(by_number[2]["epic"])
        self.assertEqual(by_number[3]["title"], "受信箱を絞り込めるようにする")
        self.assertEqual(by_number[3]["type"], "FEAT")
        self.assertIsNone(by_number[9]["type"])
        self.assertEqual(by_number[2]["url"], "https://github.com/org/app/pull/2")
        self.assertEqual([pull["included"] for pull in draft["pullRequests"]],
                         [True, False, True, False, True, True])
        self.assertEqual(draft["whatsNew"], {
            "ja": "・起動時に落ちる不具合を直す\n・受信箱を絞り込めるようにする\n・一覧の表示を速くする\n・種類の無いタイトル",
        })
        self.assertIn("GH_TOKEN がありません", " ".join(draft["messages"]))

    def test_PRのタイトルはGitHubAPIの値を使う(self) -> None:
        calls: list[str] = []
        pulls = {2: {"title": "【FIX】起動直後に落ちる不具合を直す（タイトルを直した）",
                     "html_url": "https://github.com/org/app/pull/2", "merged_at": "2026-10-01T00:00:00Z"}}

        draft = self.draft(pulls, calls=calls)

        first = draft["pullRequests"][0]
        self.assertEqual(first["title"], "起動直後に落ちる不具合を直す（タイトルを直した）")
        self.assertEqual(first["mergedAt"], "2026-10-01T00:00:00Z")
        self.assertEqual(len(calls), 6)
        # 404 の PR はマージコミットのメッセージで続ける
        by_number = {pull["number"]: pull for pull in draft["pullRequests"]}
        self.assertEqual(by_number[3]["title"], "受信箱を絞り込めるようにする")

    def test_レート制限ならAPIをやめてマージコミットのメッセージを使う(self) -> None:
        calls: list[str] = []

        draft = self.draft({2: {"title": "使われない"}}, calls=calls, failures=[rate_limited()])

        self.assertEqual(len(calls), 1)
        self.assertEqual(draft["pullRequests"][0]["title"], "起動時に落ちる不具合を直す")
        self.assertIn("レート制限", " ".join(draft["messages"]))

    def test_短いRetryAfterは待って送り直す(self) -> None:
        calls: list[str] = []

        draft = self.draft({2: {"title": "【FIX】送り直して読めた"}}, calls=calls,
                           failures=[rate_limited(retry_after="1")])

        self.assertEqual(draft["pullRequests"][0]["title"], "送り直して読めた")
        self.assertEqual(len(calls), 7)

    def test_リリースより新しいタグは前のタグにしない(self) -> None:
        self.repo.git("tag", "v2.0.0")
        self.addCleanup(self.repo.git, "tag", "-d", "v2.0.0")

        draft = self.draft(token=None, version="1.1.0")

        self.assertEqual(draft["base"]["tag"], "v1.0.0")

    def test_draftのコマンドはファイルに書いて要約を出す(self) -> None:
        stdout = io.StringIO()
        environment = {key: value for key, value in os.environ.items() if key != "GH_TOKEN"}
        with unittest.mock.patch.dict(os.environ, environment, clear=True), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = release_prepare.main(["--root", str(self.repo.path), "draft", "--version", "1.1.0",
                                         "--repo", "org/app"])

        self.assertEqual(code, 0)
        summary = json.loads(stdout.getvalue())
        self.assertEqual(summary["output"], "AppStore/whats-new-draft.json")
        self.assertEqual(summary["included"], 4)
        written = json.loads((self.repo.path / "AppStore" / "whats-new-draft.json").read_text(encoding="utf-8"))
        self.assertEqual(written["version"], "1.1.0")
        self.assertEqual(set(written), {"schemaVersion", "version", "generatedAt", "base", "head", "initial",
                                        "whatsNew", "omitted", "pullRequests", "messages"})


class DraftEdgeTests(RepoTestCase):
    def draft(self, pulls: dict[int, dict] | None = None, **options) -> dict:
        return build_draft(self.repo, pulls, **options)

    def test_前のタグが無ければ初めてのリリースの本文にする(self) -> None:
        self.repo.merge_pr("develop", 2, "feat/a", "【FEAT】機能")

        draft = self.draft()

        self.assertTrue(draft["initial"])
        self.assertIsNone(draft["base"])
        self.assertEqual(draft["pullRequests"], [])
        self.assertEqual(draft["whatsNew"], {"ja": release_prepare.INITIAL_TEXT})

    def test_載せるPRが無ければ決まった文にする(self) -> None:
        self.repo.git("tag", "v1.0.0")
        self.repo.merge_pr("develop", 2, "ci/a", "【CI】ワークフロー")

        draft = self.draft(token=None)

        self.assertEqual(draft["whatsNew"], {"ja": release_prepare.FALLBACK_TEXT})
        self.assertEqual(len(draft["pullRequests"]), 1)


class ImportTests(unittest.TestCase):
    def test_外の依存をimportしない(self) -> None:
        self.assertNotIn("jwt", sys.modules)


if __name__ == "__main__":
    unittest.main()

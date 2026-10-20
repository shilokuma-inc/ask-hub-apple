"""Tools/release_sync.py のテスト。gh と release_app_store.py は偽物の runner に差し替え、ネットワークに出ない。"""

from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import release_sync  # noqa: E402
from release_sync import find_targets, finish_gate  # noqa: E402

from Tools.tests.test_release_prepare import Repo  # noqa: E402

REPO = "org/app"


def run(title: str, status: str = "completed", conclusion: str | None = "success", run_id: int = 1) -> dict:
    return {"id": run_id, "display_title": title, "status": status, "conclusion": conclusion,
            "html_url": f"https://github.com/{REPO}/actions/runs/{run_id}"}


def app_store_result(command: str, version: str, released: bool = False, ok: bool = True,
                     ios: str | None = None, mac: str = "platform-missing") -> dict:
    if ios is None:
        ios = ("released" if released else "not-released") if command == "status" else "already-attached"
    platforms = {"IOS": {"status": ios, "message": f"iOS: {ios}", "state": "READY_FOR_SALE" if released else "WAITING_FOR_REVIEW",
                         "build": {"buildNumber": "12"}},
                 "MAC_OS": {"status": mac, "message": f"macOS: {mac}"}}
    result = {"command": command, "ok": ok, "version": version, "platforms": platforms, "messages": []}
    if command == "status":
        result["released"] = released
    if not ok:
        result["error"] = f"{command} が失敗しました"
    return result


class FakeRunner:
    """release_app_store.py と gh の呼び出しをまねる。呼び出しを calls に残す。"""

    def __init__(self):
        self.calls: list[list[str]] = []
        self.app_store: dict = {}       # (command, version) → dict か、例外の文字列
        self.github: dict = {"runs": [], "pulls": [], "issues": []}
        self.github_errors: dict = {}   # "runs" などの → stderr
        self.dispatch_error: str | None = None

    def __call__(self, argv: list) -> subprocess.CompletedProcess:
        argv = [str(item) for item in argv]
        self.calls.append(argv)
        if argv[1].endswith("release_app_store.py"):
            command, version = argv[2], argv[4]
            value = self.app_store.get((command, version), app_store_result(command, version))
            if isinstance(value, str):
                return subprocess.CompletedProcess(argv, 1, value, "Traceback ...")
            return subprocess.CompletedProcess(argv, 0 if value.get("ok") else 1, json.dumps(value), "")
        if argv[:3] == ["gh", "api", "--paginate"]:
            path = argv[3]
            key = "runs" if "/actions/workflows/" in path else "pulls" if "/pulls?" in path else "issues"
            if key in self.github_errors:
                return subprocess.CompletedProcess(argv, 1, "", self.github_errors[key])
            lines = "".join(json.dumps(item) + "\n" for item in self.github[key])
            return subprocess.CompletedProcess(argv, 0, lines, "")
        if argv[:3] == ["gh", "workflow", "run"]:
            if self.dispatch_error:
                return subprocess.CompletedProcess(argv, 1, "", self.dispatch_error)
            return subprocess.CompletedProcess(argv, 0, "", "")
        raise AssertionError(f"思わぬ呼び出し: {argv}")

    def dispatches(self) -> list[list[str]]:
        return [call for call in self.calls if call[:3] == ["gh", "workflow", "run"]]

    def github_reads(self) -> list[list[str]]:
        return [call for call in self.calls if call[:2] == ["gh", "api"]]


# MARK: targets


class FindTargetsTests(unittest.TestCase):
    def test_タグの無いreleaseブランチだけを古い順に並べる(self) -> None:
        result = find_targets(["1.10.0", "1.2.0", "1.1.0"], ["v1.1.0", "v1.0.0"], "1.0.0")

        self.assertEqual(result["versions"], ["1.2.0", "1.10.0"])
        self.assertEqual(result["finished"], ["1.1.0"])
        self.assertEqual(result["warnings"], [])

    def test_形の違うreleaseブランチは見ずに知らせる(self) -> None:
        result = find_targets(["foo", "1.1", "1.1.0/fix"], [], "1.0.0")

        self.assertEqual(result["versions"], [])
        self.assertEqual([item["branch"] for item in result["ignored"]], ["release/foo", "release/1.1", "release/1.1.0/fix"])

    def test_releaseブランチが無ければ何もしない(self) -> None:
        result = find_targets([], ["v1.0.0"], "1.1.0")

        self.assertEqual(result["versions"], [])
        self.assertIn("何もしません", result["messages"][0])

    def test_初回にdevelopと同じバージョンなら取り違えの注意を出す(self) -> None:
        first = find_targets(["1.0.0"], [], "1.0.0")
        later = find_targets(["1.1.0"], ["v1.0.0"], "1.1.0")

        self.assertEqual(len(first["warnings"]), 1)
        self.assertIn("release ブランチから上がったもの", first["warnings"][0])
        self.assertEqual(later["warnings"], [])


class TargetsCommandTests(unittest.TestCase):
    def test_リモートのreleaseブランチとタグを読む(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "work").mkdir()
        repo = Repo(root / "work")
        repo.git("init", "-q", "--bare", str(root / "origin.git"))
        repo.git("remote", "add", "origin", str(root / "origin.git"))
        for branch in ("release/1.0.0", "release/1.1.0", "release-finish/1.1.0/pr-main", "feature/x"):
            repo.git("branch", branch)
        repo.git("tag", "-a", "v1.0.0", "-m", "1.0.0")
        repo.git("push", "-q", "origin", "--all")
        repo.git("push", "-q", "origin", "--tags")

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = release_sync.main(["--root", str(repo.path), "targets"])
        result = json.loads(stdout.getvalue())

        self.assertEqual(code, 0)
        self.assertEqual(result["versions"], ["1.1.0"])
        self.assertEqual(result["finished"], ["1.0.0"])
        self.assertEqual(result["ignored"], [])


# MARK: Release/Finish を起動してよいか


class FinishGateTests(unittest.TestCase):
    def gate(self, runs=(), pulls=(), issues=()) -> dict:
        return finish_gate("1.1.0", REPO, list(runs), list(pulls), list(issues))

    def test_runもPRもIssueも無ければ起動する(self) -> None:
        result = self.gate()

        self.assertTrue(result["start"])
        self.assertEqual(result["state"], "start")

    def test_実行中や待ちのrunがあれば二重に起動しない(self) -> None:
        for status in ("queued", "in_progress", "waiting", "requested", "pending"):
            result = self.gate(runs=[run("Release/Finish 1.1.0", status=status, conclusion=None)])
            self.assertEqual((result["start"], result["state"]), (False, "running"), status)

    def test_失敗したrunがあれば起動し直さない(self) -> None:
        for conclusion in ("failure", "cancelled", "timed_out"):
            result = self.gate(runs=[run("Release/Finish 1.1.0", conclusion=conclusion)])
            self.assertEqual((result["start"], result["state"]), (False, "failed"), conclusion)
            self.assertIn("手で起動し直して", result["message"])

    def test_成功したrunがあれば起動しない(self) -> None:
        result = self.gate(runs=[run("Release/Finish 1.1.0", conclusion="failure", run_id=1),
                                 run("Release/Finish 1.1.0", conclusion="success", run_id=2)])

        self.assertEqual((result["start"], result["state"]), (False, "finished"))

    def test_ほかのバージョンのrunは見ない(self) -> None:
        result = self.gate(runs=[run("Release/Finish 1.1.01", status="in_progress", conclusion=None),
                                 run("Release/Finish 1.0.0", conclusion="failure"),
                                 run("Release/Sync", status="in_progress", conclusion=None)])

        self.assertTrue(result["start"])

    def test_取り込み待ちのPRがあれば起動し直さない(self) -> None:
        for target in ("main", "develop"):
            pull = {"number": 10, "html_url": "https://github.com/org/app/pull/10",
                    "head": f"release-finish/1.1.0/pr-{target}", "headRepo": REPO}
            result = self.gate(pulls=[pull])
            self.assertEqual((result["start"], result["state"]), (False, "waiting-merge"), target)
            self.assertIn("pull/10", result["message"])

    def test_フォークの同じ名前のブランチのPRは見ない(self) -> None:
        pull = {"number": 10, "html_url": "u", "head": "release-finish/1.1.0/pr-main", "headRepo": "someone/app"}

        self.assertTrue(self.gate(pulls=[pull])["start"])

    def test_Release_Finishが作ったIssueがあれば起動し直さない(self) -> None:
        issue = {"number": 11, "html_url": "https://github.com/org/app/issues/11",
                 "title": "【CHORE】release/1.1.0 を develop に取り込めませんでした", "author": "github-actions[bot]"}

        result = self.gate(issues=[issue])

        self.assertEqual((result["start"], result["state"]), (False, "waiting-merge"))

    def test_ほかの人が作った同じタイトルのIssueは見ない(self) -> None:
        issue = {"number": 11, "html_url": "u", "title": "【CHORE】release/1.1.0 を main に取り込めませんでした",
                 "author": "someone"}

        self.assertTrue(self.gate(issues=[issue])["start"])

    def test_実行中のrunは取り込み待ちより先に知らせる(self) -> None:
        pull = {"number": 10, "html_url": "u", "head": "release-finish/1.1.0/pr-main", "headRepo": REPO}

        result = self.gate(runs=[run("Release/Finish 1.1.0", status="queued", conclusion=None)], pulls=[pull])

        self.assertEqual(result["state"], "running")


# MARK: sync


class SyncTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runner = FakeRunner()

    def sync(self, *versions: str) -> tuple[int, dict, str]:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        summary = Path(directory.name) / "summary.md"
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = release_sync.main(["sync", "--versions", ",".join(versions), "--repo", REPO,
                                      "--app-store-python", "/venv/bin/python", "--platforms", "IOS,MAC_OS",
                                      "--summary", str(summary)], runner=self.runner)
        return code, json.loads(stdout.getvalue()), summary.read_text(encoding="utf-8")

    def test_配信されていなければ紐付けと状態だけを見てGitHubは読まない(self) -> None:
        code, result, summary = self.sync("1.1.0")

        self.assertEqual(code, 0)
        commands = [call[2] for call in self.runner.calls]
        self.assertEqual(commands, ["attach-build", "status"])
        self.assertEqual(self.runner.calls[0][0], "/venv/bin/python")
        self.assertEqual(self.runner.calls[0][3:], ["--version", "1.1.0", "--platforms", "IOS,MAC_OS"])
        self.assertEqual(result["releases"][0]["finish"]["state"], "not-released")
        self.assertEqual(self.runner.github_reads(), [])
        self.assertIn("| `release/1.1.0` | iOS: 紐付け済み（ビルド 12）<br>macOS: プラットフォームなし |", summary)

    def test_配信されたらRelease_Finishをdevelopで起動する(self) -> None:
        self.runner.app_store[("status", "1.1.0")] = app_store_result("status", "1.1.0", released=True)

        code, result, summary = self.sync("1.1.0")

        self.assertEqual(code, 0)
        self.assertEqual(self.runner.dispatches(),
                         [["gh", "workflow", "run", "release-finish.yml", "--repo", REPO, "--ref", "develop",
                           "-f", "version=1.1.0"]])
        self.assertEqual(result["started"], ["1.1.0"])
        self.assertIn("**起動した**", summary)
        # 一覧はページングを最後までたどる
        self.assertTrue(all("--paginate" in call for call in self.runner.github_reads()))
        self.assertTrue(any(f"repos/{REPO}/actions/workflows/release-finish.yml/runs?per_page=100" in call
                            for call in self.runner.github_reads()))

    def test_実行中のrunがあれば起動しない(self) -> None:
        self.runner.app_store[("status", "1.1.0")] = app_store_result("status", "1.1.0", released=True)
        self.runner.github["runs"] = [run("Release/Finish 1.1.0", status="in_progress", conclusion=None)]

        code, result, _ = self.sync("1.1.0")

        self.assertEqual(code, 0)
        self.assertEqual(self.runner.dispatches(), [])
        self.assertEqual(result["releases"][0]["finish"]["state"], "running")

    def test_失敗したrunがあれば起動し直さない(self) -> None:
        self.runner.app_store[("status", "1.1.0")] = app_store_result("status", "1.1.0", released=True)
        self.runner.github["runs"] = [run("Release/Finish 1.1.0", conclusion="failure")]

        code, result, summary = self.sync("1.1.0")

        self.assertEqual(code, 0)
        self.assertEqual(self.runner.dispatches(), [])
        self.assertIn("失敗した run があるので起動し直さない", summary)
        self.assertIn("actions/runs/1", summary)

    def test_1つのreleaseブランチの失敗でほかを止めない(self) -> None:
        self.runner.app_store[("attach-build", "1.1.0")] = "壊れた出力"
        self.runner.app_store[("status", "1.1.0")] = app_store_result("status", "1.1.0", ok=False, ios="error")
        self.runner.app_store[("status", "1.2.0")] = app_store_result("status", "1.2.0", released=True)

        code, result, summary = self.sync("1.1.0", "1.2.0")

        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        first, second = result["releases"]
        self.assertFalse(first["ok"])
        self.assertEqual(len(first["errors"]), 2)
        self.assertIn("結果を読めませんでした", first["errors"][0])
        self.assertTrue(second["ok"])
        self.assertEqual(result["started"], ["1.2.0"])
        self.assertIn("release/1.1.0", result["error"])
        self.assertIn("| `release/1.1.0` | **失敗** |", summary)

    def test_状態を読めなかったら配信済みにしない(self) -> None:
        # status の JSON に released: true があっても ok: false なら起動しない
        status = app_store_result("status", "1.1.0", released=True, ok=False)
        self.runner.app_store[("status", "1.1.0")] = status

        code, result, _ = self.sync("1.1.0")

        self.assertEqual(code, 1)
        self.assertEqual(self.runner.dispatches(), [])
        self.assertFalse(result["releases"][0]["released"])

    def test_GitHubを読めなければ起動しない(self) -> None:
        self.runner.app_store[("status", "1.1.0")] = app_store_result("status", "1.1.0", released=True)
        self.runner.github_errors["runs"] = "gh: Not Found (HTTP 404)"

        code, result, _ = self.sync("1.1.0")

        self.assertEqual(code, 1)
        self.assertEqual(self.runner.dispatches(), [])
        self.assertEqual(result["releases"][0]["finish"]["state"], "error")
        self.assertIn("HTTP 404", result["releases"][0]["errors"][0])

    def test_一覧は1回だけ読んで使い回す(self) -> None:
        for version in ("1.1.0", "1.2.0"):
            self.runner.app_store[("status", version)] = app_store_result("status", version, released=True)

        self.sync("1.1.0", "1.2.0")

        self.assertEqual(len(self.runner.github_reads()), 3)
        self.assertEqual(len(self.runner.dispatches()), 2)

    def test_起動に失敗したら失敗にする(self) -> None:
        self.runner.app_store[("status", "1.1.0")] = app_store_result("status", "1.1.0", released=True)
        self.runner.dispatch_error = "could not create workflow dispatch event: HTTP 403"

        code, result, summary = self.sync("1.1.0")

        self.assertEqual(code, 1)
        self.assertEqual(result["releases"][0]["finish"]["state"], "error")
        self.assertIn("HTTP 403", summary)

    def test_メッセージの縦棒と改行は表を壊さない(self) -> None:
        status = app_store_result("status", "1.1.0", ok=False, ios="error")
        status["platforms"]["IOS"]["message"] = "a|b\nc"
        self.runner.app_store[("status", "1.1.0")] = status

        _, _, summary = self.sync("1.1.0")

        self.assertIn("a\\|b c", summary)

    def test_バージョンの形が違えば何も呼ばずに終了コード2(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = release_sync.main(["sync", "--versions", "1.1", "--repo", REPO], runner=self.runner)

        self.assertEqual(code, 2)
        self.assertFalse(json.loads(stdout.getvalue())["ok"])
        self.assertEqual(self.runner.calls, [])


if __name__ == "__main__":
    unittest.main()

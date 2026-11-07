"""Tools/commander_watch.py のテスト。gh は偽物の runner に差し替え、ネットワークに出ない。"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import commander_watch  # noqa: E402
from commander_watch import (  # noqa: E402
    ACTIONS_BOT,
    Failure,
    GitHub,
    assess,
    check,
    is_mac_name,
    parse_timestamp,
    plan,
    read_commander,
    recovered_body,
    render_workflow,
    watch_issues,
)

from Tools.tests.test_release_prepare import GIT_ENV  # noqa: E402

ROOT = TOOLS.parent
REPO = "org/askhub-state"
NOW = datetime(2026, 11, 7, 12, 0, 0, tzinfo=timezone.utc)


def stamp(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def commander_json(seen_at: datetime | str = NOW, **overrides) -> str:
    value = {
        "v": 1, "mac": "mac-mini", "seenAt": seen_at if isinstance(seen_at, str) else stamp(seen_at),
        "versions": {"commander": "1.0.0", "claude": "2.1.316"},
        "selfCheck": {"checkedAt": "2026-11-07T09:00:00Z", "keychain": "ok", "githubToken": "ok", "claudeToken": "ok"},
    }
    value.update(overrides)
    return json.dumps(value)


def issue(number: int, state: str = "open", phase: str | None = "down", author: str = ACTIONS_BOT, body: str | None = None) -> dict:
    if body is None:
        body = f"本文\n\n<!-- askhub-commander-watch v1 {phase} -->\n" if phase else "本文\n"
    return {"number": number, "state": state, "html_url": f"https://github.com/{REPO}/issues/{number}", "body": body, "author": author}


def completed(returncode: int = 0, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class FakeGh:
    """gh api の偽物。読み取りは commander・issues の値（または失敗の列）を返し、書き込みは記録する"""

    def __init__(self, commander: str | None = None, issues: list | None = None,
                 commander_failures: list | None = None, issue_failures: list | None = None, write_failure: bool = False,
                 assignable: tuple | None = None):
        self.commander = commander
        #: 割り当てられるアカウント（None なら頼んだとおりに割り当てる。GitHub は割り当てられない人を黙って外す）
        self.assignable = assignable
        self.issues = issues or []
        self.commander_failures = list(commander_failures or [])
        self.issue_failures = list(issue_failures or [])
        self.write_failure = write_failure
        self.calls: list = []
        self.writes: list = []

    def __call__(self, argv: list, stdin: str | None) -> subprocess.CompletedProcess:
        self.calls.append(argv)
        assert argv[:2] == ["gh", "api"], argv
        if "--method" in argv:
            method = argv[argv.index("--method") + 1]
            path = argv[argv.index("--method") + 2]
            assert argv[-2:] == ["--input", "-"], argv
            self.writes.append((method, path, json.loads(stdin)))
            if self.write_failure:
                return completed(1, stderr="gh: Resource not accessible by integration (HTTP 403)")
            fields = json.loads(stdin)
            assigned = [name for name in fields.get("assignees", []) if self.assignable is None or name in self.assignable]
            return completed(stdout=json.dumps({"number": 9, "html_url": f"https://github.com/{REPO}/issues/9",
                                                "assignees": [{"login": name} for name in assigned]}))
        if argv[-1] == f"repos/{REPO}/contents/commander.json":
            assert "Accept: application/vnd.github.raw+json" in argv
            if self.commander_failures:
                return self.commander_failures.pop(0)
            if self.commander is None:
                return completed(1, stdout='{"message":"Not Found"}', stderr="gh: Not Found (HTTP 404)")
            return completed(stdout=self.commander)
        if f"repos/{REPO}/issues?state=all&per_page=100" in argv:
            assert "--paginate" in argv
            if self.issue_failures:
                return self.issue_failures.pop(0)
            return completed(stdout="".join(json.dumps(entry) + "\n" for entry in self.issues))
        raise AssertionError(f"想定していない呼び出し: {argv}")


def run_check(fake: FakeGh, now: datetime = NOW, dry_run: bool = False, assignees: tuple = ()) -> dict:
    return check(REPO, GitHub(REPO, fake, sleep=lambda _: None), now, dry_run=dry_run, assignees=assignees)


class ReadCommanderTests(unittest.TestCase):
    def test_protocol_vectors(self) -> None:
        # AskHubKit の StateFileCoder と同じ結果になる（protocol/vectors/state/commander.json の read）
        vectors = json.loads((ROOT / "protocol/vectors/state/commander.json").read_text(encoding="utf-8"))
        self.assertTrue(vectors["cases"])
        for case in vectors["cases"]:
            with self.subTest(case["name"]):
                self.assertEqual(read_commander(json.dumps(case["value"]))["outcome"], case["read"])

    def test_identifier_vectors(self) -> None:
        vectors = json.loads((ROOT / "protocol/vectors/identifiers.json").read_text(encoding="utf-8"))
        for text in vectors["timestamp"]["valid"]:
            with self.subTest(timestamp=text):
                self.assertEqual(stamp(parse_timestamp(text)), text)
        for text in vectors["timestamp"]["invalid"]:
            with self.subTest(timestamp=text):
                self.assertIsNone(parse_timestamp(text))
        for text in vectors["macName"]["valid"]:
            with self.subTest(mac=text):
                self.assertTrue(is_mac_name(text))
        for text in vectors["macName"]["invalid"]:
            with self.subTest(mac=text):
                self.assertFalse(is_mac_name(text))

    def test_more_shapes(self) -> None:
        cases = {
            "": "notJSON",
            "{": "notJSON",
            '{"v": NaN}': "notJSON",
            "[]": "malformed",
            '{"v": null}': "missingVersion",
            '{"v": true}': "malformed",
            '{"v": 0}': "unsupportedVersion",
            commander_json("2026-02-30T00:00:00Z"): "malformed",
            commander_json(selfCheck={"checkedAt": "2026-11-07T09:00:00Z", "keychain": "ok", "githubToken": "unknown",
                                      "claudeToken": "ok"}): "malformed",
            commander_json(selfCheck={"checkedAt": "2026-11-07T09:00:00Z", "keychain": "ok", "githubToken": "ok",
                                      "claudeToken": "ok", "githubTokenExpiresAt": "あした"}): "malformed",
            commander_json(versions={"commander": "1.0.0", "claude": 2}): "malformed",
            commander_json(versions={"commander": "1.0.0", "claude": None}): "valid",
        }
        for text, outcome in cases.items():
            with self.subTest(text=text):
                self.assertEqual(read_commander(text)["outcome"], outcome)

    def test_valid_file(self) -> None:
        reading = read_commander(commander_json(NOW - timedelta(minutes=3)))
        self.assertEqual(reading["outcome"], "valid")
        self.assertEqual(reading["file"]["seenAt"], NOW - timedelta(minutes=3))
        self.assertEqual(reading["file"]["seenAtText"], "2026-11-07T11:57:00Z")


class AssessTests(unittest.TestCase):
    def test_states(self) -> None:
        cases = {
            "missing": None,
            "unreadable": '{"v": 2}',
            "alive": commander_json(NOW - timedelta(minutes=12)),
            # AskHubKit の isOlder と同じく、ちょうど 30 分は古いとみなさない
            "alive-boundary": commander_json(NOW - timedelta(minutes=30)),
            "stale": commander_json(NOW - timedelta(minutes=30, seconds=1)),
            "alive-slightly-ahead": commander_json(NOW + timedelta(minutes=5)),
            "future": commander_json(NOW + timedelta(minutes=5, seconds=1)),
        }
        for name, text in cases.items():
            with self.subTest(name):
                self.assertEqual(assess(text, NOW)["state"], name.split("-")[0])

    def test_unreadable_has_reason(self) -> None:
        status = assess('{"v": 2}', NOW)
        self.assertEqual(status["outcome"], "unsupportedVersion")
        self.assertIn("v: 2", status["problem"])


class WatchIssueTests(unittest.TestCase):
    def test_selects_only_bot_issues_with_marker_on_last_line(self) -> None:
        issues = [
            issue(5, phase="recovered", state="closed"),
            issue(3),
            # 人が目印をまねても見張りの Issue とみなさない
            issue(4, author="someone"),
            issue(6, phase=None),
            # 引用などで途中にある目印は読まない
            issue(7, body="<!-- askhub-commander-watch v1 down -->\n\nあとがき\n"),
            issue(8, body="<!-- askhub-commander-watch v1 down --> と書く\n"),
        ]
        found = watch_issues(issues)
        self.assertEqual([(entry["number"], entry["phase"]) for entry in found], [(3, "down"), (5, "recovered")])

    def test_plan(self) -> None:
        alive = {"state": "alive"}
        stale = {"state": "stale"}
        open_down = watch_issues([issue(3)])
        closed_down = watch_issues([issue(3, state="closed")])
        recovered = watch_issues([issue(3, state="closed", phase="recovered")])
        self.assertEqual([step["action"] for step in plan(alive, open_down)], ["recover"])
        self.assertEqual([step["action"] for step in plan(alive, closed_down)], ["recover"])
        self.assertEqual(plan(alive, recovered), [])
        self.assertEqual(plan(alive, []), [])
        # まだ戻っていない Issue があれば、開いていても人が閉じていても重ねない
        self.assertEqual([step["action"] for step in plan(stale, open_down)], ["notified"])
        self.assertEqual([step["action"] for step in plan(stale, closed_down)], ["notified"])
        self.assertEqual([step["action"] for step in plan(stale, recovered)], ["open"])
        self.assertEqual([step["action"] for step in plan({"state": "missing"}, [])], ["open"])

    def test_recovered_body(self) -> None:
        self.assertEqual(recovered_body("本文\n\n<!-- askhub-commander-watch v1 down -->\n\n"),
                         "本文\n\n<!-- askhub-commander-watch v1 recovered -->\n")


class CheckTests(unittest.TestCase):
    def test_missing_opens_issue(self) -> None:
        fake = FakeGh(commander=None)
        result = run_check(fake)
        self.assertEqual(result["state"], "missing")
        self.assertEqual(result["actions"], [{"action": "open", "number": 9, "url": f"https://github.com/{REPO}/issues/9"}])
        [(method, path, fields)] = fake.writes
        self.assertEqual((method, path), ("POST", f"repos/{REPO}/issues"))
        self.assertIn("commander.json", fields["title"])
        self.assertTrue(fields["body"].rstrip().endswith("<!-- askhub-commander-watch v1 down -->"))
        # 立てた Issue は、次の run で見張りの Issue として読める
        self.assertEqual(watch_issues([{**issue(9), "body": fields["body"]}])[0]["phase"], "down")

    def test_without_assignees_does_not_assign(self) -> None:
        fake = FakeGh(commander=None)
        run_check(fake)
        [(_, _, fields)] = fake.writes
        self.assertNotIn("assignees", fields)

    def test_assigns_issue_for_mobile_push(self) -> None:
        fake = FakeGh(commander=None)
        result = run_check(fake, assignees=("octocat",))
        [(_, _, fields)] = fake.writes
        self.assertEqual(fields["assignees"], ["octocat"])
        self.assertEqual(result["assignees"], ["octocat"])
        self.assertEqual(len(result["messages"]), 1)

    def test_warns_when_github_drops_assignee(self) -> None:
        # 割り当てられない人は GitHub が黙って外すので、Job Summary に出して気づけるようにする
        fake = FakeGh(commander=None, assignable=("octocat",))
        result = run_check(fake, assignees=("octocat", "someone"))
        self.assertTrue(result["ok"])
        self.assertIn("someone", result["messages"][-1])
        self.assertNotIn("octocat", result["messages"][-1])

    def test_dry_run_and_recovery_do_not_assign(self) -> None:
        fake = FakeGh(commander=None)
        run_check(fake, dry_run=True, assignees=("octocat",))
        self.assertEqual(fake.writes, [])

    def test_parse_assignees(self) -> None:
        self.assertEqual(commander_watch.parse_assignees(""), ())
        self.assertEqual(commander_watch.parse_assignees(" octocat, hubot  Octocat "), ("octocat", "hubot"))
        for text in ["-octocat", "octo--cat", "x" * 40, "octo;rm", "@octocat"]:
            with self.assertRaises(commander_watch.UsageError, msg=text):
                commander_watch.parse_assignees(text)
        with self.assertRaises(commander_watch.UsageError):
            commander_watch.parse_assignees(",".join(f"user{i}" for i in range(11)))

    def test_stale_issue_shows_last_seen(self) -> None:
        fake = FakeGh(commander=commander_json(NOW - timedelta(minutes=47)))
        result = run_check(fake)
        self.assertEqual((result["state"], result["ageMinutes"], result["mac"]), ("stale", 47, "mac-mini"))
        [(_, _, fields)] = fake.writes
        self.assertIn("30 分より長く", fields["title"])
        self.assertIn("47 分更新されていません", fields["body"])
        self.assertIn("2026-11-07T11:13:00Z（47 分前）", fields["body"])
        self.assertIn("司令塔 1.0.0・Claude Code 2.1.316", fields["body"])
        self.assertIn("launchctl print gui/$(id -u)/jp.shilokuma.askhub.commander", fields["body"])

    def test_versions_do_not_break_table(self) -> None:
        fake = FakeGh(commander=commander_json(NOW - timedelta(minutes=47), versions={"commander": "1.0 | x\ny" + "9" * 60}))
        run_check(fake)
        line = next(line for line in fake.writes[0][2]["body"].splitlines() if line.startswith("| 版 |"))
        self.assertTrue(line.startswith("| 版 | 司令塔 1.0 \\| x y999"))
        # 列の区切り（逃がしていない |）は 3 つだけ
        self.assertEqual(len(re.findall(r"(?<!\\)\|", line)), 3)

    def test_future_and_unreadable_issues(self) -> None:
        fake = FakeGh(commander=commander_json(NOW + timedelta(minutes=20)))
        self.assertEqual(run_check(fake)["state"], "future")
        self.assertIn("20 分先の時刻", fake.writes[0][2]["body"])
        self.assertIn("20 分先", fake.writes[0][2]["body"])
        fake = FakeGh(commander='{"v": 2}')
        result = run_check(fake)
        self.assertEqual((result["state"], result["outcome"]), ("unreadable", "unsupportedVersion"))
        self.assertIn("unsupportedVersion", fake.writes[0][2]["body"])

    def test_already_notified_does_not_write(self) -> None:
        for state in ("open", "closed"):
            with self.subTest(state):
                fake = FakeGh(commander=None, issues=[issue(3, state=state)])
                result = run_check(fake)
                self.assertEqual(fake.writes, [])
                self.assertEqual([entry["action"] for entry in result["actions"]], ["notified"])

    def test_alive_closes_open_issue(self) -> None:
        fake = FakeGh(commander=commander_json(NOW - timedelta(minutes=2)), issues=[issue(3), issue(1, phase="recovered", state="closed")])
        result = run_check(fake)
        self.assertEqual(result["state"], "alive")
        self.assertEqual(result["actions"][0]["closed"], True)
        (comment_method, comment_path, comment), (patch_method, patch_path, fields) = fake.writes
        self.assertEqual((comment_method, comment_path), ("POST", f"repos/{REPO}/issues/3/comments"))
        self.assertIn("司令塔が戻りました（`seenAt`: 2026-11-07T11:58:00Z", comment["body"])
        self.assertIn("閉じます", comment["body"])
        self.assertEqual((patch_method, patch_path), ("PATCH", f"repos/{REPO}/issues/3"))
        self.assertEqual((fields["state"], fields["state_reason"]), ("closed", "completed"))
        self.assertTrue(fields["body"].endswith("<!-- askhub-commander-watch v1 recovered -->\n"))

    def test_alive_marks_closed_issue_recovered(self) -> None:
        # 戻る前に人が閉じた Issue は、閉じたまま目印だけを recovered にする（次に止まったら新しく立てる）
        fake = FakeGh(commander=commander_json(), issues=[issue(3, state="closed")])
        run_check(fake)
        (_, _, comment), (_, _, fields) = fake.writes
        self.assertNotIn("閉じます", comment["body"])
        self.assertEqual(set(fields), {"body"})

    def test_alive_without_issues_does_nothing(self) -> None:
        fake = FakeGh(commander=commander_json(), issues=[issue(1, phase="recovered", state="closed")])
        result = run_check(fake)
        self.assertEqual((result["actions"], fake.writes), ([], []))

    def test_dry_run_does_not_write(self) -> None:
        for fake in (FakeGh(commander=None), FakeGh(commander=commander_json(), issues=[issue(3)])):
            with self.subTest(fake.commander):
                result = run_check(fake, dry_run=True)
                self.assertEqual(fake.writes, [])
                self.assertTrue(result["dryRun"])
                self.assertIn("--dry-run", result["messages"][0])

    def test_read_retries_then_succeeds(self) -> None:
        sleeps: list = []
        fake = FakeGh(commander=commander_json(), commander_failures=[completed(1, stderr="gh: Bad Gateway (HTTP 502)")],
                      issue_failures=[completed(1, stderr="gh: Server Error (HTTP 500)")])
        result = check(REPO, GitHub(REPO, fake, sleep=sleeps.append), NOW)
        self.assertEqual(result["state"], "alive")
        self.assertEqual(sleeps, [5, 5])

    def test_read_failure_raises(self) -> None:
        failures = [completed(1, stderr="gh: Bad Gateway (HTTP 502)")] * 3
        with self.assertRaisesRegex(Failure, "commander.json を読めませんでした: gh: Bad Gateway"):
            check(REPO, GitHub(REPO, FakeGh(commander_failures=failures), sleep=lambda _: None), NOW)
        # 一覧が読めないときは Issue を立てない（重ねて立てないため）
        fake = FakeGh(commander=None, issue_failures=[completed(1, stderr="gh: Not Found (HTTP 404)")])
        with self.assertRaisesRegex(Failure, "Issue の一覧を読めませんでした"):
            check(REPO, GitHub(REPO, fake, sleep=lambda _: None), NOW)
        self.assertEqual(fake.writes, [])

    def test_write_failure_raises(self) -> None:
        with self.assertRaisesRegex(Failure, "見張りの Issue を立てられませんでした: gh: Resource not accessible"):
            run_check(FakeGh(commander=None, write_failure=True))


class MainTests(unittest.TestCase):
    def run_main(self, argv: list, fake: FakeGh) -> tuple[int, dict]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = commander_watch.main(argv, runner=fake, now=NOW)
        return code, json.loads(stdout.getvalue())

    def test_check_writes_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.md"
            code, result = self.run_main(["check", "--repo", REPO, "--summary", str(summary)],
                                         FakeGh(commander=commander_json(NOW - timedelta(minutes=47))))
            self.assertEqual((code, result["ok"], result["command"]), (0, True, "check"))
            text = summary.read_text(encoding="utf-8")
            self.assertIn("| 様子 | 印が古い |", text)
            self.assertIn("2026-11-07T11:13:00Z（47 分前）", text)
            self.assertIn(f"[見張りの Issue を立てた（#9）](https://github.com/{REPO}/issues/9)", text)

    def test_exit_codes(self) -> None:
        code, result = self.run_main(["check", "--repo", REPO], FakeGh(commander=None, write_failure=True))
        self.assertEqual((code, result["ok"]), (1, False))
        code, result = self.run_main(["check", "--repo", "not a repo"], FakeGh())
        self.assertEqual((code, result["ok"]), (2, False))
        code, result = self.run_main(["check"], FakeGh())
        self.assertEqual((code, result["ok"]), (2, False))


class SwiftConsistencyTests(unittest.TestCase):
    """判定の値が AskHubKit の値とずれていないか"""

    def swift(self, path: str) -> str:
        return (ROOT / "AskHubKit/Sources" / path).read_text(encoding="utf-8")

    def test_stale_after_matches_mac_stale_after(self) -> None:
        match = re.search(r"var macStaleAfter: Duration = \.seconds\((\d+) \* 60\)", self.swift("AskHubJobs/AttemptLiveness.swift"))
        self.assertIsNotNone(match, "JobTiming.macStaleAfter が見つからない（書き方が変わったらこのテストを直す）")
        self.assertEqual(timedelta(minutes=int(match.group(1))), commander_watch.STALE_AFTER)

    def test_heartbeat_interval(self) -> None:
        match = re.search(r"heartbeatInterval: Duration = \.seconds\((\d+) \* 60\)", self.swift("AskHubCommander/CommanderLoop.swift"))
        self.assertIsNotNone(match)
        self.assertEqual(timedelta(minutes=int(match.group(1))), commander_watch.HEARTBEAT_INTERVAL)
        self.assertLess(commander_watch.HEARTBEAT_INTERVAL, commander_watch.STALE_AFTER)

    def test_launch_agent_label_and_paths(self) -> None:
        self.assertIn(f'label = "{commander_watch.LAUNCH_AGENT_LABEL}"', self.swift("AskHubCommander/LaunchAgent.swift"))
        configuration = self.swift("AskHubCommander/CommanderConfiguration.swift")
        self.assertIn('"Library/Logs/AskHub"', configuration)
        self.assertIn('"commander.log"', configuration)
        self.assertIn(f'commander = "{commander_watch.COMMANDER_PATH}"', self.swift("AskHubProtocol/StatePath.swift"))


class WorkflowTemplateTests(unittest.TestCase):
    def template(self) -> str:
        return (ROOT / commander_watch.WORKFLOW_TEMPLATE).read_text(encoding="utf-8")

    def test_template(self) -> None:
        text = self.template()
        self.assertEqual(text.count(commander_watch.WORKFLOW_REF_PLACEHOLDER), 1)
        self.assertIn(f"sparse-checkout: {commander_watch.SCRIPT_PATH}", text)
        self.assertIn(f"python3 ask-hub-apple/{commander_watch.SCRIPT_PATH} ", text)
        # GITHUB_TOKEN だけを使い、権限は最小にする
        self.assertNotIn("secrets.", text)
        self.assertIn("permissions: {}", text)
        job_permissions = re.findall(r"^      (\w[\w-]*): (\w+)", text.split("    permissions:\n", 1)[1], re.MULTILINE)
        self.assertEqual(job_permissions[:2], [("contents", "read"), ("issues", "write")])
        self.assertIn("persist-credentials: false", text)
        # 割り当てるアカウントは公開のコードに書かず、状態リポジトリの変数から環境変数で渡す（run の中に式を埋め込まない）
        self.assertIn("ASSIGNEES: ${{ vars.COMMANDER_WATCH_ASSIGNEES }}", text)
        self.assertIn('--assignees "${ASSIGNEES:-}"', text)

    def test_render(self) -> None:
        sha = "0123456789abcdef0123456789abcdef01234567"
        rendered = render_workflow(self.template(), sha)
        self.assertIn(f"ref: {sha}", rendered)
        self.assertNotIn(commander_watch.WORKFLOW_REF_PLACEHOLDER, rendered)
        with self.assertRaises(commander_watch.UsageError):
            render_workflow(self.template(), "renewal")
        with self.assertRaises(Failure):
            render_workflow("ref: x\n", sha)


class RenderWorkflowCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name) / "repo"
        self.root.mkdir()
        self.output = Path(directory.name) / "commander-watch.yml"
        self.git("init", "-q", "-b", "renewal")
        (self.root / "Tools/askhub-state").mkdir(parents=True)
        (self.root / commander_watch.SCRIPT_PATH).write_text("# 判定\n", encoding="utf-8")
        (self.root / commander_watch.WORKFLOW_TEMPLATE).write_text("ref: __ASK_HUB_APPLE_SHA__\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "見張り")
        self.sha = self.git("rev-parse", "HEAD").strip()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, env={**os.environ, **GIT_ENV}, check=True,
                              capture_output=True, text=True).stdout

    def run_main(self, *argv: str) -> tuple[int, dict]:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            code = commander_watch.main(["render-workflow", "--root", str(self.root), "--output", str(self.output), *argv])
        return code, json.loads(stdout.getvalue())

    def test_requires_remote_branch(self) -> None:
        code, result = self.run_main("--ref", "HEAD")
        self.assertEqual(code, 1)
        self.assertIn("リモートのブランチに入っていません", result["error"])
        self.assertFalse(self.output.exists())

    def test_renders_template_of_that_commit(self) -> None:
        self.git("update-ref", "refs/remotes/origin/renewal", "HEAD")
        # 作業ツリーの雛形が変わっていても、指定したコミットの雛形を使う
        (self.root / commander_watch.WORKFLOW_TEMPLATE).write_text("changed: __ASK_HUB_APPLE_SHA__\n", encoding="utf-8")
        code, result = self.run_main("--ref", "origin/renewal")
        self.assertEqual((code, result["sha"]), (0, self.sha))
        self.assertEqual(self.output.read_text(encoding="utf-8"), f"ref: {self.sha}\n")

    def test_rejects_commit_without_watcher(self) -> None:
        self.git("rm", "-q", commander_watch.SCRIPT_PATH)
        self.git("commit", "-q", "-m", "消す")
        self.git("update-ref", "refs/remotes/origin/renewal", "HEAD")
        code, result = self.run_main("--ref", "origin/renewal")
        self.assertEqual(code, 1)
        self.assertIn("Tools/commander_watch.py がありません", result["error"])

    def test_rejects_unknown_ref(self) -> None:
        code, result = self.run_main("--ref", "origin/nothing")
        self.assertEqual(code, 1)
        self.assertIn("コミットとして読めません", result["error"])
        code, _ = self.run_main("--ref", "--help")
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()

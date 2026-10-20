"""Tools/release_finish.py のテスト。git は一時ディレクトリのリポジトリで動かし、リモートの refs は update-ref でまねる。"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import release_finish  # noqa: E402
from release_prepare import DRAFT_FILE, FALLBACK_TEXT, Failure  # noqa: E402

from Tools.tests.test_release_prepare import Repo  # noqa: E402


class FinishRepo(Repo):
    """release ブランチを切り、リモートの refs（refs/remotes/origin/*）を手で動かすリポジトリ。"""

    def sha(self, ref: str = "HEAD") -> str:
        return self.git("rev-parse", ref).strip()

    def publish(self, *branches: str) -> None:
        """ローカルのブランチを origin に push したことにする。"""
        for branch in branches:
            self.git("update-ref", f"refs/remotes/origin/{branch}", self.sha(branch))

    def cut_release(self, version: str = "1.1.0", message: str = "[chore] MARKETING_VERSION を 1.1.0 にする") -> str:
        self.git("checkout", "-q", "-b", f"release/{version}", "develop")
        self.commit_file("Configs/Project.xcconfig", f"MARKETING_VERSION = {version}\n", message)
        self.git("checkout", "-q", "develop")
        self.publish("develop", f"release/{version}")
        return self.sha(f"release/{version}")

    def commit_file(self, name: str, text: str, message: str) -> None:
        path = self.path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", message)

    def merge_into(self, target: str, branch: str) -> str:
        self.git("checkout", "-q", target)
        self.git("merge", "-q", "--no-ff", branch, "-m", f"Merge branch '{branch}' into {target}")
        self.git("checkout", "-q", "develop")
        self.publish(target)
        return self.sha(target)


class FinishTestCase(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = FinishRepo(Path(directory.name))

    def check(self, version: str = "1.1.0") -> dict:
        return release_finish.check_finish(self.repo.path, version)


class CheckTests(FinishTestCase):
    def test_initial_release_creates_main(self):
        release = self.repo.cut_release()
        result = self.check()
        self.assertEqual((result["main"], result["tagState"], result["develop"]), ("create", "create", "merge"))
        self.assertTrue(result["initial"])
        self.assertTrue(result["pending"])
        self.assertEqual(result["releaseSha"], release)
        self.assertIsNone(result["mainSha"])

    def test_second_release_merges_into_main(self):
        self.repo.cut_release()
        self.repo.git("branch", "main", "release/1.1.0")
        self.repo.publish("main")
        self.repo.merge_into("develop", "release/1.1.0")
        self.repo.git("tag", "v1.1.0", "main")
        self.repo.commit("next")
        self.repo.publish("develop")
        self.repo.cut_release("1.2.0", "[chore] MARKETING_VERSION を 1.2.0 にする")
        result = self.check("1.2.0")
        self.assertEqual((result["main"], result["tagState"], result["develop"]), ("merge", "create", "merge"))
        self.assertFalse(result["initial"])

    def test_rerun_skips_finished_steps(self):
        self.repo.cut_release()
        self.repo.git("branch", "main", "release/1.1.0")
        self.repo.publish("main")
        self.repo.git("tag", "v1.1.0", "main")
        result = self.check()
        # develop への取り込みだけが残っている（前の run がそこで止まった）
        self.assertEqual((result["main"], result["tagState"], result["develop"]), ("done", "done", "merge"))
        self.assertTrue(result["pending"])
        self.assertFalse(result["developVersionBump"])
        self.repo.merge_into("develop", "release/1.1.0")
        # 人が PR をマージした後: develop は 1.1.0 のままなので、次のパッチにするコミットが残っている
        result = self.check()
        self.assertEqual(result["develop"], "done")
        self.assertTrue(result["developVersionBump"])
        self.assertTrue(result["pending"])
        self.assertIn("1.1.1", result["messages"][3])
        self.repo.commit_file("Configs/Project.xcconfig", "MARKETING_VERSION = 1.1.1\n", "[chore] MARKETING_VERSION を 1.1.1 にする")
        self.repo.publish("develop")
        result = self.check()
        self.assertFalse(result["developVersionBump"])
        self.assertFalse(result["pending"])

    def test_release_advanced_after_tag_merges_into_develop_only(self):
        self.repo.cut_release()
        self.repo.git("branch", "main", "release/1.1.0")
        self.repo.publish("main")
        self.repo.git("tag", "v1.1.0", "main")
        # タグを打った後に、人が release ブランチでコンフリクトを解いた（前の案内どおり）
        self.repo.git("checkout", "-q", "release/1.1.0")
        self.repo.commit_file("resolve.txt", "resolve", "Merge branch 'develop' into release/1.1.0")
        self.repo.git("checkout", "-q", "develop")
        self.repo.publish("release/1.1.0")
        result = self.check()
        self.assertEqual((result["main"], result["tagState"], result["develop"]), ("done", "done", "merge"))
        self.assertTrue(result["releaseAdvanced"])
        self.assertIn("develop にだけ取り込みます", result["messages"][-1])

    def test_missing_release_branch(self):
        with self.assertRaisesRegex(Failure, "release/1.1.0 がありません"):
            self.check()

    def test_tag_without_release_head(self):
        self.repo.cut_release()
        self.repo.git("tag", "v1.1.0", "develop")
        with self.assertRaisesRegex(Failure, "含まず、このリリースを main に取り込んだコミットでもありません"):
            self.check()

    def test_tag_without_release_head_off_main(self):
        self.repo.cut_release()
        self.repo.git("branch", "main", "release/1.1.0")
        self.repo.publish("main")
        self.repo.git("tag", "v1.1.0", "develop")
        with self.assertRaisesRegex(Failure, "含まず、このリリースを main に取り込んだコミットでもありません"):
            self.check()

    def test_tag_without_main(self):
        self.repo.cut_release()
        self.repo.git("tag", "v1.1.0", "release/1.1.0")
        with self.assertRaisesRegex(Failure, "main に入っていません"):
            self.check()

    def test_ai_attribution_on_release_branch(self):
        self.repo.cut_release()
        self.repo.git("checkout", "-q", "release/1.1.0")
        self.repo.commit_file("fix.txt", "fix", "[fix] 直す\n\nco-authored-by: someone <noreply@example.com>")
        self.repo.git("checkout", "-q", "develop")
        self.repo.publish("release/1.1.0")
        with self.assertRaisesRegex(Failure, "AI 帰属行があります"):
            self.check()

    def test_ai_attribution_already_in_develop_is_ignored(self):
        # develop に入ったコミットは PR の検査を通っている（検査ができる前の履歴は見ない）
        self.repo.commit_file("old.txt", "old", "古い\n\nGenerated with [Claude Code](https://claude.com)")
        self.repo.publish("develop")
        self.repo.cut_release()
        self.assertEqual(self.check()["main"], "create")


class AttributionTests(FinishTestCase):
    def test_same_patterns_as_workflow(self):
        for message in ("x\n\nCo-Authored-By: a <b>", "x\n\nGenerated with [Claude Code](u)", "x <noreply@anthropic.com>"):
            self.assertRegex(message, release_finish.AI_ATTRIBUTION)
        # 行頭でなければ Co-Authored-By は当たらない
        self.assertNotRegex("x\n\n> Co-Authored-By: a", release_finish.AI_ATTRIBUTION)


class TagTargetTests(FinishTestCase):
    def test_initial_main_is_release_head(self):
        release = self.repo.cut_release()
        self.repo.git("branch", "main", "release/1.1.0")
        self.assertEqual(release_finish.tag_target(self.repo.path, release, self.repo.sha("main")), release)

    def test_merge_commit_on_main(self):
        self.repo.git("branch", "main", "develop")
        self.repo.commit("feature")
        release = self.repo.cut_release()
        merge = self.repo.merge_into("main", "release/1.1.0")
        # 取り込んだ後に main が進んでも、取り込んだマージコミットに打つ
        self.repo.git("checkout", "-q", "main")
        self.repo.commit("hotfix")
        self.repo.git("checkout", "-q", "develop")
        self.assertEqual(release_finish.tag_target(self.repo.path, release, self.repo.sha("main")), merge)

    def test_release_not_in_main(self):
        self.repo.git("branch", "main", "develop")
        release = self.repo.cut_release()
        with self.assertRaises(Failure):
            release_finish.tag_target(self.repo.path, release, self.repo.sha("main"))


class NotesTests(FinishTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.repo.commit_file("AppStore/metadata/ja.json", json.dumps({"description": "説明"}), "メタデータ")

    def write_whats_new(self, version: str, text: str) -> None:
        path = self.repo.path / "AppStore/metadata/ja.json"
        path.write_text(json.dumps({"description": "説明", "whatsNew": {"version": version, "text": text}}), encoding="utf-8")

    def body(self, version: str = "1.1.0") -> dict:
        return release_finish.release_body(self.repo.path, version, "org/app")

    def test_confirmed_whats_new(self):
        self.write_whats_new("1.1.0", " ・受信箱を絞り込めるようにする\n")
        result = self.body()
        self.assertEqual(result["source"], "whatsNew")
        self.assertEqual(result["body"], "・受信箱を絞り込めるようにする\n")

    def test_whats_new_of_previous_version_falls_back_to_draft(self):
        self.write_whats_new("1.0.0", "前の本文")
        (self.repo.path / DRAFT_FILE).write_text(json.dumps({"version": "1.1.0", "whatsNew": {"ja": "下書き"}}), encoding="utf-8")
        result = self.body()
        self.assertEqual(result["source"], "draft")
        self.assertTrue(result["body"].startswith("下書き\n\n> 最新情報が確定する前の下書き"))

    def test_draft_of_other_version_is_ignored(self):
        (self.repo.path / DRAFT_FILE).write_text(json.dumps({"version": "1.0.0", "whatsNew": {"ja": "古い"}}), encoding="utf-8")
        self.assertEqual(self.body()["source"], "pullRequests")

    def test_pull_request_list_since_previous_tag(self):
        self.repo.git("tag", "v1.0.0")
        self.repo.merge_pr("develop", 3, "feat/a", "【FEAT】受信箱を絞り込む")
        self.repo.merge_pr("develop", 4, "ci/b", "【CI】ワークフローを足す")
        result = self.body()
        self.assertEqual(result["source"], "pullRequests")
        self.assertEqual(result["previousTag"], "v1.0.0")
        self.assertEqual(result["body"], "- 受信箱を絞り込む (#3)\n- ワークフローを足す (#4)\n\n"
                                         "**変更の一覧**: https://github.com/org/app/compare/v1.0.0...v1.1.0\n")

    def test_no_pull_requests(self):
        self.assertEqual(self.body()["body"], FALLBACK_TEXT + "\n")

    def test_multiple_languages_are_sectioned(self):
        languages = {"languages": [{"language": "ja"}, {"language": "en"}]}
        (self.repo.path / "AppStore/languages.json").write_text(json.dumps(languages), encoding="utf-8")
        self.write_whats_new("1.1.0", "日本語")
        (self.repo.path / "AppStore/metadata/en.json").write_text(
            json.dumps({"whatsNew": {"version": "1.1.0", "text": "English"}}), encoding="utf-8")
        self.assertEqual(self.body()["body"], "### ja\n\n日本語\n\n### en\n\nEnglish\n")

    def test_partly_confirmed_languages_are_not_confirmed(self):
        languages = {"languages": [{"language": "ja"}, {"language": "en"}]}
        (self.repo.path / "AppStore/languages.json").write_text(json.dumps(languages), encoding="utf-8")
        self.write_whats_new("1.1.0", "日本語")
        self.assertEqual(self.body()["source"], "pullRequests")


class DevelopVersionTests(FinishTestCase):
    def xcconfig(self) -> str:
        return (self.repo.path / "Configs/Project.xcconfig").read_text(encoding="utf-8")

    def test_released_version_becomes_next_patch(self):
        self.repo.commit_file("Configs/Project.xcconfig", "MARKETING_VERSION = 1.1.0 // 表示\n", "1.1.0")
        result = release_finish.develop_version(self.repo.path, "1.1.0")
        self.assertTrue(result["changed"])
        self.assertEqual((result["previous"], result["version"]), ("1.1.0", "1.1.1"))
        self.assertEqual(self.xcconfig(), "MARKETING_VERSION = 1.1.1 // 表示\n")

    def test_older_version_also_becomes_next_patch(self):
        # 初回に develop と同じ 1.0.0 で出したとき（release で書き換えていない）も、配信した 1.0.0 のままにしない
        result = release_finish.develop_version(self.repo.path, "1.0.0")
        self.assertEqual(result["version"], "1.0.1")

    def test_newer_version_is_kept(self):
        self.repo.commit_file("Configs/Project.xcconfig", "MARKETING_VERSION = 1.2.0\n", "1.2.0")
        result = release_finish.develop_version(self.repo.path, "1.1.0")
        self.assertFalse(result["changed"])
        self.assertEqual(self.xcconfig(), "MARKETING_VERSION = 1.2.0\n")

    def test_invalid_version(self):
        self.repo.commit_file("Configs/Project.xcconfig", "MARKETING_VERSION = 1.1\n", "1.1")
        with self.assertRaisesRegex(Failure, "MAJOR.MINOR.PATCH"):
            release_finish.develop_version(self.repo.path, "1.1.0")


class MainTests(FinishTestCase):
    def run_main(self, *argv: str) -> tuple[int, dict]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = release_finish.main(["--root", str(self.repo.path), *argv])
        return code, json.loads(out.getvalue())

    def test_check_outputs_json(self):
        self.repo.cut_release()
        code, result = self.run_main("check", "--version", "1.1.0")
        self.assertEqual(code, 0)
        self.assertEqual(result["command"], "check")
        self.assertEqual(result["main"], "create")

    def test_failure_outputs_json(self):
        code, result = self.run_main("check", "--version", "1.1.0")
        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        self.assertIn("release/1.1.0", result["error"])

    def test_invalid_version(self):
        code, result = self.run_main("check", "--version", "1.1")
        self.assertEqual(code, 2)
        self.assertIn("MAJOR.MINOR.PATCH", result["error"])

    def test_tag_target_command(self):
        release = self.repo.cut_release()
        self.repo.git("branch", "main", "release/1.1.0")
        self.repo.publish("main")
        code, result = self.run_main("tag-target", "--version", "1.1.0")
        self.assertEqual((code, result["target"]), (0, release))


if __name__ == "__main__":
    unittest.main()

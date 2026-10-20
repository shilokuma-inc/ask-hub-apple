"""Tools/release_finish_merge.sh のテスト。

リモートは一時ディレクトリの bare リポジトリ、gh は呼び出しを記録する偽物（PATH の先頭に置くシェルスクリプト）に差し替える。
ネットワークには出ない。ブランチ保護（必須チェック）はまねられないので、check run を付けてから push する順番と、
push の結果（ブランチの先頭）を確かめる。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from Tools.tests.test_release_prepare import GIT_ENV, XCCONFIG

SCRIPT = Path(__file__).resolve().parent.parent / "release_finish_merge.sh"

#: gh の偽物。引数を GH_LOG に 1 行ずつ書き、環境変数で失敗や副作用をまねる
FAKE_GH = r"""#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *check-runs*)
    if [ -n "${GH_FAIL_CHECK_RUN:-}" ]; then
      echo "gh: Resource not accessible by integration (HTTP 403)" >&2
      exit 1
    fi
    # 1 回目の check run の後に、ほかの人が取り込み先に push したことにする
    if [ -n "${GH_ON_CHECK_RUN:-}" ] && [ ! -e "$GH_LOG.hooked" ]; then
      : > "$GH_LOG.hooked"
      bash -c "$GH_ON_CHECK_RUN" > /dev/null 2>&1
    fi
    ;;
  "pr list"*) ;;
  "pr create"*)
    if [ -n "${GH_FAIL_PR_CREATE:-}" ]; then
      echo "pull request create failed: GraphQL: GitHub Actions is not permitted to create or approve pull requests" >&2
      exit 1
    fi
    echo "https://github.com/org/app/pull/10"
    ;;
  "issue list"*) ;;
  "issue create"*)
    # 本文を後で確かめられるよう残す
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--body-file" ]; then cp "$2" "$GH_LOG.issue.md"; fi
      shift
    done
    echo "https://github.com/org/app/issues/11"
    ;;
esac
"""

VERSION = "1.1.0"
RELEASE = f"release/{VERSION}"


@unittest.skipUnless(shutil.which("jq") and shutil.which("bash"), "jq と bash が要る")
class MergeScriptTestCase(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tmp = Path(directory.name)
        self.origin = self.tmp / "origin.git"
        self.work = self.tmp / "work"
        self.runner = self.tmp / "runner"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        (self.bin / "gh").write_text(FAKE_GH, encoding="utf-8")
        (self.bin / "gh").chmod(0o755)
        self.gh_log = self.tmp / "gh.log"
        self.runs = 0

        subprocess.run(["git", "init", "-q", "--bare", "-b", "develop", str(self.origin)], check=True, env=self.env())
        self.work.mkdir()
        self.git("init", "-q", "-b", "develop")
        self.git("remote", "add", "origin", str(self.origin))
        self.write("Configs/Project.xcconfig", XCCONFIG)
        self.write("README.md", "AskHub\n")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "最初のコミット")
        self.git("checkout", "-q", "-b", RELEASE)
        self.write("Configs/Project.xcconfig", XCCONFIG.replace("1.0.0", VERSION))
        self.git("commit", "-q", "-am", f"[chore] MARKETING_VERSION を {VERSION} にする")
        self.git("checkout", "-q", "develop")
        self.git("push", "-q", "origin", "develop", RELEASE)
        self.release_sha = self.remote_sha(RELEASE)

    # MARK: 道具

    def env(self, **extra: str) -> dict[str, str]:
        return {**os.environ, **GIT_ENV, **extra}

    def git(self, *args: str, cwd: Path | None = None) -> str:
        return subprocess.run(["git", *args], cwd=cwd or self.work, env=self.env(), check=True,
                              capture_output=True, text=True).stdout

    def write(self, name: str, text: str) -> None:
        path = self.work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit_on(self, branch: str, name: str, text: str, message: str) -> None:
        """work で branch（origin の先頭）にコミットして push する。"""
        self.git("fetch", "-q", "origin")
        self.git("checkout", "-q", "-B", branch, f"origin/{branch}")
        self.write(name, text)
        self.git("add", ".")
        self.git("commit", "-q", "-m", message)
        self.git("push", "-q", "origin", branch)
        self.git("checkout", "-q", "develop")

    def remote_sha(self, branch: str) -> str | None:
        out = self.git("ls-remote", "origin", f"refs/heads/{branch}").split()
        return out[0] if out else None

    def remote_file(self, branch: str, name: str) -> str:
        return subprocess.run(["git", "--git-dir", str(self.origin), "show", f"{branch}:{name}"], env=self.env(),
                              check=True, capture_output=True, text=True).stdout

    def gh_calls(self) -> list[str]:
        return self.gh_log.read_text(encoding="utf-8").splitlines() if self.gh_log.exists() else []

    def run_script(self, target: str, **extra: str) -> tuple[int, dict[str, str], str]:
        """Release/Finish の finish ジョブと同じく、clone した作業ツリーでスクリプトを流す。"""
        if self.runner.exists():
            self.git("fetch", "-q", "--prune", "origin", cwd=self.runner)
        else:
            subprocess.run(["git", "clone", "-q", "-b", "develop", str(self.origin), str(self.runner)],
                           check=True, env=self.env(), capture_output=True)
        self.runs += 1
        temp = self.tmp / f"runner-temp-{self.runs}"
        temp.mkdir()
        summary, output = temp / "summary.md", temp / "output.txt"
        summary.touch()
        output.touch()
        env = self.env(
            VERSION=VERSION, RELEASE_SHA=self.release_sha, GITHUB_REPOSITORY="org/app", GH_TOKEN="token",
            SUMMARY=str(summary), RUNNER_TEMP=str(temp), GITHUB_OUTPUT=str(output), GH_LOG=str(self.gh_log),
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", **extra)
        completed = subprocess.run(["bash", str(SCRIPT), target], cwd=self.runner, env=env, capture_output=True, text=True)
        outputs = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines() if "=" in line)
        return completed.returncode, outputs, summary.read_text(encoding="utf-8")

    def merge_develop_into_pr_branch(self, pr_branch: str) -> None:
        """人が PR のブランチで develop を取り込み、MARKETING_VERSION のコンフリクトを release 側で解く。"""
        self.git("fetch", "-q", "origin")
        self.git("checkout", "-q", "-B", "pr", f"origin/{pr_branch}")
        merged = subprocess.run(["git", "merge", "-q", "origin/develop", "-m", "Merge branch 'develop'"], cwd=self.work,
                                env=self.env(), capture_output=True, text=True)
        self.assertNotEqual(merged.returncode, 0)  # コンフリクトする
        self.write("Configs/Project.xcconfig", XCCONFIG.replace("1.0.0", VERSION))
        self.git("add", ".")
        self.git("commit", "-q", "--no-edit")
        self.git("push", "-q", "origin", f"pr:{pr_branch}")

    def merge_pull_request(self, pr_branch: str, into: str) -> None:
        """人が GitHub で PR をマージコミットでマージしたことにする。"""
        self.git("fetch", "-q", "origin")
        self.git("checkout", "-q", "-B", into, f"origin/{into}")
        self.git("merge", "-q", "--no-ff", f"origin/{pr_branch}", "-m", "Merge pull request #10 from org/" + pr_branch)
        self.git("push", "-q", "origin", into)
        self.git("checkout", "-q", "develop")


class DevelopTests(MergeScriptTestCase):
    def test_merges_with_check_run_and_next_patch(self):
        code, outputs, summary = self.run_script("develop")
        self.assertEqual(code, 0, summary)
        self.assertEqual(outputs["state"], "merged")
        head = self.remote_sha("develop")
        self.assertEqual(outputs["sha"], head)
        self.assertIn("MARKETING_VERSION = 1.1.1", self.remote_file("develop", "Configs/Project.xcconfig"))
        self.assertEqual(self.git("--git-dir", str(self.origin), "log", "-1", "--format=%s", "develop").strip(),
                         "[chore] MARKETING_VERSION を 1.1.1 にする")
        self.assertEqual(self.git("--git-dir", str(self.origin), "log", "-1", "--format=%s", "develop^").strip(),
                         f"Merge branch '{RELEASE}' into develop")
        # push する先頭に check run を付けてから push し、一時ブランチは残さない
        check_runs = [call for call in self.gh_calls() if "check-runs" in call]
        self.assertEqual(len(check_runs), 1)
        self.assertIn(f"head_sha={head}", check_runs[0])
        self.assertIsNone(self.remote_sha(f"release-finish/{VERSION}/develop"))
        self.assertEqual(self.remote_sha(RELEASE), self.release_sha)

    def test_conflict_leaves_pr_from_temp_branch_and_rerun_after_merge_bumps_version(self):
        # リリースの間に develop が MARKETING_VERSION を変えていて、release → develop がコンフリクトする
        self.commit_on("develop", "Configs/Project.xcconfig", XCCONFIG.replace("1.0.0", "1.0.5"), "[chore] 1.0.5")
        code, outputs, summary = self.run_script("develop", GH_FAIL_PR_CREATE="1")
        self.assertEqual(code, 1)
        self.assertEqual(outputs["state"], "conflict")
        self.assertIn("Configs/Project.xcconfig", summary)
        # PR の head は release の先頭から作った一時ブランチ。release ブランチは進めない
        pr_branch = f"release-finish/{VERSION}/pr-develop"
        self.assertEqual(self.remote_sha(pr_branch), self.release_sha)
        self.assertEqual(self.remote_sha(RELEASE), self.release_sha)
        creates = [call for call in self.gh_calls() if call.startswith("pr create")]
        self.assertEqual(len(creates), 1)
        self.assertIn(f"--head {pr_branch}", creates[0])
        # PR を作れなかったので Issue で知らせ、本文で一時ブランチを案内し、release に push しないよう書く
        self.assertEqual(outputs["issue"], "https://github.com/org/app/issues/11")
        issue = Path(f"{self.gh_log}.issue.md").read_text(encoding="utf-8")
        self.assertIn(f"`{pr_branch}`", issue)
        self.assertIn(f"`{RELEASE}` には push しないでください", issue)
        self.assertIn("残っているのは `develop` への取り込みだけです", issue)
        # develop 宛ての PR の必須チェックのため、PR の head（release の先頭）に check run を付ける
        self.assertTrue(any(f"head_sha={self.release_sha}" in call for call in self.gh_calls() if "check-runs" in call))

        # 人が一時ブランチでコンフリクトを解き、PR をマージしてから起動し直す（要修正 1・2）
        self.merge_develop_into_pr_branch(pr_branch)
        self.merge_pull_request(pr_branch, "develop")
        merged = self.remote_sha("develop")
        self.assertIn("MARKETING_VERSION = 1.1.0", self.remote_file("develop", "Configs/Project.xcconfig"))
        code, outputs, summary = self.run_script("develop")
        self.assertEqual(code, 0, summary)
        self.assertEqual(outputs["state"], "done")
        self.assertIn("すでに", summary)
        # 取り込み済みでも、配信した 1.1.0 のままなので次のパッチにするコミットだけを足す
        self.assertIn("MARKETING_VERSION = 1.1.1", self.remote_file("develop", "Configs/Project.xcconfig"))
        head = self.remote_sha("develop")
        self.assertEqual(outputs["sha"], head)
        self.assertEqual(self.git("--git-dir", str(self.origin), "rev-parse", "develop^").strip(), merged)
        self.assertIn(f"head_sha={head}", [call for call in self.gh_calls() if "check-runs" in call][-1])
        self.assertIsNone(self.remote_sha(f"release-finish/{VERSION}/develop"))
        self.assertEqual(self.remote_sha(RELEASE), self.release_sha)

        # もう一度起動し直しても、何も変えない
        code, outputs, summary = self.run_script("develop")
        self.assertEqual((code, outputs["state"], outputs["sha"]), (0, "done", head))

    def test_existing_pr_branch_with_human_commits_is_kept(self):
        self.commit_on("develop", "Configs/Project.xcconfig", XCCONFIG.replace("1.0.0", "1.0.5"), "[chore] 1.0.5")
        self.run_script("develop", GH_FAIL_PR_CREATE="1")
        pr_branch = f"release-finish/{VERSION}/pr-develop"
        self.merge_develop_into_pr_branch(pr_branch)
        resolved = self.remote_sha(pr_branch)
        # PR をマージする前に起動し直しても、人がコンフリクトを解いたコミットを消さない
        code, outputs, _ = self.run_script("develop")
        self.assertEqual((code, outputs["state"]), (1, "conflict"))
        self.assertEqual(self.remote_sha(pr_branch), resolved)
        self.assertIn(f"--head {pr_branch}", [call for call in self.gh_calls() if call.startswith("pr create")][-1])

    def test_leftover_temp_branch_is_overwritten(self):
        # 中断した run の一時ブランチが残っている（指摘 3）
        self.git("checkout", "-q", "-b", "junk")
        self.write("other.txt", "other")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "[chore] 別のコミット")
        self.git("push", "-q", "origin", f"junk:refs/heads/release-finish/{VERSION}/develop")
        self.git("checkout", "-q", "develop")
        code, outputs, summary = self.run_script("develop")
        self.assertEqual(code, 0, summary)
        self.assertEqual(outputs["state"], "merged")
        self.assertIsNone(self.remote_sha(f"release-finish/{VERSION}/develop"))

    def test_check_run_failure_is_not_reported_as_rejected_push(self):
        before = self.remote_sha("develop")
        code, outputs, summary = self.run_script("develop", GH_FAIL_CHECK_RUN="1")
        self.assertEqual(code, 1)
        self.assertEqual(outputs["state"], "check-run-failed")
        self.assertIn("check run「No AI Attribution」を付けられませんでした", summary)
        self.assertIn("HTTP 403", summary)
        self.assertIn("起動し直してください", summary)
        self.assertNotIn("push を断られました", summary)
        self.assertEqual(self.remote_sha("develop"), before)
        self.assertIsNone(self.remote_sha(f"release-finish/{VERSION}/develop"))
        # コンフリクトではないので、PR のブランチ・PR・Issue を残して「コンフリクトを解いて」と案内しない
        self.assertNotIn("コンフリクトを解", summary)
        self.assertIsNone(self.remote_sha(f"release-finish/{VERSION}/pr-develop"))
        self.assertEqual([call for call in self.gh_calls() if call.startswith(("pr ", "issue "))], [])
        self.assertNotIn("pr", outputs)
        self.assertNotIn("issue", outputs)

    def test_retries_once_when_develop_moves_after_start(self):
        # 1 回目の check run の後に、ほかの PR が develop にマージされた（指摘 6）
        other = self.tmp / "other"
        subprocess.run(["git", "clone", "-q", "-b", "develop", str(self.origin), str(other)], check=True,
                       env=self.env(), capture_output=True)
        hook = (f"cd {other} && echo x > feature.txt && git add . && git commit -q -m feature && "
                "git push -q origin develop")
        code, outputs, summary = self.run_script("develop", GH_ON_CHECK_RUN=hook)
        self.assertEqual(code, 0, summary)
        self.assertEqual(outputs["state"], "merged")
        self.assertIn("取り込み直しました", summary)
        self.assertEqual(self.remote_file("develop", "feature.txt"), "x\n")
        self.assertIn("MARKETING_VERSION = 1.1.1", self.remote_file("develop", "Configs/Project.xcconfig"))


class MainTests(MergeScriptTestCase):
    def test_creates_main_from_release_head(self):
        code, outputs, summary = self.run_script("main")
        self.assertEqual(code, 0, summary)
        self.assertEqual((outputs["state"], outputs["sha"]), ("created", self.release_sha))
        self.assertEqual(self.remote_sha("main"), self.release_sha)
        self.assertEqual(self.gh_calls(), [])

    def test_merges_into_main_without_check_run(self):
        # 保護の無い main には一時ブランチも check run も使わない（指摘 5）
        self.git("push", "-q", "origin", "develop:refs/heads/main")
        code, outputs, summary = self.run_script("main")
        self.assertEqual(code, 0, summary)
        self.assertEqual(outputs["state"], "merged")
        self.assertEqual(self.remote_sha("main"), outputs["sha"])
        self.assertEqual(self.git("--git-dir", str(self.origin), "log", "-1", "--format=%s", "main").strip(),
                         f"Merge branch '{RELEASE}' into main")
        self.assertEqual([call for call in self.gh_calls() if "check-runs" in call], [])
        self.assertIsNone(self.remote_sha(f"release-finish/{VERSION}/main"))

    def test_already_merged_main_is_done(self):
        self.git("push", "-q", "origin", f"{self.release_sha}:refs/heads/main")
        code, outputs, _ = self.run_script("main")
        self.assertEqual((code, outputs["state"]), (0, "done"))

    def test_planned_done_does_not_merge_advanced_release(self):
        # タグを打った後に release が進んだ: check が main を done とみなしたら、進んだ分は main に取り込まない
        self.git("push", "-q", "origin", f"{self.release_sha}:refs/heads/main")
        self.commit_on(RELEASE, "late.txt", "late", "[fix] 遅れて入ったコミット")
        self.release_sha = self.remote_sha(RELEASE)
        code, outputs, summary = self.run_script("main", PLANNED="done")
        self.assertEqual((code, outputs["state"]), (0, "done"), summary)
        self.assertNotEqual(self.remote_sha("main"), self.release_sha)


if __name__ == "__main__":
    unittest.main()

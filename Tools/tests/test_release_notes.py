"""Tools/release_notes.py のテスト。ファイルは一時ディレクトリに置き、git のリモートも一時ディレクトリの bare リポジトリにする。

    python3 -m unittest discover -s Tools/tests -t .
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import release_notes  # noqa: E402
from release_notes import InvalidWhatsNew, check_release, parse_whats_new  # noqa: E402
from release_prepare import Failure  # noqa: E402

GIT_ENV = {
    "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.com",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
}

METADATA = {
    "_comment": ["説明"],
    "promotionalText": "宣伝",
    "description": "説明文",
    "keywords": ["GitHub", "AI"],
}


def language(code: str) -> dict:
    return {"language": code, "appleLanguage": code, "appleLocale": code, "storeLocale": code}


def write_repository(root: Path, languages: tuple[str, ...] = ("ja",), draft: bool = True) -> None:
    (root / "AppStore" / "metadata").mkdir(parents=True)
    (root / "AppStore" / "languages.json").write_text(
        json.dumps({"languages": [language(code) for code in languages]}), encoding="utf-8")
    for code in languages:
        (root / "AppStore" / "metadata" / f"{code}.json").write_text(
            release_notes.dump_json(METADATA), encoding="utf-8")
    if draft:
        (root / "AppStore" / "whats-new-draft.json").write_text(
            json.dumps({"schemaVersion": 1, "version": "1.1.0", "whatsNew": {code: "下書き" for code in languages}}),
            encoding="utf-8")


def run_main(*argv: str, env: dict | None = None) -> tuple[int, dict]:
    output = io.StringIO()
    with unittest.mock.patch.dict(os.environ, env or {}), \
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
        status = release_notes.main(list(argv))
    return status, json.loads(output.getvalue())


class CheckReleaseTests(unittest.TestCase):
    def test_release_branch_without_tag(self):
        result = check_release("1.1.0", ["1.1.0"], ["v1.0.0"])
        self.assertTrue(result["ok"])
        self.assertEqual(result["branch"], "release/1.1.0")
        self.assertFalse(result["initial"])
        self.assertEqual(result["warnings"], [])

    def test_initial_release_warns(self):
        result = check_release("1.0.0", ["1.0.0"], ["not-a-version", "vfoo"])
        self.assertTrue(result["initial"])
        self.assertEqual(len(result["warnings"]), 1)
        self.assertIn("最初のバージョン", result["warnings"][0])

    def test_released_version_is_rejected(self):
        with self.assertRaisesRegex(Failure, "リリース済み"):
            check_release("1.1.0", ["1.1.0"], ["v1.0.0", "v1.1.0"])

    def test_missing_release_branch_is_rejected(self):
        with self.assertRaisesRegex(Failure, "release/1.2.0 がありません"):
            check_release("1.2.0", ["1.1.0"], ["v1.0.0"])


class ParseWhatsNewTests(unittest.TestCase):
    def problems(self, raw: str, languages: list[str] | None = None, limit: int = 4000) -> list[str]:
        with self.assertRaises(InvalidWhatsNew) as context:
            parse_whats_new(raw, languages or ["ja"], limit=limit)
        return context.exception.problems

    def test_texts_are_stripped_and_ordered_by_languages(self):
        texts = parse_whats_new(json.dumps({"en": " New ", "ja": "\n・新機能\n"}), ["ja", "en"])
        self.assertEqual(list(texts.items()), [("ja", "・新機能"), ("en", "New")])

    def test_not_json(self):
        self.assertIn("JSON として読めません", self.problems("{ja: 1}")[0])

    def test_not_object(self):
        self.assertIn("オブジェクト", self.problems('["ja"]')[0])
        self.assertIn("オブジェクト", self.problems('"ja"')[0])

    def test_unknown_and_missing_languages(self):
        problems = self.problems(json.dumps({"fr": "Nouveau"}), ["ja", "en"])
        self.assertEqual(len(problems), 2)
        self.assertIn("無い言語があります: fr", problems[0])
        self.assertIn("本文の無い言語があります: ja, en", problems[1])

    def test_empty_object(self):
        self.assertIn("本文の無い言語があります: ja", self.problems("{}")[0])

    def test_value_must_be_string(self):
        self.assertEqual(self.problems(json.dumps({"ja": 1})), ["ja: 本文は文字列にしてください"])
        self.assertEqual(self.problems(json.dumps({"ja": None})), ["ja: 本文は文字列にしてください"])

    def test_blank_text(self):
        self.assertEqual(self.problems(json.dumps({"ja": " \n\t"})), ["ja: 本文が空です"])

    def test_limit_counts_stripped_characters(self):
        self.assertEqual(parse_whats_new(json.dumps({"ja": "  " + "あ" * 10 + "\n"}), ["ja"], limit=10),
                         {"ja": "あ" * 10})
        self.assertEqual(self.problems(json.dumps({"ja": "あ" * 11}), limit=10), ["ja: 本文が 11 字あります（上限 10 字）"])

    def test_default_limit_is_app_store_limit(self):
        self.assertEqual(parse_whats_new(json.dumps({"ja": "a" * 4000}), ["ja"]), {"ja": "a" * 4000})
        self.assertIn("4001 字", self.problems(json.dumps({"ja": "a" * 4001}))[0])

    def test_placeholder_is_rejected(self):
        self.assertIn("TODO:", self.problems(json.dumps({"ja": "TODO: 書く"}))[0])

    def test_duplicated_language(self):
        self.assertIn("2 回以上", self.problems('{"ja": "一", "ja": "二"}')[0])

    def test_all_problems_are_reported_together(self):
        problems = self.problems(json.dumps({"ja": "", "en": 1}), ["ja", "en"])
        self.assertEqual(problems, ["ja: 本文が空です", "en: 本文は文字列にしてください"])


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def apply(self, whats_new: object, version: str = "1.1.0") -> tuple[int, dict]:
        raw = whats_new if isinstance(whats_new, str) else json.dumps(whats_new, ensure_ascii=False)
        return run_main("--root", str(self.root), "apply", "--version", version, env={"WHATS_NEW": raw})

    def metadata(self, code: str = "ja") -> dict:
        return json.loads((self.root / "AppStore" / "metadata" / f"{code}.json").read_text(encoding="utf-8"))

    def test_writes_whats_new_and_removes_draft(self):
        write_repository(self.root)
        status, result = self.apply({"ja": "・受信箱を絞り込めるようにする\n"})
        self.assertEqual(status, 0, result)
        self.assertTrue(result["changed"])
        self.assertTrue(result["draftRemoved"])
        self.assertEqual(result["languages"], [{"language": "ja", "length": 15, "changed": True}])
        metadata = self.metadata()
        self.assertEqual(metadata["whatsNew"], {"version": "1.1.0", "text": "・受信箱を絞り込めるようにする"})
        # ほかのキーとその順は変えない（whatsNew は末尾に足す）
        self.assertEqual(list(metadata), [*METADATA, "whatsNew"])
        self.assertFalse((self.root / "AppStore" / "whats-new-draft.json").exists())

    def test_same_input_twice_changes_nothing(self):
        write_repository(self.root)
        self.apply({"ja": "本文"})
        before = (self.root / "AppStore" / "metadata" / "ja.json").read_text(encoding="utf-8")
        status, result = self.apply({"ja": "本文"})
        self.assertEqual(status, 0, result)
        self.assertFalse(result["changed"])
        self.assertFalse(result["draftRemoved"])
        self.assertEqual(result["languages"][0]["changed"], False)
        self.assertEqual((self.root / "AppStore" / "metadata" / "ja.json").read_text(encoding="utf-8"), before)

    def test_overwrites_previous_confirmation(self):
        write_repository(self.root)
        self.apply({"ja": "最初の本文"})
        status, result = self.apply({"ja": "直した本文"})
        self.assertEqual(status, 0, result)
        self.assertTrue(result["changed"])
        self.assertEqual(self.metadata()["whatsNew"], {"version": "1.1.0", "text": "直した本文"})

    def test_overwrites_whats_new_of_previous_version_in_place(self):
        write_repository(self.root, draft=False)
        path = self.root / "AppStore" / "metadata" / "ja.json"
        old = {"_comment": ["説明"], "whatsNew": {"version": "1.0.0", "text": "前の本文"}, "description": "説明文"}
        path.write_text(release_notes.dump_json(old), encoding="utf-8")
        status, result = self.apply({"ja": "新しい本文"})
        self.assertEqual(status, 0, result)
        self.assertTrue(result["changed"])
        self.assertFalse(result["draftRemoved"])
        self.assertEqual(list(self.metadata()), ["_comment", "whatsNew", "description"])
        self.assertEqual(self.metadata()["whatsNew"], {"version": "1.1.0", "text": "新しい本文"})

    def test_invalid_input_writes_nothing(self):
        write_repository(self.root, languages=("ja", "en"))
        before = (self.root / "AppStore" / "metadata" / "ja.json").read_text(encoding="utf-8")
        status, result = self.apply({"ja": "本文", "en": ""})
        self.assertEqual(status, 1)
        self.assertFalse(result["ok"])
        self.assertEqual(result["problems"], ["en: 本文が空です"])
        self.assertEqual((self.root / "AppStore" / "metadata" / "ja.json").read_text(encoding="utf-8"), before)
        self.assertTrue((self.root / "AppStore" / "whats-new-draft.json").exists())

    def test_missing_metadata_file_writes_nothing(self):
        write_repository(self.root, languages=("ja", "en"))
        (self.root / "AppStore" / "metadata" / "en.json").unlink()
        status, result = self.apply({"ja": "本文", "en": "Text"})
        self.assertEqual(status, 1)
        self.assertIn("en.json がありません", result["error"])
        self.assertNotIn("whatsNew", self.metadata())
        self.assertTrue((self.root / "AppStore" / "whats-new-draft.json").exists())

    def test_multiple_languages(self):
        write_repository(self.root, languages=("ja", "en"))
        status, result = self.apply({"en": "Filters", "ja": "絞り込み"})
        self.assertEqual(status, 0, result)
        self.assertEqual([entry["language"] for entry in result["languages"]], ["ja", "en"])
        self.assertEqual(self.metadata("en")["whatsNew"], {"version": "1.1.0", "text": "Filters"})

    def test_missing_environment_variable(self):
        write_repository(self.root)
        with unittest.mock.patch.dict(os.environ):
            os.environ.pop("WHATS_NEW", None)
            status, result = run_main("--root", str(self.root), "apply", "--version", "1.1.0")
        self.assertEqual(status, 1)
        self.assertIn("環境変数 WHATS_NEW", result["error"])

    def test_invalid_version(self):
        write_repository(self.root)
        status, result = self.apply({"ja": "本文"}, version="1.1")
        self.assertEqual(status, 2)
        self.assertIn("MAJOR.MINOR.PATCH", result["error"])


class CheckCommandTests(unittest.TestCase):
    """`check` が `git ls-remote` で release ブランチとタグを読むこと。"""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        base = Path(self.directory.name)
        self.remote = base / "remote.git"
        self.work = base / "work"
        self.git(base, "init", "-q", "--bare", str(self.remote))
        self.work.mkdir()
        self.git(self.work, "init", "-q", "-b", "develop")
        (self.work / "README").write_text("x", encoding="utf-8")
        self.git(self.work, "add", ".")
        self.git(self.work, "commit", "-q", "-m", "最初のコミット")
        self.git(self.work, "remote", "add", "origin", str(self.remote))
        self.git(self.work, "push", "-q", "origin", "develop", "develop:refs/heads/release/1.1.0")

    def tearDown(self):
        self.directory.cleanup()

    @staticmethod
    def git(cwd: Path, *args: str) -> None:
        subprocess.run(["git", *args], cwd=cwd, env={**os.environ, **GIT_ENV}, check=True, capture_output=True)

    def check(self, version: str) -> tuple[int, dict]:
        return run_main("--root", str(self.work), "check", "--version", version, env=GIT_ENV)

    def test_initial_release(self):
        status, result = self.check("1.1.0")
        self.assertEqual(status, 0, result)
        self.assertTrue(result["initial"])

    def test_after_previous_tag(self):
        self.git(self.work, "tag", "-a", "v1.0.0", "-m", "1.0.0")
        self.git(self.work, "push", "-q", "origin", "v1.0.0")
        status, result = self.check("1.1.0")
        self.assertEqual(status, 0, result)
        self.assertFalse(result["initial"])

    def test_released(self):
        self.git(self.work, "tag", "v1.1.0")
        self.git(self.work, "push", "-q", "origin", "v1.1.0")
        status, result = self.check("1.1.0")
        self.assertEqual(status, 1)
        self.assertIn("リリース済み", result["error"])

    def test_without_release_branch(self):
        status, result = self.check("1.2.0")
        self.assertEqual(status, 1)
        self.assertIn("release/1.2.0 がありません", result["error"])


if __name__ == "__main__":
    unittest.main()

"""Policy truth table and real Git regressions for change selection."""

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ci_changes


class SelectionTests(unittest.TestCase):
    def test_truth_table(self):
        cases = [([], False), (["README.md"], False), (["AGENTS.md"], False),
                 (["docs/guide.md"], False), (["docs/fixture.json"], True),
                 (["unknown.file"], True), (["scripts/check.py"], True),
                 ([".github/workflows/ci.yml"], True),
                 (["docs/guide.md", "source.rs"], True)]
        for paths, expected in cases:
            with self.subTest(paths=paths):
                self.assertEqual(ci_changes.classify(paths)["heavy"], expected)

    def test_git_deletions_renames_and_cumulative_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root).decode().strip()

            git("init", "-q")
            git("config", "user.email", "ci-test@example.invalid")
            git("config", "user.name", "CI fixture")
            (root / "AGENTS.md").write_text("policy")
            (root / "source.rs").write_text("code")
            git("add", ".")
            git("commit", "-qm", "initial")
            initial = git("rev-parse", "HEAD")
            (root / "AGENTS.md").unlink()
            git("add", "-A")
            git("commit", "-qm", "delete policy")
            docs = git("rev-parse", "HEAD")
            (root / "source.rs").rename(root / "README.md")
            git("add", "-A")
            git("commit", "-qm", "rename code into docs")
            code = git("rev-parse", "HEAD")
            (root / "README.md").write_text("later documentation")
            git("add", ".")
            git("commit", "-qm", "later docs")
            with patch.object(ci_changes, "ROOT", root):
                self.assertFalse(ci_changes.classify(ci_changes.changed_paths(initial, docs))["heavy"])
                self.assertTrue(ci_changes.classify(ci_changes.changed_paths(docs, code))["heavy"])
                self.assertFalse(ci_changes.classify(ci_changes.changed_paths(code, "HEAD"))["heavy"])
                self.assertTrue(ci_changes.classify(ci_changes.changed_paths(docs, "HEAD"))["heavy"])
                with self.assertRaises(ValueError):
                    ci_changes.changed_paths("0" * 40, "HEAD")
                with self.assertRaises(subprocess.CalledProcessError):
                    ci_changes.changed_paths("HEAD", initial)


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from mac_cleaner.models import FileIdentity
from mac_cleaner.safety import validate_cleanup_candidate


class SafetyGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.home = Path(self.temporary.name) / "home"
        self.allowed = self.home / "Library" / "Caches"
        self.allowed.mkdir(parents=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def assert_refused(self, path: str | Path) -> None:
        result = validate_cleanup_candidate(path, allowed_roots=[self.allowed], home=self.home)
        self.assertFalse(result.allowed, result.reason)

    def test_dangerous_roots_are_refused(self) -> None:
        for path in ("/", self.home, self.home / ".ssh" / "id_ed25519",
                     self.home / "Documents" / "work.txt", "/System", "/private/var/tmp/x"):
            with self.subTest(path=path):
                self.assert_refused(path)

    def test_empty_and_unresolved_are_refused(self) -> None:
        self.assert_refused("")
        self.assert_refused(self.allowed / "missing")

    def test_broad_allowed_root_does_not_bypass_policy(self) -> None:
        ordinary = self.home / "ordinary" / "file"
        ordinary.parent.mkdir()
        ordinary.write_text("data", encoding="utf-8")
        result = validate_cleanup_candidate(ordinary, allowed_roots=[self.home], home=self.home)
        self.assertFalse(result.allowed)
        result = validate_cleanup_candidate(ordinary, allowed_roots=[Path("/")], home=self.home)
        self.assertFalse(result.allowed)

    def test_symlink_escape_is_refused(self) -> None:
        outside = self.home / "outside"
        outside.mkdir()
        (outside / "valuable").write_text("keep", encoding="utf-8")
        link = self.allowed / "link"
        link.symlink_to(outside, target_is_directory=True)
        self.assert_refused(link / "valuable")

    def test_identity_change_is_refused(self) -> None:
        path = self.allowed / "old.cache"
        path.write_text("old", encoding="utf-8")
        st = path.lstat()
        identity = FileIdentity(st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
        path.write_text("changed and larger", encoding="utf-8")
        result = validate_cleanup_candidate(path, allowed_roots=[self.allowed], expected=identity, home=self.home)
        self.assertFalse(result.allowed)
        self.assertIn("changed", result.reason)

    def test_safe_names_are_handled_as_paths_not_shell(self) -> None:
        names = ["space name", "unicodé-文件", "line\nbreak", "$(touch PWNED)", ";echo bad", "-leading"]
        for name in names:
            path = self.allowed / name
            path.write_text("cache", encoding="utf-8")
            st = path.lstat()
            identity = FileIdentity(st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
            result = validate_cleanup_candidate(path, allowed_roots=[self.allowed], expected=identity, home=self.home)
            self.assertTrue(result.allowed, f"{name!r}: {result.reason}")
        self.assertFalse((Path.cwd() / "PWNED").exists())

    def test_git_source_is_refused_but_known_generated_dir_can_be_reviewed(self) -> None:
        repo = self.home / "Projects" / "sample"
        (repo / ".git").mkdir(parents=True)
        source = repo / "main.py"
        source.write_text("important", encoding="utf-8")
        result = validate_cleanup_candidate(source, allowed_roots=[repo], home=self.home)
        self.assertFalse(result.allowed)
        self.assertIn("Git worktree", result.reason)

    def test_application_bundle_is_refused(self) -> None:
        app = self.allowed / "Example.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents" / "Info.plist").write_text("plist", encoding="utf-8")
        self.assert_refused(app / "Contents" / "Info.plist")


if __name__ == "__main__":
    unittest.main()

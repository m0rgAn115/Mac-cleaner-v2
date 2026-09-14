from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from mac_cleaner.config import Config
from mac_cleaner.models import Classification
from mac_cleaner.scanners import ScanContext, scan_downloads


class DownloadPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.home = Path(self.temporary.name) / "home"
        self.downloads = self.home / "Downloads"
        self.downloads.mkdir(parents=True)
        self.config = Config(path=self.home / ".config/mac-cleaner/config.json")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_git_worktree_overrides_download_review_policy(self) -> None:
        (self.downloads / ".git").mkdir()
        (self.downloads / "large-source.bin").write_bytes(b"important")
        items = scan_downloads(ScanContext(self.config, home=self.home))
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].classification, Classification.PROTECTED)
        self.assertIn("Git worktree", items[0].reason)


if __name__ == "__main__":
    unittest.main()


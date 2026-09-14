from __future__ import annotations

import os
import tempfile
import time
import unittest
from pathlib import Path

from mac_cleaner.config import Config
from mac_cleaner.models import Classification
from mac_cleaner.scanners import ScanContext, _safe_old_files


class SafeScannerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.home = Path(self.temporary.name) / "home"
        self.cache = self.home / "Library" / "Caches" / "com.example.app"
        self.cache.mkdir(parents=True)
        self.config = Config(path=self.home / ".config/mac-cleaner/config.json", cache_age_days=30)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_only_old_user_files_are_safe_candidates(self) -> None:
        old = self.cache / "old cache"
        recent = self.cache / "recent"
        old.write_bytes(b"old")
        recent.write_bytes(b"new")
        old_time = time.time() - 40 * 86400
        os.utime(old, (old_time, old_time))
        ctx = ScanContext(config=self.config, home=self.home)
        items = _safe_old_files(ctx, self.home / "Library/Caches", category="App caches",
                                age_days=30, reason="test cache", action="preview")
        self.assertEqual([item.path for item in items], [str(old)])
        self.assertTrue(all(item.classification == Classification.SAFE for item in items))
        self.assertTrue(recent.exists())

    def test_ignore_is_applied_before_candidate_creation(self) -> None:
        old = self.cache / "ignored"
        old.write_bytes(b"old")
        old_time = time.time() - 40 * 86400
        os.utime(old, (old_time, old_time))
        self.config.ignored_paths.append(str(self.cache))
        ctx = ScanContext(config=self.config, home=self.home)
        items = _safe_old_files(ctx, self.home / "Library/Caches", category="App caches",
                                age_days=30, reason="test cache", action="preview")
        self.assertEqual(items, [])


if __name__ == "__main__":
    unittest.main()


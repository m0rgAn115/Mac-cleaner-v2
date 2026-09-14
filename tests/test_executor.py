from __future__ import annotations

import os
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from mac_cleaner.executor import execute_items
from mac_cleaner.models import Classification, ScanItem


class CleanupExecutorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(dir=Path.cwd())
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.cache = self.home / "Library/Caches/example.app"
        self.audit = self.root / "audit"
        self.cache.mkdir(parents=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def item(self, path: Path, classification: Classification, category: str, *, metadata=None) -> dict:
        if path.is_dir() and not path.is_symlink():
            size = sum(child.lstat().st_size for child in path.rglob("*") if child.is_file())
        else:
            size = path.lstat().st_size
        return ScanItem.from_path(
            path,
            category=category,
            classification=classification,
            size=size,
            reason="temporary test fixture",
            proposed_action="test-only action",
            metadata=metadata or {},
        ).as_dict()

    def execute(self, items: list[dict], *, mode="delete", classification="SAFE") -> dict:
        return execute_items(
            items,
            mode=mode,
            classification=classification,
            home=self.home,
            audit_directory=self.audit,
            enable_managers=False,
        )

    def test_safe_regular_file_is_deleted_and_audited(self) -> None:
        path = self.cache / "old.cache"
        path.write_bytes(b"regenerable")
        record = self.execute([self.item(
            path, Classification.SAFE, "App caches",
            metadata={"cleanup_root": str(self.home / "Library/Caches"),
                      "execution_kind": "direct-file", "actionable": True},
        )])
        self.assertFalse(path.exists())
        self.assertTrue(record["results"][0]["success"])
        self.assertTrue(Path(record["audit_path"]).is_file())
        self.assertIn("before_available", record)
        self.assertIn("after_available", record)

    def test_safe_root_metadata_cannot_authorize_an_arbitrary_location(self) -> None:
        downloads = self.home / "Downloads"
        downloads.mkdir()
        path = downloads / "important.txt"
        path.write_text("keep", encoding="utf-8")
        record = self.execute([self.item(
            path, Classification.SAFE, "App caches",
            metadata={"cleanup_root": str(downloads), "actionable": True},
        )])
        self.assertTrue(path.exists())
        self.assertFalse(record["results"][0]["success"])
        self.assertIn("allowlist", record["results"][0]["message"])

    def test_changed_identity_and_symlink_are_refused(self) -> None:
        changed = self.cache / "changed.cache"
        changed.write_text("before", encoding="utf-8")
        item = self.item(changed, Classification.SAFE, "App caches", metadata={
            "cleanup_root": str(self.home / "Library/Caches"), "actionable": True,
        })
        changed.write_text("after and different", encoding="utf-8")
        outside = self.home / "valuable"
        outside.write_text("keep", encoding="utf-8")
        link = self.cache / "link.cache"
        link.symlink_to(outside)
        link_item = self.item(link, Classification.SAFE, "App caches", metadata={
            "cleanup_root": str(self.home / "Library/Caches"), "actionable": True,
        })
        record = self.execute([item, link_item])
        self.assertTrue(changed.exists())
        self.assertTrue(outside.exists())
        self.assertTrue(link.is_symlink())
        self.assertTrue(all(not result["success"] for result in record["results"]))

    def test_protected_and_broad_paths_are_refused(self) -> None:
        documents = self.home / "Documents"
        documents.mkdir()
        valuable = documents / "valuable.txt"
        valuable.write_text("keep", encoding="utf-8")
        items = [self.item(valuable, Classification.REVIEW, "Large files", metadata={"actionable": True})]
        record = self.execute(items, mode="trash", classification="REVIEW")
        self.assertTrue(valuable.exists())
        self.assertFalse(record["results"][0]["success"])

    def test_executor_refuses_root_home_credentials_documents_and_system(self) -> None:
        ssh = self.home / ".ssh"
        documents = self.home / "Documents"
        ssh.mkdir()
        documents.mkdir()
        credential = ssh / "id_ed25519"
        document = documents / "project.txt"
        credential.write_text("secret", encoding="utf-8")
        document.write_text("valuable", encoding="utf-8")
        paths = [Path("/"), self.home, credential, document, Path("/System")]
        items = [ScanItem.from_path(
            path, category="Developer — build", classification=Classification.REVIEW,
            size=0, reason="adversarial fixture", proposed_action="must refuse",
            metadata={"actionable": True},
        ).as_dict() for path in paths]
        record = self.execute(items, mode="trash", classification="REVIEW")
        self.assertEqual(len(record["results"]), len(paths))
        self.assertTrue(all(not result["success"] for result in record["results"]))
        self.assertTrue(credential.exists())
        self.assertTrue(document.exists())

    def test_symlinked_trash_destination_aborts_before_any_action(self) -> None:
        outside = self.root / "outside-trash"
        outside.mkdir()
        (self.home / ".Trash").symlink_to(outside, target_is_directory=True)
        downloads = self.home / "Downloads"
        downloads.mkdir()
        candidate = downloads / "installer.dmg"
        candidate.write_bytes(b"valuable fixture")
        item = self.item(candidate, Classification.REVIEW, "Downloads — installers/disk images", metadata={"actionable": True})
        with self.assertRaises(ValueError):
            self.execute([item], mode="trash", classification="REVIEW")
        self.assertTrue(candidate.exists())
        self.assertEqual(list(outside.iterdir()), [])

    def test_review_generated_directory_moves_atomically_to_trash(self) -> None:
        project = self.home / "Projects/demo"
        (project / ".git").mkdir(parents=True)
        generated = project / "node_modules"
        generated.mkdir()
        (generated / "package.bin").write_bytes(b"generated")
        item = self.item(generated, Classification.REVIEW, "Developer — node_modules", metadata={
            "project": str(project), "actionable": True, "execution_kind": "review-path",
        })
        record = self.execute([item], mode="trash", classification="REVIEW")
        self.assertFalse(generated.exists())
        result = record["results"][0]
        self.assertTrue(result["success"])
        self.assertTrue(Path(result["destination"]).is_dir())

    def test_review_directory_cannot_be_permanently_deleted(self) -> None:
        generated = self.home / "Projects/demo/build"
        generated.mkdir(parents=True)
        (generated / "artifact").write_bytes(b"build")
        item = self.item(generated, Classification.REVIEW, "Developer — build", metadata={"actionable": True})
        record = self.execute([item], mode="delete", classification="REVIEW")
        self.assertTrue(generated.exists())
        self.assertFalse(record["results"][0]["success"])
        self.assertIn("regular files", record["results"][0]["message"])

    def test_unusual_filenames_are_never_interpreted_by_a_shell(self) -> None:
        names = ["space name", "unicodé-文件", "line\nbreak", "$(touch PWNED)", ";echo bad", "-leading"]
        items = []
        for name in names:
            path = self.cache / name
            path.write_text("cache", encoding="utf-8")
            items.append(self.item(path, Classification.SAFE, "App caches", metadata={
                "cleanup_root": str(self.home / "Library/Caches"), "actionable": True,
            }))
        record = self.execute(items)
        self.assertTrue(all(result["success"] for result in record["results"]))
        self.assertFalse((Path.cwd() / "PWNED").exists())

    def test_manager_actions_can_be_disabled_for_tests(self) -> None:
        item = {
            "path": "brew://cleanup", "category": "Homebrew official cleanup",
            "classification": "SAFE", "size": 123, "reason": "fixture",
            "metadata": {"actionable": True, "execution_kind": "supported-manager", "manager": "Homebrew"},
        }
        record = self.execute([item])
        self.assertFalse(record["results"][0]["success"])
        self.assertIn("disabled", record["results"][0]["message"])

    def test_docker_image_requires_explicit_permanent_removal(self) -> None:
        item = {
            "path": "docker://image/sha256:0123456789abcdef", "category": "Docker — Images",
            "classification": "REVIEW", "size": 123, "reason": "fixture",
            "metadata": {"actionable": True, "execution_kind": "docker-image",
                         "docker_id": "sha256:0123456789abcdef", "object_type": "docker-image"},
        }
        record = self.execute([item], mode="trash", classification="REVIEW")
        self.assertFalse(record["results"][0]["success"])
        self.assertIn("explicit permanent removal", record["results"][0]["message"])

    def test_internal_manifest_endpoint_revalidates_and_audits_fixture(self) -> None:
        path = self.cache / "bridge.cache"
        path.write_bytes(b"bridge fixture")
        item = self.item(path, Classification.SAFE, "App caches", metadata={
            "cleanup_root": str(self.home / "Library/Caches"),
            "execution_kind": "direct-file", "actionable": True,
        })
        environment = dict(os.environ)
        environment["HOME"] = str(self.home)
        result = subprocess.run(
            [sys.executable, str(Path(__file__).parent.parent / "mac-cleaner"),
             "_apply-manifest", "--mode", "delete", "--classification", "SAFE", "--yes"],
            input=json.dumps({"items": [item]}), text=True, capture_output=True,
            env=environment, timeout=20, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertFalse(path.exists())
        self.assertTrue(record["results"][0]["success"])
        self.assertTrue(Path(record["audit_path"]).is_file())


if __name__ == "__main__":
    unittest.main()

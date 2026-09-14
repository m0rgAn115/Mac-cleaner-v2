from __future__ import annotations

import errno
import json
import os
import platform
import shutil
import stat
import subprocess
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from .models import Classification, FileIdentity
from .safety import SafetyResult, validate_cleanup_candidate


@dataclass
class ActionResult:
    path: str
    action: str
    category: str
    original_size: int
    reason: str
    success: bool
    message: str
    destination: str | None = None


def history_root(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".local/share/mac-cleaner/history"


def _identity(item: dict[str, Any]) -> FileIdentity | None:
    value = item.get("identity")
    if not isinstance(value, dict):
        return None
    try:
        return FileIdentity(
            device=int(value["device"]), inode=int(value["inode"]),
            size=int(value["size"]), mtime_ns=int(value["mtime_ns"]),
        )
    except (KeyError, TypeError, ValueError):
        return None


def _unique_trash_path(trash: Path, source: Path) -> Path:
    candidate = trash / source.name
    counter = 2
    while candidate.exists() or candidate.is_symlink():
        if source.suffix:
            candidate = trash / f"{source.stem} {counter}{source.suffix}"
        else:
            candidate = trash / f"{source.name} {counter}"
        counter += 1
    return candidate


def _prepare_owned_directory(path: Path, *, create: bool = False, trusted_root: Path | None = None) -> None:
    if create and trusted_root is not None:
        try:
            relative = path.relative_to(trusted_root)
        except ValueError as exc:
            raise ValueError(f"private destination escaped its trusted root: {path}") from exc
        current = trusted_root
        for part in relative.parts:
            current /= part
            try:
                st = current.lstat()
            except FileNotFoundError:
                current.mkdir(mode=0o700)
                st = current.lstat()
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
                raise ValueError(f"unsafe component in private destination: {current}")
    elif create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    current = path
    while True:
        st = current.lstat()
        if stat.S_ISLNK(st.st_mode):
            raise ValueError(f"refused symlink in private destination: {current}")
        if current == path and not stat.S_ISDIR(st.st_mode):
            raise ValueError(f"private destination is not a directory: {current}")
        if st.st_uid != os.getuid():
            raise ValueError(f"private destination is not owned by the current user: {current}")
        if trusted_root is None or current == trusted_root:
            break
        if current == current.parent or trusted_root not in current.parents:
            raise ValueError(f"private destination escaped its trusted root: {path}")
        current = current.parent


def _prepare_trash(home: Path) -> Path:
    trash = home / ".Trash"
    _prepare_owned_directory(trash, create=True, trusted_root=home)
    if trash.resolve(strict=True) != trash:
        raise ValueError("Trash does not resolve to the expected location")
    return trash


def _review_policy(item: dict[str, Any], path: Path, home: Path) -> tuple[Path | None, Path | None, str | None]:
    absolute = path.absolute()
    if absolute == home or home not in absolute.parents:
        return None, None, "REVIEW actions are restricted to descendants of the current home directory"
    category = str(item.get("category", ""))
    generated = {"node_modules", ".venv", "venv", ".next", "build", "dist", ".gradle"}
    if path.name in generated and category == f"Developer — {path.name}":
        return path, None, None
    gradle = home / ".gradle/caches"
    if path == gradle or gradle in path.parents:
        return path, None, None
    archives = home / "Library/Developer/Xcode/Archives"
    if archives in path.parents and path.suffix == ".xcarchive":
        return path, None, None
    device_support = home / "Library/Developer/Xcode/iOS DeviceSupport"
    if path.parent == device_support:
        return path, None, None
    backups = home / "Library/Application Support/MobileSync/Backup"
    if path.parent == backups and category == "iPhone/iPad backups":
        return path, backups, None
    for root in (home / "Downloads", home / "Public", home / "Movies"):
        if root == path or root in path.parents:
            return root, None, None
    if path == home / ".Trash" or (home / ".Trash") in path.parents:
        return None, None, "Trash must be reviewed and emptied separately"
    return None, None, "item is not inside a recognized REVIEW cleanup scope"


def _safe_root_allowed(root: Path, home: Path) -> bool:
    """Independently constrain direct SAFE deletion; scan metadata is not authority."""
    permitted = (
        home / "Library/Caches",
        home / "Library/Logs",
        home / "Library/Developer/Xcode/DerivedData",
        home / "Library/Developer/Xcode/DocumentationCache",
        home / "Library/Developer/Xcode/ModuleCache.noindex",
    )
    absolute = root.absolute()
    return any(absolute == candidate or candidate in absolute.parents for candidate in permitted)


def _run_manager(manager: str, category: str, original_size: int, reason: str) -> ActionResult:
    if manager == "Homebrew" and category == "Homebrew official cleanup":
        brew = shutil.which("brew")
        if not brew:
            return ActionResult("brew://cleanup", "brew cleanup", category, original_size, reason, False, "brew is unavailable")
        preview = subprocess.run([brew, "cleanup", "--dry-run"], capture_output=True, text=True, timeout=60, check=False)
        if preview.returncode != 0:
            return ActionResult("brew://cleanup", "brew cleanup", category, original_size, reason, False, "Homebrew dry-run validation failed")
        action = subprocess.run([brew, "cleanup"], capture_output=True, text=True, timeout=300, check=False)
        return ActionResult(
            "brew://cleanup", "brew cleanup", category, original_size, "Homebrew revalidated its own cleanup plan",
            action.returncode == 0, (action.stdout + "\n" + action.stderr).strip()[-4000:] or "Homebrew cleanup completed",
        )
    if manager == "xcrun simctl" and category == "Unavailable Xcode simulators":
        xcrun = shutil.which("xcrun")
        if not xcrun:
            return ActionResult("xcrun://simctl/unavailable", "simctl delete unavailable", category, original_size, reason, False, "xcrun is unavailable")
        preview = subprocess.run([xcrun, "simctl", "list", "devices", "unavailable", "-j"], capture_output=True, text=True, timeout=30, check=False)
        if preview.returncode != 0:
            return ActionResult("xcrun://simctl/unavailable", "simctl delete unavailable", category, original_size, reason, False, "simctl validation failed")
        action = subprocess.run([xcrun, "simctl", "delete", "unavailable"], capture_output=True, text=True, timeout=180, check=False)
        return ActionResult(
            "xcrun://simctl/unavailable", "simctl delete unavailable", category, original_size,
            "Apple simctl still reported unavailable devices", action.returncode == 0,
            (action.stdout + "\n" + action.stderr).strip()[-4000:] or "Unavailable simulators removed",
        )
    return ActionResult(f"manager://{manager}", "manager cleanup", category, original_size, reason, False, "This manager action is intentionally not enabled")


def execute_items(
    items: Iterable[dict[str, Any]],
    *,
    mode: str,
    classification: str,
    home: Path | None = None,
    audit_directory: Path | None = None,
    enable_managers: bool = True,
) -> dict[str, Any]:
    if mode not in {"trash", "delete"}:
        raise ValueError("mode must be 'trash' or 'delete'")
    if classification not in {Classification.SAFE.value, Classification.REVIEW.value}:
        raise ValueError("only SAFE and REVIEW items can be acted upon")
    items = list(items)
    home = (home or Path.home()).resolve()
    audit_directory = audit_directory or history_root(home)
    audit_root = home if audit_directory == home or home in audit_directory.absolute().parents else None
    _prepare_owned_directory(audit_directory, create=True, trusted_root=audit_root)
    before = shutil.disk_usage(home).free
    results: list[ActionResult] = []
    managers_seen: set[tuple[str, str]] = set()
    trash = _prepare_trash(home) if mode == "trash" else home / ".Trash"

    for item in items:
        path_text = str(item.get("path", ""))
        category = str(item.get("category", "Unknown"))
        item_class = str(item.get("classification", ""))
        size = max(0, int(item.get("size", 0) or 0))
        reason = str(item.get("reason", ""))
        metadata = item.get("metadata") if isinstance(item.get("metadata"), dict) else {}
        if item_class != classification:
            results.append(ActionResult(path_text, mode, category, size, reason, False, "classification does not match the confirmed operation"))
            continue
        if metadata.get("actionable") is False:
            results.append(ActionResult(path_text, mode, category, size, reason, False, "scanner marked this item as advisory-only"))
            continue
        if metadata.get("execution_kind") == "supported-manager":
            key = (str(metadata.get("manager", "")), category)
            if key in managers_seen:
                continue
            managers_seen.add(key)
            manager_size = sum(
                max(0, int(candidate.get("size", 0) or 0))
                for candidate in items
                if isinstance(candidate.get("metadata"), dict)
                and str(candidate["metadata"].get("manager", "")) == key[0]
                and str(candidate.get("category", "")) == key[1]
            )
            results.append(_run_manager(*key, manager_size, reason) if enable_managers else ActionResult(path_text, mode, category, manager_size, reason, False, "manager execution disabled in this environment"))
            continue
        if "://" in path_text:
            results.append(ActionResult(path_text, mode, category, size, reason, False, "virtual resources cannot be deleted as filesystem paths"))
            continue

        path = Path(path_text)
        expected = _identity(item)
        if expected is None:
            results.append(ActionResult(path_text, mode, category, size, reason, False, "missing filesystem identity from scan"))
            continue
        try:
            st = path.lstat()
        except OSError as exc:
            results.append(ActionResult(path_text, mode, category, size, reason, False, f"cannot re-stat path: {exc}"))
            continue
        if st.st_uid != os.getuid():
            results.append(ActionResult(path_text, mode, category, size, reason, False, "path is not owned by the current user"))
            continue

        if classification == Classification.SAFE.value:
            root_value = metadata.get("cleanup_root")
            roots = [Path(str(root_value))] if root_value else []
            if not roots or not all(_safe_root_allowed(root, home) for root in roots):
                validation = SafetyResult(False, "SAFE root is not on the independent cleanup allowlist")
            else:
                validation = validate_cleanup_candidate(path, allowed_roots=roots, expected=expected, home=home)
            if mode != "delete":
                validation = SafetyResult(False, "SAFE cleanup supports only confirmed permanent deletion")
            if not stat.S_ISREG(st.st_mode):
                validation = SafetyResult(False, "SAFE direct cleanup supports only regular files")
        else:
            allowed_root, exception_root, policy_error = _review_policy(item, path, home)
            if policy_error or allowed_root is None:
                results.append(ActionResult(path_text, mode, category, size, reason, False, policy_error or "review policy refused path"))
                continue
            validation = validate_cleanup_candidate(
                path, allowed_roots=[allowed_root], expected=expected, home=home,
                allow_root=allowed_root == path, protected_exception_root=exception_root,
            )
            if mode == "delete" and not stat.S_ISREG(st.st_mode):
                validation = SafetyResult(False, "permanent REVIEW deletion is limited to individual regular files")
        if not validation.allowed:
            results.append(ActionResult(path_text, mode, category, size, reason, False, validation.reason))
            continue

        try:
            if mode == "trash":
                destination = _unique_trash_path(trash, path)
                try:
                    os.rename(path, destination)
                except OSError as exc:
                    if exc.errno == errno.EXDEV:
                        raise OSError("cross-filesystem moves are refused; no copy-and-delete fallback is used") from exc
                    raise
                results.append(ActionResult(path_text, "move-to-trash", category, size, reason, True, "moved atomically to Trash", str(destination)))
            else:
                path.unlink()
                results.append(ActionResult(path_text, "permanent-delete", category, size, reason, True, "deleted after identity and containment revalidation"))
        except OSError as exc:
            results.append(ActionResult(path_text, mode, category, size, reason, False, str(exc)))

    after = shutil.disk_usage(home).free
    timestamp = datetime.now().astimezone()
    record = {
        "timestamp": timestamp.isoformat(timespec="seconds"),
        "macos_version": platform.mac_ver()[0],
        "classification": classification,
        "mode": mode,
        "before_available": before,
        "after_available": after,
        "reclaimed": max(0, after - before),
        "estimated_processed": sum(result.original_size for result in results if result.success),
        "results": [asdict(result) for result in results],
    }
    audit_path = audit_directory / f"{timestamp.strftime('%Y%m%d-%H%M%S-%f')}.json"
    temporary = audit_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(audit_path)
    record["audit_path"] = str(audit_path)
    return record


def list_history(home: Path | None = None, limit: int = 20) -> list[dict[str, Any]]:
    root = history_root(home)
    if not root.is_dir():
        return []
    records = []
    for path in sorted(root.glob("*.json"), reverse=True)[:limit]:
        try:
            records.append(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
    return records

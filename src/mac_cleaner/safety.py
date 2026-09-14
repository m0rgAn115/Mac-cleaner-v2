from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from .models import FileIdentity


@dataclass(frozen=True)
class SafetyResult:
    allowed: bool
    reason: str


SYSTEM_PROTECTED = tuple(Path(p) for p in (
    "/System", "/bin", "/sbin", "/usr", "/private", "/var", "/Library",
    "/Applications", "/cores", "/dev", "/etc", "/opt",
))

HOME_PROTECTED_RELATIVE = (
    ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config",
    "Documents", "Desktop", "Pictures", "Music",
    "Library/Keychains", "Library/Messages", "Library/Mail", "Library/Safari",
    "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
    "Library/CloudStorage", "Library/Application Support/CloudDocs",
    "Library/Photos", "Library/Application Support/MobileSync/Backup",
)

SENSITIVE_NAMES = {".env", ".git", ".gitconfig", ".netrc", ".npmrc", ".pypirc"}
CLOUD_NAMES = {"Dropbox", "OneDrive", "Google Drive", "iCloud Drive"}
GENERATED_NAMES = {"node_modules", ".venv", "venv", ".next", "build", "dist", "DerivedData"}


def _within(path: Path, root: Path) -> bool:
    path_text = os.path.normcase(os.path.normpath(str(path)))
    root_text = os.path.normcase(os.path.normpath(str(root)))
    return path_text == root_text or path_text.startswith(root_text.rstrip(os.sep) + os.sep)


def protected_reason(path: Path, home: Path | None = None, *, check_git: bool = True) -> str | None:
    """Return why a lexical absolute path is protected, without following it."""
    home = home or Path.home()
    absolute = Path(os.path.abspath(os.path.expanduser(str(path))))
    if absolute == Path("/"):
        return "filesystem root is always protected"
    if absolute == home:
        return "the home directory itself is always protected"
    for root in SYSTEM_PROTECTED:
        if _within(absolute, root):
            return f"inside protected system root {root}"
    for relative in HOME_PROTECTED_RELATIVE:
        root = home / relative
        if _within(absolute, root):
            return f"inside protected user data root {root}"
    if any(part in SENSITIVE_NAMES or part.startswith(".env.") for part in absolute.parts):
        return "credential, environment, or source-control data is protected"
    if ".app" in str(absolute).lower():
        cursor = Path(absolute.anchor)
        for part in absolute.parts[1:]:
            cursor /= part
            if part.endswith(".app") and (cursor / "Contents" / "Info.plist").exists():
                return "macOS application bundles are protected"
    if any(part.endswith((".photoslibrary", ".musiclibrary", ".photolibrary")) for part in absolute.parts):
        return "media library bundles are protected"
    if any(part in CLOUD_NAMES for part in absolute.parts):
        return "cloud-synchronized data is protected"
    # Source files in a Git worktree are protected. Explicitly recognized generated
    # directories remain REVIEW candidates and are never selected automatically.
    if check_git:
        try:
            relative_parts = absolute.relative_to(home).parts
        except ValueError:
            relative_parts = ()
        cursor = home
        for index, part in enumerate(relative_parts):
            cursor /= part
            if (cursor / ".git").exists():
                remainder = relative_parts[index + 1:]
                if not any(value in GENERATED_NAMES for value in remainder):
                    return f"source code inside Git worktree {cursor} is protected"
    return None


def validate_cleanup_candidate(
    raw_path: str | Path | None,
    *,
    allowed_roots: Iterable[Path],
    expected: FileIdentity | None = None,
    home: Path | None = None,
    allow_root: bool = False,
    protected_exception_root: Path | None = None,
) -> SafetyResult:
    """Central deletion gate used by dry-run reporting and the confirmed executor."""
    if raw_path is None or not str(raw_path).strip():
        return SafetyResult(False, "empty or unresolved path")
    home = (home or Path.home()).absolute()
    lexical = Path(os.path.abspath(os.path.expanduser(str(raw_path))))
    reason = protected_reason(lexical, home)
    exception_root = None
    if protected_exception_root is not None:
        try:
            exception_root = protected_exception_root.expanduser().resolve(strict=True)
        except OSError:
            return SafetyResult(False, "protected exception root cannot be resolved")
    exception_applies = exception_root is not None and lexical.parent == exception_root
    if reason and not exception_applies:
        return SafetyResult(False, reason)
    try:
        current = lexical
        while True:
            st = current.lstat()
            if stat.S_ISLNK(st.st_mode):
                return SafetyResult(False, f"symlink in path: {current}")
            if current == current.parent:
                break
            current = current.parent
        resolved = lexical.resolve(strict=True)
        st = lexical.lstat()
    except OSError as exc:
        return SafetyResult(False, f"cannot safely resolve/stat path: {exc}")
    roots: list[Path] = []
    for root in allowed_roots:
        try:
            resolved_root = root.expanduser().resolve(strict=True)
        except OSError:
            continue
        if resolved_root in (Path("/"), home):
            continue
        if protected_reason(resolved_root, home) and resolved_root != exception_root and not exception_applies:
            continue
        roots.append(resolved_root)
    if not roots or not any(_within(resolved, root) and (allow_root or resolved != root) for root in roots):
        return SafetyResult(False, "path is not a descendant of an allowed cleanup root")
    if expected is not None:
        actual = FileIdentity(st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
        if actual != expected:
            return SafetyResult(False, "filesystem object changed since it was scanned")
    return SafetyResult(True, "candidate passed centralized safety checks")

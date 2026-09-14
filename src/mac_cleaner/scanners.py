from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
import platform
import pwd
import re
import shutil
import subprocess
import time
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable

from .config import Config
from .fs import allocated_size, directory_size, du_size, iter_files
from .models import Classification, ScanItem, ScanReport
from .safety import protected_reason


INSTALLER_EXTENSIONS = {".dmg", ".pkg", ".iso"}
ARCHIVE_EXTENSIONS = {".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar"}
VIDEO_EXTENSIONS = {".mov", ".mp4", ".m4v", ".mkv", ".avi", ".webm"}
DATA_EXTENSIONS = {".csv", ".parquet", ".sqlite", ".db", ".jsonl", ".h5", ".hdf5"}


def _run(args: list[str], timeout: float = 15) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None


def _human_command(args: list[str]) -> str:
    return " ".join(args)


def _parse_size(text: str) -> int:
    text = text.strip().upper().replace("IB", "B")
    units = {"B": 1, "KB": 1000, "MB": 1000**2, "GB": 1000**3, "TB": 1000**4}
    for suffix in ("TB", "GB", "MB", "KB", "B"):
        if text.endswith(suffix):
            try:
                return int(float(text[:-len(suffix)]) * units[suffix])
            except ValueError:
                return 0
    return 0


def _is_cloud_placeholder(path: Path, st: os.stat_result) -> bool:
    return path.suffix == ".icloud" or (st.st_size > 0 and getattr(st, "st_blocks", 1) == 0)


@dataclass
class ScanContext:
    config: Config
    home: Path = field(default_factory=Path.home)
    now: float = field(default_factory=time.time)
    notices: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    open_paths: set[str] = field(default_factory=set)

    @property
    def uid(self) -> int:
        return os.getuid()

    def ignored(self, path: Path, category: str) -> bool:
        return self.config.is_ignored(path, category)


def platform_info() -> dict[str, str]:
    version = platform.mac_ver()[0]
    sw = _run(["/usr/bin/sw_vers", "-buildVersion"], timeout=3)
    return {
        "system": platform.system(),
        "macos_version": version,
        "build": sw.stdout.strip() if sw and sw.returncode == 0 else "unknown",
        "architecture": platform.machine(),
        "python": platform.python_version(),
    }


def collect_open_paths(ctx: ScanContext) -> None:
    lsof = shutil.which("lsof")
    if not lsof:
        ctx.notices.append("lsof is unavailable; open-file exclusion could not be checked.")
        return
    username = pwd.getpwuid(ctx.uid).pw_name
    # -nP avoids slow hostname/service resolution. Restricting to ordinary file
    # descriptors plus cwd/text/memory mappings keeps this practical on busy Macs.
    result = _run([lsof, "-nP", "-Fn", "-a", "-u", username,
                   "-d", "0-1024,cwd,txt,mem"], timeout=12)
    if result is None:
        ctx.notices.append("lsof timed out; age checks still apply, but open-file exclusion was unavailable.")
        return
    if result.returncode not in (0, 1):
        ctx.notices.append("lsof could not enumerate open files; age checks still apply.")
        return
    ctx.open_paths = {line[1:] for line in result.stdout.splitlines() if line.startswith("n/")}


def _safe_old_files(
    ctx: ScanContext,
    root: Path,
    *,
    category: str,
    age_days: int,
    reason: str,
    action: str,
    owner_from_root: bool = False,
    max_candidates: int | None = None,
) -> list[ScanItem]:
    items: list[ScanItem] = []
    cutoff = ctx.now - age_days * 86400
    if not root.is_dir() or root.is_symlink():
        return items
    for path, st in iter_files(root):
        if st.st_uid != ctx.uid or st.st_mtime > cutoff:
            continue
        if str(path) in ctx.open_paths or ctx.ignored(path, category):
            continue
        if protected_reason(path, ctx.home, check_git=False):
            continue
        try:
            relative = path.relative_to(root)
            owner = relative.parts[0] if owner_from_root and relative.parts else None
        except ValueError:
            owner = None
        items.append(ScanItem.from_path(
            path, category=category, classification=Classification.SAFE,
            size=allocated_size(st), reason=f"{reason}; unchanged for at least {age_days} days",
            proposed_action=action, owner=owner,
            metadata={"cleanup_root": str(root), "execution_kind": "direct-file", "actionable": True},
        ))
        limit = max_candidates or ctx.config.max_safe_candidates_per_root
        if len(items) >= limit:
            ctx.notices.append(
                f"Stopped enumerating {category} at {limit:,} candidates under {root}; "
                "unlisted files are excluded from the reclaimable estimate."
            )
            break
    return items


def scan_safe(ctx: ScanContext) -> list[ScanItem]:
    items: list[ScanItem] = []
    collect_open_paths(ctx)
    # Run specific scanners first, then prevent broad Library scans from counting
    # the same filesystem object a second time.
    items += scan_package_caches(ctx)
    for crash_root in (ctx.home / "Library/Logs/DiagnosticReports", ctx.home / "Library/Logs/CrashReporter"):
        items += _safe_old_files(
            ctx, crash_root, category="Crash reports", age_days=ctx.config.crash_age_days,
            reason="Old user diagnostic report", action="Delete this report after confirmation",
        )
    seen = {item.path for item in items}
    covered_roots = [Path(item.path) for item in items if item.path.startswith("/") and Path(item.path).is_dir()]
    cache_items = _safe_old_files(
        ctx, ctx.home / "Library/Caches", category="App caches",
        age_days=ctx.config.cache_age_days,
        reason="User-owned regenerable application cache file",
        action="Delete this old cache file after confirmation", owner_from_root=True,
    )
    items += [item for item in cache_items
              if item.path not in seen and not any(root == Path(item.path) or root in Path(item.path).parents for root in covered_roots)]
    seen.update(item.path for item in items)
    log_items = _safe_old_files(
        ctx, ctx.home / "Library/Logs", category="Old logs",
        age_days=ctx.config.log_age_days,
        reason="Old user log file; recent and open logs are retained",
        action="Delete this old log file after confirmation", owner_from_root=True,
    )
    items += [item for item in log_items if item.path not in seen]
    developer = ctx.home / "Library/Developer/Xcode"
    items += _safe_old_files(
        ctx, developer / "DerivedData", category="Xcode DerivedData",
        age_days=ctx.config.cache_age_days,
        reason="Regenerable Xcode build output", action="Delete this old DerivedData file after confirmation",
        owner_from_root=True,
    )
    for relative, category in (
        ("Library/Developer/Xcode/DocumentationCache", "Xcode documentation cache"),
        ("Library/Developer/Xcode/ModuleCache.noindex", "Xcode module cache"),
    ):
        items += _safe_old_files(
            ctx, ctx.home / relative, category=category, age_days=ctx.config.cache_age_days,
            reason="Regenerable Xcode cache", action="Delete this old Xcode cache file after confirmation",
        )
    items += scan_unavailable_simulators(ctx)
    temp = _run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], timeout=3)
    if temp and temp.returncode == 0 and temp.stdout.strip():
        temp_path = Path(temp.stdout.strip())
        size = du_size(temp_path, timeout=20)
        if size:
            items.append(ScanItem.from_path(
                temp_path, category="User temporary data", classification=Classification.PROTECTED,
                size=size, reason="The per-user Darwin temp directory resolves inside /private; policy refuses to clean protected system roots",
                proposed_action="Report only; do not modify",
            ))
    return items


def scan_package_caches(ctx: ScanContext) -> list[ScanItem]:
    items: list[ScanItem] = []
    sources: list[tuple[Path, str, str, str]] = []
    brew = shutil.which("brew")
    if brew:
        result = _run([brew, "--cache"], timeout=8)
        brew_cache = Path(result.stdout.strip()) if result and result.returncode == 0 else None
        preview = _run([brew, "cleanup", "--dry-run"], timeout=25)
        official_count = 0
        if preview and preview.stdout.strip():
            ctx.notices.append("Homebrew official cleanup preview:\n" + preview.stdout.strip()[:4000])
            for line in preview.stdout.splitlines():
                match = re.match(r"Would remove: (.+?) \((?:.*?,\s*)?([0-9.]+\s*[KMGT]?B)\)$", line.strip(), re.IGNORECASE)
                if not match:
                    continue
                candidate = Path(match.group(1))
                size = _parse_size((match.group(2) or "0B").replace(" ", ""))
                items.append(ScanItem.from_path(
                    candidate, category="Homebrew official cleanup", classification=Classification.SAFE,
                    size=size, reason="Homebrew itself identified this as stale in `brew cleanup --dry-run`",
                    proposed_action="Use official command after confirmation: brew cleanup",
                    metadata={"execution_kind": "supported-manager", "manager": "Homebrew", "actionable": True},
                ))
                official_count += 1
        if brew_cache and official_count == 0:
            sources.append((brew_cache, "Homebrew cache", "Homebrew download cache", "brew cleanup --prune=30"))
    npm = shutil.which("npm")
    if npm:
        result = _run([npm, "config", "get", "cache"], timeout=8)
        if result and result.returncode == 0:
            sources.append((Path(result.stdout.strip()), "npm cache", "npm's regenerable content-addressed cache", "npm cache clean --force"))
    pnpm = shutil.which("pnpm")
    if pnpm:
        result = _run([pnpm, "store", "path"], timeout=8)
        if result and result.returncode == 0:
            sources.append((Path(result.stdout.strip()), "pnpm store", "pnpm package store", "pnpm store prune"))
    pip_result = _run([shutil.which("python3") or "python3", "-m", "pip", "cache", "dir"], timeout=8)
    if pip_result and pip_result.returncode == 0:
        sources.append((Path(pip_result.stdout.strip()), "Python package cache", "pip's regenerable download/wheel cache", "python3 -m pip cache purge"))
    seen: set[Path] = set()
    cutoff = ctx.now - ctx.config.cache_age_days * 86400
    for root, category, reason, action in sources:
        root = Path(os.path.abspath(os.path.expanduser(str(root))))
        if root in seen:
            continue
        seen.add(root)
        if not root.is_dir() or root.is_symlink():
            continue
        try:
            entries = list(root.iterdir())
        except OSError:
            continue
        for entry in entries:
            try:
                st = entry.lstat()
            except OSError:
                continue
            if entry.is_symlink() or st.st_uid != ctx.uid or st.st_mtime > cutoff:
                continue
            if ctx.ignored(entry, category) or protected_reason(entry, ctx.home, check_git=False):
                continue
            size = du_size(entry, timeout=30)
            if size is None:
                continue
            items.append(ScanItem.from_path(
                entry, category=category, classification=Classification.REVIEW,
                size=size, reason=f"{reason}; top-level cache entry unchanged for at least {ctx.config.cache_age_days} days",
                proposed_action=f"Review this cache; the broad official command would be: {action}",
                metadata={"execution_kind": "supported-manager", "manager": action.split()[0], "actionable": False},
            ))
    return items


def scan_unavailable_simulators(ctx: ScanContext) -> list[ScanItem]:
    xcrun = shutil.which("xcrun")
    if not xcrun:
        return []
    result = _run([xcrun, "simctl", "list", "devices", "unavailable", "-j"], timeout=15)
    if not result or result.returncode != 0:
        return []
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []
    devices = [device for group in data.get("devices", {}).values() for device in group]
    if not devices:
        return []
    total = 0
    paths: list[str] = []
    for device in devices:
        raw = device.get("dataPath")
        if raw:
            path = Path(raw)
            paths.append(str(path))
            total += du_size(path, timeout=15) or 0
    return [ScanItem(
        path="xcrun://simctl/unavailable", category="Unavailable Xcode simulators",
        classification=Classification.SAFE, size=total,
        reason=f"{len(devices)} simulator device(s) reported unavailable by Apple's simctl",
        proposed_action="Run supported command after confirmation: xcrun simctl delete unavailable",
        metadata={"device_names": [d.get("name") for d in devices], "data_paths": paths,
                  "execution_kind": "supported-manager", "manager": "xcrun simctl", "actionable": True},
    )]


def scan_home_breakdown(ctx: ScanContext) -> tuple[int | None, list[dict[str, object]]]:
    try:
        children = [p for p in ctx.home.iterdir() if not p.is_symlink()]
    except OSError as exc:
        ctx.errors.append(f"Cannot list home directory: {exc}")
        return None, []
    def measure(path: Path) -> tuple[Path, int | None]:
        return path, du_size(path, timeout=90)
    measured: list[tuple[Path, int | None]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        for result in executor.map(measure, children):
            measured.append(result)
    breakdown = []
    for path, size in measured:
        if size is None:
            continue
        reason = protected_reason(path, ctx.home)
        breakdown.append({
            "path": str(path), "size": size,
            "policy": "PROTECTED" if reason else "STATS ONLY",
            "reason": reason or "Included only to explain storage consumption",
        })
    breakdown.sort(key=lambda row: int(row["size"]), reverse=True)
    sizes = [int(row["size"]) for row in breakdown]
    return sum(sizes) if sizes else None, breakdown


def _download_kind(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in INSTALLER_EXTENSIONS:
        return "installers/disk images"
    if suffix in ARCHIVE_EXTENSIONS:
        return "archives"
    if suffix in VIDEO_EXTENSIONS:
        return "videos"
    if suffix in DATA_EXTENSIONS:
        return "datasets"
    return "large or old files"


def scan_downloads(ctx: ScanContext) -> list[ScanItem]:
    root = ctx.home / "Downloads"
    root_reason = protected_reason(root, ctx.home)
    if root_reason and root.exists():
        size = du_size(root, timeout=60) or 0
        return [ScanItem.from_path(
            root, category="Protected user data", classification=Classification.PROTECTED,
            size=size, reason=f"Downloads analysis was suppressed because {root_reason}",
            proposed_action="Report size only; refuse cleanup",
        )]
    cutoff = ctx.now - ctx.config.download_age_days * 86400
    items: list[ScanItem] = []
    for path, st in iter_files(root):
        if _is_cloud_placeholder(path, st) or ctx.ignored(path, "Downloads"):
            continue
        kind = _download_kind(path)
        notable = (st.st_size >= ctx.config.large_file_bytes or st.st_mtime <= cutoff
                   or path.suffix.lower() in INSTALLER_EXTENSIONS | ARCHIVE_EXTENSIONS)
        if not notable:
            continue
        facts = []
        if st.st_size >= ctx.config.large_file_bytes:
            facts.append("large")
        if st.st_mtime <= cutoff:
            facts.append(f"older than {ctx.config.download_age_days} days")
        if path.suffix.lower() in INSTALLER_EXTENSIONS | ARCHIVE_EXTENSIONS:
            facts.append(kind)
        items.append(ScanItem.from_path(
            path, category=f"Downloads — {kind}", classification=Classification.REVIEW,
            size=allocated_size(st), reason="Download is " + ", ".join(facts),
            proposed_action="Ignore, reveal in Finder, move to Trash, or explicitly request permanent deletion",
            metadata={"actionable": True, "execution_kind": "review-path"},
        ))
    return items


def _review_directory(
    path: Path, category: str, reason: str, action: str,
    *, actionable: bool = True,
) -> ScanItem | None:
    if not path.exists() or path.is_symlink():
        return None
    size = du_size(path, timeout=45)
    if size is None:
        return None
    return ScanItem.from_path(path, category=category, classification=Classification.REVIEW,
                              size=size, reason=reason, proposed_action=action,
                              metadata={"actionable": actionable, "execution_kind": "review-path"})


def scan_review_locations(ctx: ScanContext) -> list[ScanItem]:
    items = scan_downloads(ctx)
    trash = _review_directory(ctx.home / ".Trash", "Trash", "Trash may still contain wanted files",
                              "Review in Finder; empty only after explicit confirmation", actionable=False)
    if trash:
        items.append(trash)
    backup_root = ctx.home / "Library/Application Support/MobileSync/Backup"
    if backup_root.is_dir() and not backup_root.is_symlink():
        try:
            backups = [p for p in backup_root.iterdir() if p.is_dir() and not p.is_symlink()]
        except OSError:
            backups = []
        for backup in backups:
            item = _review_directory(backup, "iPhone/iPad backups", "Local device backup may be irreplaceable",
                                     "Review using Finder's device backup management")
            if item:
                items.append(item)
    archives = ctx.home / "Library/Developer/Xcode/Archives"
    if archives.is_dir():
        try:
            archive_paths = [p for p in archives.rglob("*.xcarchive") if not p.is_symlink()]
        except OSError:
            archive_paths = []
        for archive in archive_paths:
            item = _review_directory(archive, "Xcode Archives", "Signed build archive may be needed for symbolication or distribution",
                                     "Review in Xcode Organizer; never automatic")
            if item:
                items.append(item)
    items += scan_time_machine(ctx)
    items += scan_docker(ctx)
    items += scan_xcode_review(ctx)
    return items


def scan_xcode_review(ctx: ScanContext) -> list[ScanItem]:
    items: list[ScanItem] = []
    device_support = ctx.home / "Library/Developer/Xcode/iOS DeviceSupport"
    if device_support.is_dir() and not device_support.is_symlink():
        try:
            versions = [p for p in device_support.iterdir() if p.is_dir() and not p.is_symlink()]
        except OSError:
            versions = []
        for version in versions:
            item = _review_directory(
                version, "Xcode device support", "May be needed to debug connected devices running this OS version",
                "Review installed/used device versions in Xcode; never automatic",
            )
            if item:
                items.append(item)
    xcrun = shutil.which("xcrun")
    if not xcrun:
        return items
    result = _run([xcrun, "simctl", "list", "runtimes", "-j"], timeout=15)
    if not result or result.returncode != 0:
        return items
    try:
        runtimes = json.loads(result.stdout).get("runtimes", [])
    except json.JSONDecodeError:
        return items
    for runtime in runtimes:
        raw_path = runtime.get("bundlePath") or runtime.get("path")
        if not raw_path:
            continue
        path = Path(raw_path)
        size = du_size(path, timeout=45) or 0
        items.append(ScanItem.from_path(
            path, category="Xcode simulator runtimes", classification=Classification.REVIEW,
            size=size, reason=f"Installed simulator runtime {runtime.get('name', runtime.get('identifier', 'unknown'))}; may still be needed",
            proposed_action="Review and uninstall through Xcode Settings > Platforms; never delete the bundle directly",
            metadata={"identifier": runtime.get("identifier"), "available": runtime.get("isAvailable"),
                      "actionable": False},
        ))
    return items


def scan_time_machine(ctx: ScanContext) -> list[ScanItem]:
    tmutil = shutil.which("tmutil")
    if not tmutil:
        return []
    result = _run([tmutil, "listlocalsnapshots", "/"], timeout=15)
    if not result or result.returncode != 0:
        return []
    snapshots = [line.strip() for line in result.stdout.splitlines() if line.strip() and not line.startswith("Snapshots for")]
    if not snapshots:
        return []
    return [ScanItem(
        path=f"tmutil://local-snapshots/{snapshot}", category="Time Machine local snapshots",
        classification=Classification.REVIEW, size=0,
        reason="macOS normally manages local snapshots automatically; size is not reliably exposed by tmutil",
        proposed_action="Use only a supported tmutil deletion/thinning command after explicit selection",
        metadata={"snapshot": snapshot, "size_known": False, "actionable": False},
    ) for snapshot in snapshots]


def scan_docker(ctx: ScanContext) -> list[ScanItem]:
    docker = shutil.which("docker")
    if not docker:
        return []
    result = _run([docker, "system", "df", "--format", "{{json .}}"], timeout=15)
    if not result or result.returncode != 0:
        ctx.notices.append("Docker CLI exists, but the daemon did not provide storage usage.")
        return []
    items: list[ScanItem] = []
    for line in result.stdout.splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = row.get("Type", "Docker data")
        size = _parse_size(str(row.get("Size", "0B")))
        reclaimable_text = str(row.get("Reclaimable", "0B")).split()[0]
        reclaimable = _parse_size(reclaimable_text)
        category = f"Docker — {kind}"
        reason = f"Docker reports {row.get('Size', 'unknown')} total and {row.get('Reclaimable', 'unknown')} reclaimable"
        if str(kind).lower() == "volumes":
            action = "Inspect named volumes individually; volumes are never automatically removed"
        elif "build" in str(kind).lower():
            action = "Review build cache; offer a separate confirmed builder prune only"
        else:
            action = "Inspect Docker objects individually; never run broad automatic prune"
        estimated_reclaimable = reclaimable if "Reclaimable" in row else size
        items.append(ScanItem(
            path=f"docker://{str(kind).lower().replace(' ', '-')}", category=category,
            classification=Classification.REVIEW, size=estimated_reclaimable,
            reason=reason, proposed_action=action,
            metadata={"total": row.get("Size"), "reclaimable": row.get("Reclaimable"),
                      "count": row.get("TotalCount"), "actionable": False},
        ))
    return items


def _project_roots(home: Path) -> list[Path]:
    names = ("Developer", "Develop", "Projects", "projects", "Proyectos", "Code", "code", "Sites", "src", "workspace")
    roots = [home / name for name in names if (home / name).is_dir() and not (home / name).is_symlink()]
    cwd = Path.cwd()
    if home in cwd.parents and cwd not in roots and not protected_reason(cwd, home):
        roots.append(cwd)
    unique: list[Path] = []
    for root in roots:
        if not any(root == existing or existing in root.parents for existing in unique):
            unique.append(root)
    return unique


def scan_developer(ctx: ScanContext) -> list[ScanItem]:
    targets = {"node_modules", ".venv", "venv", ".next", "build", "dist", ".gradle"}
    items: list[ScanItem] = []
    seen: set[Path] = set()
    for root in _project_roots(ctx.home):
        root_depth = len(root.parts)
        for directory, dirnames, _ in os.walk(root, topdown=True, followlinks=False):
            current = Path(directory)
            depth = len(current.parts) - root_depth
            dirnames[:] = [name for name in dirnames if name not in {".git", ".svn", ".hg"}]
            if depth >= 7:
                dirnames[:] = []
                continue
            for name in list(dirnames):
                candidate = current / name
                if candidate.is_symlink():
                    dirnames.remove(name)
                    continue
                if name not in targets:
                    continue
                dirnames.remove(name)
                if candidate in seen or ctx.ignored(candidate, "Developer generated data"):
                    continue
                seen.add(candidate)
                size = du_size(candidate, timeout=45)
                if size is None:
                    continue
                marker_parent = current
                project = next((p for p in [marker_parent, *marker_parent.parents]
                                if p == root or any((p / marker).exists() for marker in (".git", "package.json", "pyproject.toml", "build.gradle"))), marker_parent)
                items.append(ScanItem.from_path(
                    candidate, category=f"Developer — {name}", classification=Classification.REVIEW,
                    size=size, reason=f"Generated/dependency directory in project {project}; may be expensive or impossible to reproduce",
                    proposed_action="Review project state, then optionally move this directory to Trash",
                    metadata={"project": str(project), "actionable": True, "execution_kind": "review-path"},
                ))
    gradle = ctx.home / ".gradle/caches"
    if gradle.exists() and not ctx.ignored(gradle, "Gradle cache"):
        item = _review_directory(gradle, "Gradle cache", "Regenerable in principle, but may contain costly offline dependencies",
                                 "Review; use Gradle-supported cleanup where available")
        if item:
            items.append(item)
    return items


def scan_large_files(ctx: ScanContext) -> list[ScanItem]:
    """Scan bounded, non-protected user locations; Downloads are handled separately."""
    roots = [ctx.home / "Public", ctx.home / "Movies"]
    items: list[ScanItem] = []
    cutoff = ctx.now - ctx.config.old_file_days * 86400
    for root in roots:
        for path, st in iter_files(root):
            if st.st_size < ctx.config.large_file_bytes or _is_cloud_placeholder(path, st):
                continue
            if protected_reason(path, ctx.home):
                continue
            if ctx.ignored(path, "Large files"):
                continue
            facts = ["at least 50 MB"]
            if st.st_size >= ctx.config.very_large_file_bytes:
                facts.append("very large (at least 1 GB)")
            if st.st_mtime <= cutoff:
                facts.append(f"older than {ctx.config.old_file_days} days")
            items.append(ScanItem.from_path(
                path, category="Large files", classification=Classification.REVIEW,
                size=allocated_size(st), reason=", ".join(facts),
                proposed_action="Ignore, reveal in Finder, move to Trash, or explicitly request permanent deletion",
                metadata={"actionable": True, "execution_kind": "review-path"},
            ))
    return items


def scan_protected_roots(ctx: ScanContext) -> list[ScanItem]:
    rows: list[ScanItem] = []
    candidates = [
        ctx.home / ".ssh", ctx.home / ".aws", ctx.home / ".config",
        ctx.home / "Documents", ctx.home / "Desktop", ctx.home / "Applications",
        ctx.home / "Pictures", ctx.home / "Music", ctx.home / "Library/Keychains",
        ctx.home / "Library/Messages", ctx.home / "Library/Mail", ctx.home / "Library/Safari",
        ctx.home / "Library/Containers", ctx.home / "Library/Group Containers",
        ctx.home / "Library/Mobile Documents", ctx.home / "Library/CloudStorage",
        ctx.home / "Dropbox", ctx.home / "OneDrive", ctx.home / "Google Drive",
    ]
    for path in candidates:
        if not path.exists() or path.is_symlink() or ctx.ignored(path, "Protected"):
            continue
        size = du_size(path, timeout=60)
        if size is None:
            continue
        rows.append(ScanItem.from_path(
            path, category="Protected user data", classification=Classification.PROTECTED,
            size=size, reason=protected_reason(path, ctx.home) or "Sensitive personal data",
            proposed_action="Report size only; refuse cleanup",
        ))
    return rows


def scan_all(config: Config, *, developer: bool = False, large: bool = False) -> ScanReport:
    ctx = ScanContext(config=config)
    disk = shutil.disk_usage(ctx.home)
    home_size, breakdown = scan_home_breakdown(ctx)
    items = scan_safe(ctx)
    items += scan_review_locations(ctx)
    if developer:
        items += scan_developer(ctx)
    if large:
        items += scan_large_files(ctx)
    items += scan_protected_roots(ctx)
    items.sort(key=lambda item: (item.classification.value, item.category, -item.size, item.path))
    return ScanReport(
        generated_at=datetime.now().astimezone().isoformat(timespec="seconds"),
        platform=platform_info(),
        storage={"capacity": disk.total, "used": disk.used, "available": disk.free},
        home_size=home_size, home_breakdown=breakdown, items=items,
        notices=ctx.notices, errors=ctx.errors,
    )


def _sample_hash(path: Path, size: int) -> bytes:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        digest.update(handle.read(65536))
        if size > 65536:
            handle.seek(max(0, size - 65536))
            digest.update(handle.read(65536))
    return digest.digest()


def _full_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def scan_duplicates(config: Config, roots: Iterable[Path] | None = None) -> ScanReport:
    ctx = ScanContext(config=config)
    roots = list(roots or [ctx.home / "Downloads"])
    by_size: dict[int, list[tuple[Path, os.stat_result]]] = defaultdict(list)
    seen_inodes: set[tuple[int, int]] = set()
    for root in roots:
        absolute = Path(os.path.abspath(os.path.expanduser(str(root))))
        reason = protected_reason(absolute, ctx.home)
        if reason:
            ctx.notices.append(f"Skipped duplicate scan of {absolute}: {reason}")
            continue
        for path, st in iter_files(absolute):
            if st.st_size == 0 or _is_cloud_placeholder(path, st) or ctx.ignored(path, "Duplicates"):
                continue
            inode = (st.st_dev, st.st_ino)
            if inode in seen_inodes:
                continue
            seen_inodes.add(inode)
            by_size[st.st_size].append((path, st))
    sample_groups: dict[tuple[int, bytes], list[tuple[Path, os.stat_result]]] = defaultdict(list)
    for size, candidates in by_size.items():
        if len(candidates) < 2:
            continue
        for path, st in candidates:
            try:
                sample_groups[(size, _sample_hash(path, size))].append((path, st))
            except OSError:
                continue
    full_groups: dict[tuple[int, str], list[tuple[Path, os.stat_result]]] = defaultdict(list)
    for (size, _), candidates in sample_groups.items():
        if len(candidates) < 2:
            continue
        for path, st in candidates:
            try:
                full_groups[(size, _full_hash(path))].append((path, st))
            except OSError:
                continue
    items: list[ScanItem] = []
    for (size, digest), candidates in full_groups.items():
        if len(candidates) < 2:
            continue
        group = str(uuid.uuid4())
        for index, (path, st) in enumerate(sorted(candidates, key=lambda pair: str(pair[0]))):
            items.append(ScanItem.from_path(
                path, category="Duplicates", classification=Classification.REVIEW,
                size=0 if index == 0 else allocated_size(st),
                reason=f"Byte-identical SHA-256 duplicate group; one copy is retained in the estimate ({digest[:12]}…)",
                proposed_action="Choose a copy manually; default is Ignore",
                metadata={"duplicate_group": group, "sha256": digest, "suggested_keep": index == 0,
                          "logical_size": size, "actionable": True, "execution_kind": "review-path"},
            ))
    disk = shutil.disk_usage(ctx.home)
    return ScanReport(
        generated_at=datetime.now().astimezone().isoformat(timespec="seconds"),
        platform=platform_info(), storage={"capacity": disk.total, "used": disk.used, "available": disk.free},
        home_size=None, items=items, notices=ctx.notices, errors=ctx.errors,
    )

from __future__ import annotations

import os
import stat
import subprocess
from collections.abc import Iterator
from pathlib import Path


def allocated_size(st: os.stat_result) -> int:
    blocks = getattr(st, "st_blocks", 0)
    return blocks * 512 if blocks else st.st_size


def iter_files(root: Path, *, skip: set[Path] | None = None, max_depth: int | None = None) -> Iterator[tuple[Path, os.stat_result]]:
    """Walk without following symlinks; inaccessible entries are skipped."""
    if not root.is_dir() or root.is_symlink():
        return
    skip = skip or set()
    root_depth = len(root.parts)
    stack = [root]
    while stack:
        directory = stack.pop()
        try:
            entries = list(os.scandir(directory))
        except OSError:
            continue
        for entry in entries:
            path = Path(entry.path)
            if path in skip:
                continue
            try:
                if entry.is_symlink():
                    continue
                st = entry.stat(follow_symlinks=False)
                if stat.S_ISREG(st.st_mode):
                    yield path, st
                elif stat.S_ISDIR(st.st_mode):
                    depth = len(path.parts) - root_depth
                    if max_depth is None or depth < max_depth:
                        stack.append(path)
            except OSError:
                continue


def directory_size(root: Path) -> int:
    if root.is_file() and not root.is_symlink():
        try:
            return allocated_size(root.stat(follow_symlinks=False))
        except OSError:
            return 0
    return sum(allocated_size(st) for _, st in iter_files(root))


def du_size(path: Path, timeout: float = 45) -> int | None:
    """Use macOS du for fast aggregate reporting; never follows symlinks."""
    try:
        result = subprocess.run(
            ["/usr/bin/du", "-sk", "-x", str(path)], capture_output=True,
            text=True, timeout=timeout, check=False,
        )
        if result.returncode not in (0, 1) or not result.stdout:
            return None
        return int(result.stdout.split()[0]) * 1024
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


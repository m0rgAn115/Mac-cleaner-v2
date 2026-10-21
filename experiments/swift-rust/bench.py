#!/usr/bin/env python3
"""Metadata-only, read-only scanner benchmark. Python 3 standard library only."""
import argparse
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import time

BASE = Path(__file__).resolve().parent
FIELDS = ("files", "dirs", "links", "bytes", "selected", "selected_bytes", "errors")
SHAPES = {"small": (8, 2, 32), "wide": (16, 1, 1536), "nested": (16, 36, 64)}


def fixture(name, shape):
    root = BASE / "generated" / name
    marker = root / "complete.json"
    if marker.exists():
        assert json.loads(marker.read_text())["shape"] == list(shape)
        return root
    root.mkdir(parents=True, exist_ok=True)
    categories, folders, count = shape
    for category in range(categories):
        parent = root / f"category-{category:02}"
        parent.mkdir(exist_ok=True)
        for folder in range(folders):
            directory = parent / (f"level-{folder // 3:02}/child-{folder:02}" if name == "nested" else f"group-{folder:02}")
            directory.mkdir(parents=True, exist_ok=True)
            for i in range(count):
                suffix = ("cache", "log", "dat")[i % 3]
                size = (0, 64, 10240, 10241, 65536, 131072)[(i + folder + category) % 6]
                path = directory / f"archivo-é-{i:05}.{suffix}"
                with path.open("wb") as stream:
                    if size:
                        stream.write(b"x" * min(size, 64))
                        stream.truncate(size)
            (directory / ".DS_Store").write_bytes(b"ignored")
        protected = parent / ".protected"
        protected.mkdir(exist_ok=True)
        (protected / "must-not-select.cache").write_bytes(b"keep")
        for link, target in (("loop", parent), ("excluded-link", protected), ("broken", parent / "missing")):
            path = parent / link
            if not path.is_symlink():
                path.symlink_to(target, target_is_directory=True)
        # Two names for one inode: this benchmark counts directory entries, not unique disk blocks.
        original = next(parent.rglob("*.cache"))
        hardlink = parent / "hardlink.cache"
        if not hardlink.exists():
            hardlink.hardlink_to(original)
    marker.write_text(json.dumps({"shape": shape}))
    return root


def reference(root):
    result = dict.fromkeys(FIELDS, 0)
    pending = sorted(p for p in root.iterdir() if p.is_dir())
    while pending:
        directory = pending.pop()
        result["dirs"] += 1
        with os.scandir(directory) as entries:
            for entry in entries:
                if entry.name in (".DS_Store", ".protected"):
                    continue
                if entry.is_symlink():
                    result["links"] += 1
                elif entry.is_dir(follow_symlinks=False):
                    pending.append(Path(entry.path))
                elif entry.is_file(follow_symlinks=False):
                    size = entry.stat(follow_symlinks=False).st_size
                    result["files"] += 1
                    result["bytes"] += size
                    if (entry.name.endswith(".log") and size > 10240) or (entry.name.endswith(".cache") and size > 0):
                        result["selected"] += 1
                        result["selected_bytes"] += size
    return result


def measured(command):
    # wait4 supplies CPU and peak RSS per child without sampling or requiring kern.clockrate.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        started = time.perf_counter()
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
        _, status, usage = os.wait4(process.pid, 0)
        elapsed = time.perf_counter() - started
        process.returncode = os.waitstatus_to_exitcode(status)
        stdout.seek(0)
        stderr.seek(0)
        if process.returncode:
            raise RuntimeError(stderr.read().decode())
        result = json.loads(stdout.read())
    # On macOS ru_maxrss is bytes, unlike Linux's KiB.
    return result | {"wall_seconds": elapsed, "cpu_seconds": usage.ru_utime + usage.ru_stime,
                     "peak_rss_bytes": usage.ru_maxrss}


def build():
    (BASE / "bin").mkdir(exist_ok=True)
    (BASE / "module-cache").mkdir(exist_ok=True)
    commands = {
        "rust": ["rustc", "--edition=2021", "-C", "opt-level=3", "-C", "codegen-units=1", "-C", "lto=thin", str(BASE / "scanner.rs"), "-o", str(BASE / "bin/rust")],
        "swift": ["xcrun", "swiftc", "-O", "-whole-module-optimization", "-module-cache-path", str(BASE / "module-cache"), str(BASE / "scanner.swift"), "-o", str(BASE / "bin/swift")],
        "librust.a": ["rustc", "--edition=2021", "--crate-type=staticlib", "-C", "opt-level=3", "-C", "codegen-units=1", "-C", "lto=thin", str(BASE / "bridge.rs"), "-o", str(BASE / "bin/librust.a")],
        "swift-rust": ["xcrun", "swiftc", "-O", "-whole-module-optimization", "-module-cache-path", str(BASE / "module-cache"), "-import-objc-header", str(BASE / "bridge.h"), str(BASE / "bridge.swift"), str(BASE / "bin/librust.a"), "-o", str(BASE / "bin/swift-rust")],
    }
    builds = {}
    for language, command in commands.items():
        started = time.perf_counter()
        subprocess.run(command, check=True)
        builds[language] = {"command": command, "seconds": time.perf_counter() - started,
                            "binary_bytes": (BASE / "bin" / language).stat().st_size}
    return builds


def command(engine, root, workers):
    if engine == "rust-std":
        return [str(BASE / "bin/rust"), str(root), str(workers)]
    if engine == "swift-rust":
        return [str(BASE / "bin/swift-rust"), str(root), str(workers)]
    return [str(BASE / "bin/swift"), str(root), str(workers), engine.removeprefix("swift-")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument("--cpu", default="not queried")
    parser.add_argument("--workers", type=int, nargs="+", default=[1, 2, 4, 8])
    args = parser.parse_args()
    assert args.rounds >= 3
    assert all(1 <= n <= 64 for n in args.workers)
    builds = build()
    print("Builds completed", flush=True)
    roots = {name: fixture(name, shape) for name, shape in SHAPES.items()}
    expected = {name: reference(root) for name, root in roots.items()}
    assert expected["small"]["files"] == 520
    assert expected["small"]["links"] == 24
    print("Fixtures:", json.dumps(expected), flush=True)
    engines = ["rust-std", "swift-posix", "swift-foundation", "swift-rust"]
    jobs = [(name, engine, workers) for name in roots for engine in engines for workers in args.workers]
    # Warm every implementation/configuration; fixture creation/reference already touched metadata.
    for name, engine, workers in jobs:
        result = measured(command(engine, roots[name], workers))
        assert {k: result[k] for k in FIELDS} == expected[name], (name, engine, result, expected[name])
    print(f"All {len(jobs)} correctness/warmup checks passed", flush=True)
    rows = []
    rng = random.Random(20261015)
    for iteration in range(args.rounds):
        rng.shuffle(jobs)
        for name, engine, workers in jobs:
            result = measured(command(engine, roots[name], workers))
            assert {k: result[k] for k in FIELDS} == expected[name], (name, engine, result)
            rows.append(result | {"dataset": name, "engine": engine, "workers": workers, "round": iteration + 1})
        print(f"Round {iteration + 1}/{args.rounds} completed", flush=True)
        (BASE / "generated/partial-runs.json").write_text(json.dumps(rows))
    summary = []
    for name, engine, workers in sorted(jobs):
        group = [r for r in rows if (r["dataset"], r["engine"], r["workers"]) == (name, engine, workers)]
        stats = {"dataset": name, "engine": engine, "workers": workers}
        for metric in ("wall_seconds", "scan_seconds", "cpu_seconds", "peak_rss_bytes"):
            values = [r[metric] for r in group]
            stats[metric] = {"median": statistics.median(values), "min": min(values), "max": max(values)}
        summary.append(stats)
    metadata = {"platform": platform.platform(), "cpu": args.cpu,
                "swift": subprocess.check_output(["xcrun", "swift", "--version"], text=True).strip(),
                "rust": subprocess.check_output(["rustc", "--version"], text=True).strip(),
                "rounds": args.rounds, "cache": "warm/mixed; no purge or cold-cache claim", "builds": builds}
    (BASE / "results.json").write_text(json.dumps({"metadata": metadata, "expected": expected, "summary": summary, "runs": rows}, indent=2) + "\n")
    print("dataset engine workers | wall ms | scan ms | CPU ms | peak RSS MiB")
    for s in summary:
        print(f'{s["dataset"]:7} {s["engine"]:16} {s["workers"]} | {s["wall_seconds"]["median"]*1000:8.2f} | {s["scan_seconds"]["median"]*1000:8.2f} | {s["cpu_seconds"]["median"]*1000:8.2f} | {s["peak_rss_bytes"]["median"]/1048576:6.2f}')


if __name__ == "__main__":
    main()

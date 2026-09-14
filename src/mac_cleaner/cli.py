from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import __version__
from .config import Config
from .executor import execute_items, list_history
from .models import Classification
from .reporting import print_dry_run, print_json, print_summary
from .scanners import scan_all, scan_duplicates


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mac-cleaner",
        description="Conservative, transparent macOS storage analysis and confirmed cleanup.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = parser.add_subparsers(dest="command")

    scan = sub.add_parser("scan", help="analyze storage without changing anything")
    scan.add_argument("--developer", action="store_true", help="scan bounded project roots for generated storage")
    scan.add_argument("--large", action="store_true", help="include bounded large-file scanning")
    scan.add_argument("--details", action="store_true", help="show every exact candidate path")
    scan.add_argument("--json", action="store_true", help="emit the complete machine-readable report")

    large = sub.add_parser("large", help="scan bounded locations for large/old files")
    large.add_argument("--details", action="store_true", default=True, help=argparse.SUPPRESS)
    large.add_argument("--json", action="store_true")

    duplicates = sub.add_parser("duplicates", help="cryptographically verify duplicates (defaults to Downloads)")
    duplicates.add_argument("paths", nargs="*", type=Path)
    duplicates.add_argument("--json", action="store_true")

    clean = sub.add_parser("clean", help="preview or interactively clean SAFE candidates")
    clean.add_argument("--dry-run", action="store_true", help="print the exact plan without changing anything")
    clean.add_argument("--developer", action="store_true")

    sub.add_parser("history", help="show cleanup audit history")
    ignore = sub.add_parser("ignore", help="persistently exclude a path before future consideration")
    ignore_group = ignore.add_mutually_exclusive_group(required=True)
    ignore_group.add_argument("path", nargs="?")
    ignore_group.add_argument("--pattern")
    ignore_group.add_argument("--category")

    internal = sub.add_parser("_apply-manifest", help=argparse.SUPPRESS)
    internal.add_argument("--mode", choices=("trash", "delete"), required=True)
    internal.add_argument("--classification", choices=("SAFE", "REVIEW"), required=True)
    internal.add_argument("--yes", action="store_true", required=True)
    return parser


def _apply_manifest(args: argparse.Namespace) -> int:
    raw = sys.stdin.buffer.read(256 * 1024 * 1024 + 1)
    if len(raw) > 256 * 1024 * 1024:
        print("Manifest exceeds the 256 MiB safety limit", file=sys.stderr)
        return 2
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        print(f"Invalid cleanup manifest: {exc}", file=sys.stderr)
        return 2
    items = payload.get("items") if isinstance(payload, dict) else None
    if not isinstance(items, list) or len(items) > 200_000 or not all(isinstance(item, dict) for item in items):
        print("Cleanup manifest must contain at most 200,000 item objects", file=sys.stderr)
        return 2
    record = execute_items(items, mode=args.mode, classification=args.classification)
    print(json.dumps(record, ensure_ascii=False))
    return 0


def _load_config() -> Config:
    try:
        return Config.load()
    except ValueError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    command = args.command or "scan"
    if command == "_apply-manifest":
        return _apply_manifest(args)
    config = _load_config()

    if command == "ignore":
        if args.pattern:
            ignored, kind = config.add_pattern(args.pattern), "pattern"
        elif args.category:
            ignored, kind = config.add_category(args.category), "category"
        else:
            ignored, kind = config.add_ignore(args.path), "path"
        print(f"Ignored {kind} saved: {ignored}\nConfiguration: {config.path}")
        return 0
    if command == "history":
        records = list_history()
        if not records:
            print("No cleanup history exists yet.")
            return 0
        for record in records:
            successes = sum(bool(item.get("success")) for item in record.get("results", []))
            failures = len(record.get("results", [])) - successes
            print(f"{record.get('timestamp', 'unknown')}  {record.get('classification', '?'):9} "
                  f"{record.get('mode', '?'):7}  success={successes} failed={failures} "
                  f"measured_reclaimed={record.get('reclaimed', 0)} bytes")
        return 0
    if command == "duplicates":
        report = scan_duplicates(config, args.paths or None)
        if args.json:
            print_json(report)
        else:
            print_summary(report, details=True, protected=False)
        return 0
    if command == "clean":
        report = scan_all(config, developer=args.developer, large=False)
        print_dry_run(report)
        if args.dry_run:
            return 0
        actionable = [item.as_dict() for item in report.items
                      if item.classification == Classification.SAFE and item.metadata.get("actionable", True)]
        if not actionable:
            print("No actionable SAFE candidates were found.")
            return 0
        if not sys.stdin.isatty():
            print("Refused: interactive confirmation requires a terminal. Use the desktop app or --dry-run.", file=sys.stderr)
            return 2
        confirmation = input("\nType LIMPIAR SEGURO to execute exactly this SAFE plan: ")
        if confirmation != "LIMPIAR SEGURO":
            print("Cancelled. Nothing was changed.")
            return 1
        record = execute_items(actionable, mode="delete", classification="SAFE")
        successes = sum(result["success"] for result in record["results"])
        failures = len(record["results"]) - successes
        print(f"Completed: {successes} succeeded, {failures} refused/failed. "
              f"Measured reclaimed: {record['reclaimed']} bytes\nAudit: {record['audit_path']}")
        return 0 if failures == 0 else 1

    is_large = command == "large"
    report = scan_all(config, developer=getattr(args, "developer", False),
                      large=is_large or getattr(args, "large", False))
    if getattr(args, "json", False):
        print_json(report)
    else:
        print_summary(report, details=is_large or getattr(args, "details", False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

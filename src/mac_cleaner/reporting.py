from __future__ import annotations

import json
import os
import sys
from collections import defaultdict
from pathlib import Path

from .models import Classification, ScanItem, ScanReport
from .safety import validate_cleanup_candidate


def human_size(value: int | None) -> str:
    if value is None:
        return "unavailable"
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    number = float(value)
    for unit in units:
        if abs(number) < 1024 or unit == units[-1]:
            return f"{number:.0f} {unit}" if unit in ("B", "KiB") else f"{number:.1f} {unit}"
        number /= 1024
    return f"{value} B"


def _rule(title: str) -> None:
    print(f"\n{title}\n" + "─" * max(32, len(title)))


def _display_path(path: str, home: Path) -> str:
    prefix = str(home) + os.sep
    return "~/" + path[len(prefix):] if path.startswith(prefix) else path


def print_summary(report: ScanReport, *, details: bool = False, protected: bool = True) -> None:
    home = Path.home()
    storage = report.storage
    _rule("Storage")
    print(f"{'Capacity':<24}{human_size(storage['capacity']):>12}")
    print(f"{'Used':<24}{human_size(storage['used']):>12}")
    print(f"{'Available':<24}{human_size(storage['available']):>12}")
    percent = storage["used"] / storage["capacity"] * 100 if storage["capacity"] else 0
    print(f"{'Used percentage':<24}{percent:>11.1f}%")
    print(f"{'Home (measured)':<24}{human_size(report.home_size):>12}")

    _rule("Largest home locations (statistics only)")
    if not report.home_breakdown:
        print("No home-directory breakdown available.")
    for row in report.home_breakdown[:15]:
        print(f"{human_size(int(row['size'])):>12}  {_display_path(str(row['path']), home)}  [{row['policy']}]")

    for classification, title in ((Classification.SAFE, "SAFE TO CLEAN (after explicit confirmation)"),
                                  (Classification.REVIEW, "REVIEW (never automatic)")):
        _rule(title)
        totals = report.category_totals(classification)
        if not totals:
            print("None found.")
        for category, size in totals.items():
            count = sum(1 for item in report.items if item.classification == classification and item.category == category)
            print(f"{category:<42}{human_size(size):>12}  {count:>6} item(s)")
        print(f"{'Total ' + classification.value.lower():<42}{human_size(report.totals()[classification.value]):>12}")

    if protected:
        _rule("PROTECTED / REFUSED")
        protected_items = [item for item in report.items if item.classification == Classification.PROTECTED]
        if not protected_items:
            print("No protected locations were measured.")
        for item in sorted(protected_items, key=lambda value: value.size, reverse=True):
            print(f"{human_size(item.size):>12}  {_display_path(item.path, home)}")
            print(f"              {item.reason}; {item.proposed_action}")
        print("\nAlways refused by policy: /, the home directory itself, /System, /bin, /sbin, /usr,")
        print("/private, /var, /Library, /Applications, app/media bundles, credentials, .env files,")
        print("Git source, Mail, Messages, Safari, cloud-sync roots, and app/group containers.")

    if details:
        _rule("Exact candidate paths")
        actionable = [item for item in report.items if item.classification != Classification.PROTECTED]
        if not actionable:
            print("No candidates found.")
        for item in actionable:
            print_item(item, home)

    if report.notices:
        _rule("Notices")
        for notice in report.notices:
            print("- " + notice.replace("\n", "\n  "))
    if report.errors:
        _rule("Scan limitations")
        for error in report.errors:
            print("- " + error)


def print_item(item: ScanItem, home: Path | None = None) -> None:
    home = home or Path.home()
    print(f"[{item.classification.value}] {human_size(item.size):>10}  {_display_path(item.path, home)}")
    print(f"  Category: {item.category}")
    print(f"  Reason:   {item.reason}")
    if item.mtime:
        print(f"  Modified: {item.mtime}")
    print(f"  Action:   {item.proposed_action}")


def print_json(report: ScanReport) -> None:
    json.dump(report.as_dict(), sys.stdout, indent=2, ensure_ascii=False)
    print()


def print_dry_run(report: ScanReport) -> None:
    safe = [item for item in report.items if item.classification == Classification.SAFE]
    validated: list[ScanItem] = []
    managed: list[ScanItem] = []
    refused: list[tuple[ScanItem, str]] = []
    for item in safe:
        if item.metadata.get("actionable") is False:
            refused.append((item, "scanner marked this package-manager result as advisory-only"))
            continue
        if item.metadata.get("execution_kind") == "supported-manager":
            managed.append(item)
            continue
        cleanup_root = item.metadata.get("cleanup_root")
        if not cleanup_root:
            refused.append((item, "scanner did not declare a narrow cleanup root"))
            continue
        result = validate_cleanup_candidate(
            item.path, allowed_roots=[Path(str(cleanup_root))], expected=item.identity, home=Path.home()
        )
        if result.allowed:
            validated.append(item)
        else:
            refused.append((item, result.reason))
    _rule("DRY RUN — no files will be deleted")
    estimate = sum(i.size for i in validated + managed)
    print(f"Direct candidates passing the safety gate: {len(validated)}")
    print(f"Candidates delegated to supported managers: {len(managed)}")
    print(f"Refused after revalidation: {len(refused)}")
    print(f"Estimated SAFE bytes after revalidation: {human_size(estimate)}")
    print("No action occurs in dry-run. A real SAFE cleanup requires a separate explicit confirmation.")
    for item in validated + managed:
        print_item(item)
    if refused:
        _rule("REFUSED DURING DRY-RUN REVALIDATION")
        for item, reason in refused:
            print(f"{_display_path(item.path, Path.home())}: {reason}")

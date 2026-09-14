from __future__ import annotations

import fnmatch
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


def default_config_path() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "mac-cleaner" / "config.json"


@dataclass
class Config:
    path: Path
    ignored_paths: list[str] = field(default_factory=list)
    ignored_patterns: list[str] = field(default_factory=list)
    ignored_categories: list[str] = field(default_factory=list)
    cache_age_days: int = 30
    log_age_days: int = 30
    crash_age_days: int = 14
    temp_age_days: int = 7
    old_file_days: int = 365
    download_age_days: int = 90
    large_file_bytes: int = 50 * 1024 * 1024
    very_large_file_bytes: int = 1024 * 1024 * 1024
    max_safe_candidates_per_root: int = 100_000

    @classmethod
    def load(cls, path: Path | None = None) -> "Config":
        config_path = path or default_config_path()
        if not config_path.exists():
            return cls(path=config_path)
        try:
            data: dict[str, Any] = json.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"Cannot read configuration {config_path}: {exc}") from exc
        allowed = {name for name in cls.__dataclass_fields__ if name != "path"}
        return cls(path=config_path, **{k: v for k, v in data.items() if k in allowed})

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        data = {k: getattr(self, k) for k in self.__dataclass_fields__ if k != "path"}
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        temporary.replace(self.path)

    def is_ignored(self, path: Path, category: str) -> bool:
        if category in self.ignored_categories:
            return True
        absolute = Path(os.path.abspath(os.path.expanduser(str(path))))
        for ignored in self.ignored_paths:
            ignored_path = Path(os.path.abspath(os.path.expanduser(ignored)))
            if absolute == ignored_path or ignored_path in absolute.parents:
                return True
        text = str(absolute)
        return any(fnmatch.fnmatch(text, pattern) or fnmatch.fnmatch(absolute.name, pattern)
                   for pattern in self.ignored_patterns)

    def add_ignore(self, raw_path: str) -> str:
        absolute = str(Path(os.path.abspath(os.path.expanduser(raw_path))))
        if absolute not in self.ignored_paths:
            self.ignored_paths.append(absolute)
            self.save()
        return absolute

    def add_pattern(self, pattern: str) -> str:
        if pattern not in self.ignored_patterns:
            self.ignored_patterns.append(pattern)
            self.save()
        return pattern

    def add_category(self, category: str) -> str:
        if category not in self.ignored_categories:
            self.ignored_categories.append(category)
            self.save()
        return category

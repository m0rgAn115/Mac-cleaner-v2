from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
import stat
from typing import Any


class Classification(str, Enum):
    SAFE = "SAFE"
    REVIEW = "REVIEW"
    PROTECTED = "PROTECTED"


@dataclass(frozen=True)
class FileIdentity:
    device: int
    inode: int
    size: int
    mtime_ns: int


@dataclass
class ScanItem:
    path: str
    category: str
    classification: Classification
    size: int
    reason: str
    proposed_action: str
    mtime: str | None = None
    identity: FileIdentity | None = None
    owner: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_path(
        cls,
        path: Path,
        *,
        category: str,
        classification: Classification,
        size: int,
        reason: str,
        proposed_action: str,
        owner: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> "ScanItem":
        identity = None
        mtime = None
        try:
            st = path.lstat()
            identity = FileIdentity(st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
            mtime = datetime.fromtimestamp(st.st_mtime).astimezone().isoformat(timespec="seconds")
        except OSError:
            pass
        item_metadata = dict(metadata or {})
        if identity is not None:
            item_metadata.setdefault(
                "object_type",
                "directory" if stat.S_ISDIR(st.st_mode) else "file" if stat.S_ISREG(st.st_mode) else "other",
            )
        return cls(
            path=str(path), category=category, classification=classification,
            size=max(0, int(size)), reason=reason,
            proposed_action=proposed_action, mtime=mtime, identity=identity,
            owner=owner, metadata=item_metadata,
        )

    def as_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result["classification"] = self.classification.value
        return result


@dataclass
class ScanReport:
    generated_at: str
    platform: dict[str, Any]
    storage: dict[str, int]
    home_size: int | None
    items: list[ScanItem] = field(default_factory=list)
    home_breakdown: list[dict[str, Any]] = field(default_factory=list)
    notices: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def totals(self) -> dict[str, int]:
        return {
            kind.value: sum(i.size for i in self.items if i.classification == kind)
            for kind in Classification
        }

    def category_totals(self, classification: Classification) -> dict[str, int]:
        totals: dict[str, int] = {}
        for item in self.items:
            if item.classification == classification:
                totals[item.category] = totals.get(item.category, 0) + item.size
        return dict(sorted(totals.items(), key=lambda pair: pair[1], reverse=True))

    def as_dict(self) -> dict[str, Any]:
        return {
            "generated_at": self.generated_at,
            "platform": self.platform,
            "storage": self.storage,
            "home_size": self.home_size,
            "totals": self.totals(),
            "home_breakdown": self.home_breakdown,
            "items": [item.as_dict() for item in self.items],
            "notices": self.notices,
            "errors": self.errors,
        }

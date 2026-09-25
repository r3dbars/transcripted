"""Deterministic dev / holdout splits for eval suites.

A suite item's split depends only on (suite salt, item id), so adding items
never reshuffles the ones already there, and nobody can "re-roll" the split
to get a friendlier holdout without changing the salt, which changes the
suite fingerprint every ledger row records.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

DEV = "dev"
HOLDOUT = "holdout"
SPLITS = (DEV, HOLDOUT)


def unit_hash(salt: str, item_id: str) -> float:
    digest = hashlib.sha256(f"{salt}\x00{item_id}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") / float(1 << 64)


def split_of(item: Mapping[str, Any], salt: str, holdout_fraction: float) -> str:
    pinned = item.get("split")
    if pinned is not None:
        if pinned not in SPLITS:
            raise ValueError(f"item {item.get('id')!r} pins unknown split {pinned!r}")
        return pinned
    # Items that share a cluster (same people, same meeting) land on the same
    # side, so correlated copies never straddle the holdout line.
    key = str(item.get("cluster", item["id"]))
    return HOLDOUT if unit_hash(salt, key) < holdout_fraction else DEV


def cluster_of(item: Mapping[str, Any]) -> str:
    return str(item.get("cluster", item["id"]))


@dataclass(frozen=True)
class Suite:
    id: str
    title: str
    salt: str
    holdout_fraction: float
    items: tuple[Mapping[str, Any], ...]
    notes: str = ""

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "Suite":
        for key in ("id", "salt", "holdout_fraction", "items"):
            if key not in raw:
                raise ValueError(f"suite missing {key!r}")
        fraction = float(raw["holdout_fraction"])
        if not 0.0 < fraction < 1.0:
            raise ValueError(f"suite {raw['id']}: holdout_fraction must be in (0, 1)")
        ids = [str(item.get("id", "")) for item in raw["items"]]
        if any(not item_id for item_id in ids):
            raise ValueError(f"suite {raw['id']}: every item needs an id")
        if len(set(ids)) != len(ids):
            raise ValueError(f"suite {raw['id']}: duplicate item ids")
        return cls(
            id=str(raw["id"]),
            title=str(raw.get("title", raw["id"])),
            salt=str(raw["salt"]),
            holdout_fraction=fraction,
            items=tuple(dict(item) for item in raw["items"]),
            notes=str(raw.get("notes", "")),
        )

    def items_in(self, split: str) -> list[Mapping[str, Any]]:
        if split not in SPLITS:
            raise ValueError(f"unknown split {split!r}")
        return [item for item in self.items if split_of(item, self.salt, self.holdout_fraction) == split]

    def fingerprint(self) -> str:
        """Changes whenever items, salt, or the split rule change."""
        payload = {
            "salt": self.salt,
            "holdout_fraction": self.holdout_fraction,
            "items": sorted(
                (json.dumps(item, sort_keys=True) for item in self.items)
            ),
        }
        blob = json.dumps(payload, sort_keys=True).encode("utf-8")
        return hashlib.sha256(blob).hexdigest()[:16]

    def counts(self) -> dict[str, int]:
        return {split: len(self.items_in(split)) for split in SPLITS}

    def clusters(self) -> dict[str, str]:
        """item id -> the independent unit it belongs to (itself by default)."""
        return {str(item["id"]): cluster_of(item) for item in self.items}

    def units(self) -> dict[str, int]:
        """Independent units per split: what the statistics actually count."""
        return {split: len({cluster_of(i) for i in self.items_in(split)}) for split in SPLITS}


def check_split_health(
    suite: Suite,
    *,
    minimum_per_split: int = 1,
    minimum_units: Mapping[str, int] | None = None,
) -> list[str]:
    """Problems that make a suite unusable for honest tuning."""
    problems = []
    counts = suite.counts()
    for split in SPLITS:
        if counts[split] < minimum_per_split:
            problems.append(
                f"suite {suite.id}: {split} split has {counts[split]} items, needs >= {minimum_per_split}"
            )
    sides: dict[str, set[str]] = {}
    for item in suite.items:
        sides.setdefault(cluster_of(item), set()).add(split_of(item, suite.salt, suite.holdout_fraction))
    straddling = sorted(c for c, s in sides.items() if len(s) > 1)
    if straddling:
        problems.append(f"suite {suite.id}: clusters on both sides of the holdout line: {straddling[:5]}")
    if minimum_units:
        units = suite.units()
        for split, needed in minimum_units.items():
            if units.get(split, 0) < needed:
                problems.append(
                    f"suite {suite.id}: {split} split has {units.get(split, 0)} independent units "
                    f"({counts.get(split, 0)} items), needs >= {needed} to tell a real win from luck"
                )
    return problems


def item_ids(items: Sequence[Mapping[str, Any]]) -> list[str]:
    return [str(item["id"]) for item in items]

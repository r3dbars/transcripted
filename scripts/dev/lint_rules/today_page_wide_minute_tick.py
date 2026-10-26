"""today-page-wide-minute-tick: Settings > Today must not rebuild the page
each minute.

A page-wide `TimelineView(.everyMinute)` around `TodaySettingsPage` (and
passing `now` into the day card) made every session row format times once a
minute. That showed up as main-thread hangs (Sentry APPLE-MACOS-5X/5Y/4Q/3K;
PR #2275). The Now label and tape marker keep their own minute timelines in
`TodayClockViews.swift`. Fast tests compile `TodayPresentation.swift` but not
the views, so a behavior suite cannot catch the wrap coming back.
"""

from __future__ import annotations

import re
from pathlib import Path

from lint_rules._base import swift_file

RULE = {
    "id": "today-page-wide-minute-tick",
    "summary": "Settings > Today must not wrap the page in TimelineView(.everyMinute) or pass now into the page, day card, or session row",
    "why": "a page-wide minute TimelineView rebuilt every session row through TodayFormatterCache "
           "and hung the main thread about once a minute (Sentry APPLE-MACOS-5X/5Y/4Q/3K; 3b788a79b, PR #2275)",
    "fix": "keep TimelineView(.everyMinute) only on TodayNowLabel / TodayNowMarker in "
           "Sources/UI/Settings/TodayClockViews.swift; TodaySettingsPage, TodayDayCard, and "
           "TodaySessionRow take no `now:` — the snapshot rolls over via TodayClockPolicy.needsRollover",
    "owner_doc": "Sources/UI/Settings/AGENTS.md",
    "level": "lint",
    "paths": ["Sources/UI/Settings/**/*.swift"],
    "exclude": [],
    "ratchet": False,
    "proof": [
        "3b788a79b79559bac100af0fe6cae8c44e3e3ef6:Sources/UI/Settings/TranscriptedSettingsView+Pages.swift",
        "3b788a79b79559bac100af0fe6cae8c44e3e3ef6:Sources/UI/Settings/Pages/TodaySettingsPage.swift",
    ],
}

EVERY_MINUTE = re.compile(r"TimelineView\s*\(\s*\.everyMinute\s*\)")
NOW_STORED = re.compile(r"\b(?:let|var)\s+now\s*:\s*Date\b")
NO_NOW_TYPES = frozenset({"TodaySettingsPage", "TodayDayCard", "TodaySessionRow"})
CLOCK_VIEWS = "TodayClockViews.swift"


def check(path: str, text: str):
    sf = swift_file(text)
    out = []
    if Path(path).name != CLOCK_VIEWS:
        for line, _ in sf.find(EVERY_MINUTE):
            out.append((
                line,
                "TimelineView(.everyMinute) belongs only on TodayNowLabel / TodayNowMarker "
                "in TodayClockViews.swift; wrapping TodaySettingsPage rebuilds every session row each minute",
            ))
    for line, match in sf.find(NOW_STORED):
        owner = sf.type_at(match.start())
        if owner is not None and owner.name in NO_NOW_TYPES:
            out.append((
                line,
                f"{owner.name} must not take now: the day card and session rows skip minute ticks; "
                "live clock pieces live in TodayClockViews.swift",
            ))
    return out

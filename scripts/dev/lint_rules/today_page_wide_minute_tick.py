"""today-page-wide-minute-tick: Settings > Stats (`.today`) must not rebuild on
a minute timer.

A page-wide `TimelineView(.everyMinute)` around `TodaySettingsPage` (and
passing `now` into its cards/rows) caused main-thread hangs once a minute
(Sentry APPLE-MACOS-5X/5Y/4Q/3K; PR #2275). Stats uses `TodayDayRollover`
with `TodayMidnightSchedule` in `TodayClockViews.swift` — zero per-minute
timers. Fast tests compile `TodayPresentation.swift` but not the views, so a
behavior suite cannot catch a minute-ticking wrap coming back.
"""

from __future__ import annotations

import re

from lint_rules._base import swift_file

RULE = {
    "id": "today-page-wide-minute-tick",
    "summary": "Settings > Stats (`.today`) must not use TimelineView(.everyMinute) or pass `now: Date` into the Stats page, cards, or rows",
    "why": "a page-wide minute TimelineView rebuilt rows through TodayFormatterCache "
           "and hung the main thread about once a minute (Sentry APPLE-MACOS-5X/5Y/4Q/3K; 3b788a79b, PR #2275)",
    "fix": "keep Stats free of TimelineView(.everyMinute) and roll over only at midnight via "
           "TodayDayRollover / TodayMidnightSchedule in Sources/UI/Settings/TodayClockViews.swift; "
           "TodaySettingsPage and its cards/rows take no `now: Date`",
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
NO_NOW_TYPES = frozenset({
    "TodaySettingsPage",
    "StatsSevenDayCard",
    "StatsStreakCard",
    "StatsCaptureMixCard",
    "StatsRecentMeetingRow",
    # Historical names kept so the PR #2275 regression proof continues to match.
    "TodayDayCard",
    "TodaySessionRow",
})


def check(path: str, text: str):
    sf = swift_file(text)
    out = []
    for line, _ in sf.find(EVERY_MINUTE):
        out.append((
            line,
            "Settings views must not use TimelineView(.everyMinute); "
            "Stats rolls over at midnight via TodayDayRollover / TodayMidnightSchedule in TodayClockViews.swift",
        ))
    for line, match in sf.find(NOW_STORED):
        owner = sf.type_at(match.start())
        if owner is not None and owner.name in NO_NOW_TYPES:
            out.append((
                line,
                f"{owner.name} must not take `now: Date`: Stats skips minute ticks and rolls over via "
                "TodayDayRollover / TodayClockPolicy.needsRollover in TodayClockViews.swift",
            ))
    return out

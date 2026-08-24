#!/usr/bin/env python3
"""Every analytics event a call site emits must exist in the PSV registry.

AnalyticsReporter.trackEvent returns early when AnalyticsEventPolicy.policy(forEvent:)
is nil, so an event name that never made it into Resources/analytics-events.psv is
dropped before delivery and its fleet-wide count is permanently zero — silently, and
invisibly in local logs, because the paired DiagnosticsTrail record still lands in
events.jsonl. That is exactly how meeting_capture_stopped_under_controller went
missing. The existing AnalyticsEventPolicyTests only checks the doc and the PSV agree
with each other; nothing checked either against the code that actually emits.

The reverse direction (registered but not yet emitted) is reported for information
only and never fails: the onboarding activation-funnel events are deliberately
registered ahead of the UI that will fire them, and five ops/dashboard scripts plus
four docs are built around those names.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
REGISTRY = REPO_ROOT / "Resources" / "analytics-events.psv"
SOURCE_DIRS = ("Sources", "Tools")

# AnalyticsReporter.track("name", ...) / .track(\n  "name", ...). A call whose first
# argument is an identifier rather than a literal is dispatching a name computed
# elsewhere; those are collected separately so they can be reported, not guessed at.
TRACK_LITERAL = re.compile(r'AnalyticsReporter\.track\(\s*"([a-z0-9_]+)"')
TRACK_DYNAMIC = re.compile(r'AnalyticsReporter\.track\(\s*([a-z][A-Za-z0-9_]*)\s*,')


def registry_events() -> set[str]:
    events = set()
    for line in REGISTRY.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        events.add(line.split("|", 1)[0])
    return events


def scan_sources() -> tuple[dict[str, list[str]], list[str]]:
    emitted: dict[str, list[str]] = {}
    dynamic: list[str] = []
    for source_dir in SOURCE_DIRS:
        for path in sorted((REPO_ROOT / source_dir).rglob("*.swift")):
            if ".build" in path.parts:
                continue
            text = path.read_text(encoding="utf-8")
            rel = path.relative_to(REPO_ROOT).as_posix()
            for name in TRACK_LITERAL.findall(text):
                emitted.setdefault(name, []).append(rel)
            for symbol in TRACK_DYNAMIC.findall(text):
                dynamic.append(f"{rel}: track({symbol}, ...)")
    return emitted, dynamic


def main() -> int:
    registered = registry_events()
    emitted, dynamic = scan_sources()

    unregistered = sorted(name for name in emitted if name not in registered)
    if unregistered:
        print("Analytics emitter check FAILED: event(s) tracked but absent from the registry.")
        print(f"AnalyticsReporter drops these before delivery. Add them to {REGISTRY.relative_to(REPO_ROOT)}")
        print("and to docs/privacy-first-observability.md, which AnalyticsEventPolicyTests keeps in parity.")
        for name in unregistered:
            for site in emitted[name]:
                print(f"  {name}  <-  {site}")
        return 1

    unemitted = sorted(registered - set(emitted))
    print(f"Analytics emitter check passed: {len(emitted)} emitted event(s), all registered.")
    if unemitted:
        print(f"Registered but not emitted from Swift ({len(unemitted)}) - informational, not a failure:")
        for name in unemitted:
            print(f"  {name}")
    if dynamic:
        print(f"Call sites dispatching a computed name ({len(dynamic)}) - not checkable here:")
        for site in dynamic:
            print(f"  {site}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

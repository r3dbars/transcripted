"""blocking-system-api-outside-owner: slow system APIs only in their owner file.

Three Apple APIs make synchronous LaunchServices / XPC / preference calls and
have each frozen the app when called on main. Each one now has a single owner
that runs it on a background queue and hands out async entry points. Because
they're global Apple symbols, nothing stops another file from naming them
directly, so this rule does: the raw call may appear only in its owner.

The check is token-based on comment- and string-blanked code. Out of scope:
`EKEventStore.authorizationStatus(for:)` (cheap), and two reads that can block
but have no owner yet, so they're known misses rather than allowed:
`NSRunningApplication.runningApplications(withBundleIdentifier:)` and
`NSWorkspace.shared.frontmostApplication?.bundleIdentifier` (910dd046f moved
one off main; Sources/Writing/WritingFrontWindowObserver.swift still reads it).
Calls through a local alias (`let ws = NSWorkspace.shared`) are also missed.
"""

from __future__ import annotations

import re

from lint_rules._base import swift_file

RULE = {
    "id": "blocking-system-api-outside-owner",
    "summary": "NSWorkspace.shared.runningApplications, SMAppService and EKEventStore() are called only from their owner file",
    "why": "direct calls on main froze launch and Settings (cb900ba2a, fabac326f, 582529a45, 6baa7aa7b, d1a94c0e8, 5d26d63bb, 910dd046f)",
    "fix": "use RunningApplicationsReader.applications()/bundleIdentifiers(), LaunchAtLoginController.readState()/its async register paths, or MeetingPromptCalendarReader / MeetingInviteeCalendarReader",
    "owner_doc": "Sources/Support/AGENTS.md",
    "level": "lint",
    "paths": ["Sources/**/*.swift"],
    "exclude": [],
    "ratchet": True,
    # Parents of the fixes: cb900ba2a, fabac326f, e761d0142 (launch-time register on main).
    "proof": [
        "b0d463aa38:Sources/Meeting/MeetingPromptDetector.swift",
        "b0d463aa38:Sources/Meeting/BrowserWindowTitleReader.swift",
        "b0d463aa38:Sources/Support/CallAppMicrophoneSharingMonitor.swift",
        "6baa7aa7bd:Sources/Support/CallAppMicrophoneSharingMonitor.swift",
        "22832d88d2:Sources/TranscriptedAppState.swift",
    ],
}

# (pattern, owner files, message)
_APIS = (
    (
        re.compile(r"\bNSWorkspace\s*\.\s*shared\s*\.\s*runningApplications\b"),
        frozenset({"Sources/Support/RunningApplicationsReader.swift"}),
        "NSWorkspace.shared.runningApplications read outside RunningApplicationsReader; "
        "an app's first bundleIdentifier read blocks on LaunchServices. "
        "Use `await RunningApplicationsReader.applications()` or `.bundleIdentifiers()`",
    ),
    (
        # A bare type reference (`var status: SMAppService.Status`) doesn't call anything.
        re.compile(r"\bSMAppService\b(?!\s*\.\s*Status\b)"),
        frozenset({
            "Sources/Support/LaunchAtLoginController.swift",
            "Sources/Support/LaunchAtLoginPreferences.swift",
        }),
        "SMAppService used outside LaunchAtLoginController; status/register/unregister are "
        "blocking XPC calls. Use `await LaunchAtLoginController.readState()` or its async "
        "register/unregister paths, which run on its statusQueue",
    ),
    (
        re.compile(r"\bEKEventStore\s*(?:\.\s*init\s*)?\("),
        frozenset({
            "Sources/Meeting/MeetingPromptCalendarReader.swift",
            "Sources/Meeting/MeetingInviteeCalendarReader.swift",
            "Sources/Support/TranscriptedPermissionAccess.swift",
        }),
        "EKEventStore() built outside the calendar readers; construction makes synchronous "
        "preference/XPC calls. Go through MeetingPromptCalendarReader or "
        "MeetingInviteeCalendarReader (TranscriptedPermissionAccess for the access request)",
    ),
)


def check(path: str, text: str) -> list:
    if "runningApplications" not in text and "SMAppService" not in text and "EKEventStore" not in text:
        return []
    hits = []
    sf = None
    for rx, owners, message in _APIS:
        if path in owners:
            continue
        if sf is None:
            sf = swift_file(text)
        for line, _ in sf.find(rx):
            hits.append((line, message))
    hits.sort()
    return hits

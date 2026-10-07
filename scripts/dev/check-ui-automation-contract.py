#!/usr/bin/env python3
"""Keep the accessibility identifiers that outside tools press declared in the app.

The QA CLI smokes (Tools/TranscriptedQA UISmoke and ImportedAudioNativeSmoke) and
build.sh's launch smoke press controls by `transcripted.<area>.<name>`
identifier. If the app stops declaring one, the smoke fails on a machine with
the app running, long after the change that broke it. This used to be Swift
tests that read Sources/ as text (Tests/UIAutomationSurfaceContractTests.swift).
It only checks that files agree with each other and runs no app code, so it
lives here.

Stdlib only, offline, writes nothing.

    python3 scripts/dev/check-ui-automation-contract.py
    python3 scripts/dev/check-ui-automation-contract.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

IDENTIFIER = re.compile(r'"(transcripted\.[a-z0-9-]+(?:\.[a-z0-9-]+)+)"')
PRESSERS = [
    "Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/UISmoke.swift",
    "Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/ImportedAudioNativeSmoke.swift",
    "scripts/entrypoints/build.sh",
]
# The sidebar row ids are built from TranscriptedSettingsPage's cases
# ("transcripted.settings.sidebar.<case>"), so most have no literal.
PAGE_ENUM = "Sources/UI/Settings/TranscriptedSettingsPage.swift"
PAGE_ID_PREFIX = "transcripted.settings.sidebar."
PAGE_CASE = re.compile(r"^\s*case (\w+)\s*$", re.MULTILINE)
MIN_PRESSED = 20

SETTINGS_DIR = "Sources/UI/Settings"
# Controls the click-flow smokes drive on the Settings pages.
SETTINGS_CLICK_FLOW_IDS = [
    "transcripted.settings.footer.check-updates",
    "transcripted.settings.general.launch-at-login",
    "transcripted.settings.general.show-in-dock",
    "transcripted.settings.general.dictation-sounds",
    "transcripted.settings.general.cleanup-pasted-text",
    "transcripted.settings.section.dictation",
    "transcripted.settings.section.bluetooth-microphone",
    "transcripted.settings.section.send-after-dictation",
    "transcripted.settings.section.meetings",
    "transcripted.settings.section.speakers",
    "transcripted.settings.section.transcription",
    "transcripted.settings.section.app",
    "transcripted.settings.section.permissions",
    "transcripted.settings.section.privacy",
    "transcripted.settings.general.keyboard-shortcuts",
    "transcripted.settings.general.bluetooth-dictation",
    "transcripted.settings.general.microphone",
    "transcripted.settings.general.auto-send",
    "transcripted.settings.general.model",
    "transcripted.settings.general.corrections",
    "transcripted.settings.general.people-in-room",
    "transcripted.settings.general.crash-reports",
    "transcripted.settings.general.usage-stats",
    "transcripted.settings.storage.capture-library",
    "transcripted.settings.storage.delete-audio",
    "transcripted.settings.storage.free-up-space",
    "transcripted.settings.storage.support-files",
    "transcripted.settings.about.automatic-updates",
    "transcripted.settings.about.support",
    "transcripted.settings.general.corrections.clear-all",
]
# Icon-only Speakers controls stay scriptable without using speaker names.
SPEAKERS_IDS = [
    "transcripted.speakers.voice-to-name.play",
    "transcripted.speakers.voice-to-name.menu",
    "transcripted.speakers.search.field",
    "transcripted.speakers.person.play",
    "transcripted.speakers.person.menu",
]
# The Speakers surface must not regrow a manual refresh button; navigation and
# mutations refresh its model.
SPEAKERS_FORBIDDEN_IDS = ["transcripted.speakers.refresh"]


def identifiers(text: str) -> set[str]:
    return set(IDENTIFIER.findall(text))


def page_identifiers(sources: dict[str, str]) -> set[str]:
    """Sidebar ids the page enum builds from its case names."""
    text = sources.get(PAGE_ENUM, "")
    head = text.split("var id:", 1)[0]
    return {PAGE_ID_PREFIX + name for name in PAGE_CASE.findall(head)}


def check(sources: dict[str, str], pressers: dict[str, str]) -> list[str]:
    """`sources`: app Swift files by path. `pressers`: the tools that press ids."""
    problems: list[str] = []
    declared: set[str] = set()
    for text in sources.values():
        declared |= identifiers(text)
    declared |= page_identifiers(sources)

    pressed: set[str] = set()
    for text in pressers.values():
        pressed |= identifiers(text)
    if len(pressed) < MIN_PRESSED:
        problems.append(
            f"the QA smokes should still drive the menu bar, sidebar, onboarding and import controls "
            f"(found {len(pressed)} identifiers, expected at least {MIN_PRESSED})"
        )
    for ident in sorted(pressed):
        if ident not in declared:
            problems.append(f"{ident} is pressed by the QA smokes but the app never declares it")

    settings = {path: text for path, text in sources.items() if path.startswith(SETTINGS_DIR + "/")}
    settings_declared: set[str] = set()
    for text in settings.values():
        settings_declared |= identifiers(text)
    for ident in SETTINGS_CLICK_FLOW_IDS:
        if ident not in settings_declared:
            problems.append(f"{ident} should stay attached to a Settings click-flow control")

    speakers_declared: set[str] = set()
    for path, text in settings.items():
        if Path(path).name.startswith("SpeakerPeople"):
            speakers_declared |= identifiers(text)
    for ident in SPEAKERS_IDS:
        if ident not in speakers_declared:
            problems.append(f"{ident} should keep the Speakers icon-only controls scriptable")
    for ident in SPEAKERS_FORBIDDEN_IDS:
        if ident in speakers_declared:
            problems.append(f"{ident} must not come back: navigation and mutations refresh the Speakers model")
    return problems


def read_tree(root: Path, base: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for path in sorted(root.rglob("*.swift")):
        out[path.relative_to(base).as_posix()] = path.read_text(encoding="utf-8", errors="replace")
    return out


def load() -> tuple[dict[str, str], dict[str, str]]:
    sources = read_tree(REPO_ROOT / "Sources", REPO_ROOT)
    pressers = {}
    for rel in PRESSERS:
        path = REPO_ROOT / rel
        pressers[rel] = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    return sources, pressers


def self_test() -> int:
    quote = lambda ids: "\n".join(f'let a = "{i}"' for i in ids)
    settings_src = quote(SETTINGS_CLICK_FLOW_IDS)
    speakers_src = quote(SPEAKERS_IDS)
    pressed_ids = [f"transcripted.menubar.item-{n}" for n in range(MIN_PRESSED)]
    sources = {
        f"{SETTINGS_DIR}/TranscriptedSettingsView.swift": settings_src,
        f"{SETTINGS_DIR}/SpeakerPeopleSettingsSection.swift": speakers_src,
        "Sources/UI/MenuBar/Menu.swift": quote(pressed_ids),
    }
    sources[PAGE_ENUM] = "enum P {\n    case today\n    case home\n\n    var id: String { rawValue }\n    case later\n}"
    pressers = {"smoke": quote(pressed_ids + [PAGE_ID_PREFIX + "home"])}
    assert check(sources, pressers) == [], check(sources, pressers)

    missing = dict(sources)
    missing["Sources/UI/MenuBar/Menu.swift"] = quote(pressed_ids[1:])
    assert any(pressed_ids[0] in p for p in check(missing, pressers))

    unknown_page = {"smoke": quote(pressed_ids + [PAGE_ID_PREFIX + "later"])}
    assert any("later" in p for p in check(sources, unknown_page)), "only cases before var id count as pages"

    few = {"smoke": quote(pressed_ids[:3])}
    assert any("at least" in p for p in check(sources, few))

    dropped = dict(sources)
    dropped[f"{SETTINGS_DIR}/TranscriptedSettingsView.swift"] = quote(SETTINGS_CLICK_FLOW_IDS[1:])
    assert any(SETTINGS_CLICK_FLOW_IDS[0] in p for p in check(dropped, pressers))

    elsewhere = dict(sources)
    elsewhere[f"{SETTINGS_DIR}/SpeakerPeopleSettingsSection.swift"] = quote(SPEAKERS_IDS[1:])
    elsewhere[f"{SETTINGS_DIR}/Other.swift"] = quote(SPEAKERS_IDS[:1])
    assert any(SPEAKERS_IDS[0] in p for p in check(elsewhere, pressers)), "a Speakers id outside SpeakerPeople* files must not count"

    regrown = dict(sources)
    regrown[f"{SETTINGS_DIR}/SpeakerPeopleSettingsSection.swift"] = speakers_src + quote(SPEAKERS_FORBIDDEN_IDS)
    assert any("must not come back" in p for p in check(regrown, pressers))
    print("ui automation contract self-test OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    problems = check(*load())
    for problem in problems:
        print(f"FAIL: {problem}")
    if problems:
        return 1
    print("ui automation contract OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

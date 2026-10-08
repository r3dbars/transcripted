#!/usr/bin/env python3
"""Keep the accessibility identifiers that outside tools press declared in the app.

The QA CLI smokes (Tools/TranscriptedQA UISmoke and ImportedAudioNativeSmoke) and
build.sh's launch smoke press controls by `transcripted.<area>.<name>`
identifier. If the app stops declaring one, the smoke fails on a machine with
the app running, long after the change that broke it. This used to be Swift
tests that read Sources/ as text (Tests/UIAutomationSurfaceContractTests.swift).
It only checks that files agree with each other and runs no app code, so it
lives here.

Stdlib only and offline. The default check writes nothing; self-tests use
an owned temporary fixture directory.

    python3 scripts/dev/check-ui-automation-contract.py
    python3 scripts/dev/check-ui-automation-contract.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

IDENTIFIER = re.compile(r'"(transcripted\.[a-z0-9-]+(?:\.[a-z0-9-]+)+)"')
PRESSERS = [
    "Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/ImportedAudioNativeSmoke.swift",
    "scripts/entrypoints/build.sh",
]
# Sidebar ids come from the actual automationIdentifier property. Fail closed
# if its mapping stops using the supported literal/rawValue switch shape.
PAGE_ENUM = "Sources/UI/Settings/TranscriptedSettingsPage.swift"
PAGE_ID_PREFIX = "transcripted.settings.sidebar."
PAGE_CASE = re.compile(r'^\s*case (\w+)(?:\s*=\s*"([^"\n]+)")?\s*$', re.MULTILINE)
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
    """Evaluate the page property's literal returns and rawValue interpolation."""
    text = sources.get(PAGE_ENUM, "")
    cases = dict((name, raw or name) for name, raw in PAGE_CASE.findall(text.split("var id:", 1)[0]))
    match = re.search(r"var automationIdentifier:\s*String\s*\{", text)
    if not cases or not match:
        raise ValueError("missing page cases or automationIdentifier mapping")
    start = match.end()
    depth = 1
    end = start
    while end < len(text) and depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    body = text[start:end - 1].strip()
    # Current property is a switch with one or more explicit case groups plus
    # a default. Only literal strings, optionally containing rawValue, count.
    arms = re.findall(r'(case\s+[^:]+|default)\s*:\s*return\s+"([^"\n]*)"', body)
    residue = re.sub(r'(case\s+[^:]+|default)\s*:\s*return\s+"([^"\n]*)"', "", body)
    if not arms or re.sub(r"\s|switch self|[{}]", "", residue):
        raise ValueError("unsupported automationIdentifier mapping; update the checker")
    mapped: dict[str, str] = {}
    default = None
    for label, value in arms:
        if label == "default":
            default = value
        else:
            names = re.findall(r"\.(\w+)", label)
            if not names or any(name not in cases for name in names):
                raise ValueError("unknown case in automationIdentifier mapping")
            for name in names:
                mapped[name] = value
    result = set()
    for name, raw in cases.items():
        value = mapped.get(name, default)
        if value is None:
            raise ValueError("incomplete automationIdentifier mapping")
        value = value.replace(r"\(rawValue)", raw)
        if "\\(" in value:
            raise ValueError("unsupported interpolation in automationIdentifier mapping")
        result.add(value)
    return result


def check(sources: dict[str, str], pressers: dict[str, str]) -> list[str]:
    """`sources`: app Swift files by path. `pressers`: the tools that press ids."""
    problems: list[str] = []
    declared: set[str] = set()
    for path, text in sources.items():
        if path != PAGE_ENUM:
            declared |= identifiers(text)
    try:
        declared |= page_identifiers(sources)
    except ValueError as error:
        problems.append(f"{PAGE_ENUM}: {error}")

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
            speakers_declared |= set(re.findall(r'"(transcripted\.speakers\.refresh[^"\n]*)"', text))
    for ident in SPEAKERS_IDS:
        if ident not in speakers_declared:
            problems.append(f"{ident} should keep the Speakers icon-only controls scriptable")
    for ident in SPEAKERS_FORBIDDEN_IDS:
        for declared_id in sorted(speakers_declared):
            if declared_id.startswith(ident):
                problems.append(f"{declared_id} must not come back: navigation and mutations refresh the Speakers model")
    return problems


def read_tree(root: Path, base: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for path in sorted(root.rglob("*.swift")):
        out[path.relative_to(base).as_posix()] = path.read_text(encoding="utf-8", errors="replace")
    return out


def presser_paths(root: Path) -> list[str]:
    """Include UISmoke extensions after its command is split into files."""
    commands = root / "Tools/TranscriptedQA/Sources/TranscriptedQA/Commands"
    return PRESSERS + [path.relative_to(root).as_posix() for path in sorted(commands.glob("UISmoke*.swift"))]


def load() -> tuple[dict[str, str], dict[str, str]]:
    sources = read_tree(REPO_ROOT / "Sources", REPO_ROOT)
    pressers = {}
    for rel in presser_paths(REPO_ROOT):
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
    sources[PAGE_ENUM] = r"""enum P {
    case today
    case home
    case connectAgent
    var id: String { rawValue }
    var automationIdentifier: String {
        switch self {
        case .connectAgent: return "transcripted.settings.sidebar.connect-agent"
        default: return "transcripted.settings.sidebar.\(rawValue)"
        }
    }
}"""
    pressers = {"smoke": quote(pressed_ids + [PAGE_ID_PREFIX + "home"])}
    assert check(sources, pressers) == [], check(sources, pressers)

    missing = dict(sources)
    missing["Sources/UI/MenuBar/Menu.swift"] = quote(pressed_ids[1:])
    assert any(pressed_ids[0] in p for p in check(missing, pressers))

    unknown_page = {"smoke": quote(pressed_ids + [PAGE_ID_PREFIX + "later"])}
    assert any("later" in p for p in check(sources, unknown_page)), "unknown pages must not count"

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
    descendant = dict(sources)
    descendant[f"{SETTINGS_DIR}/SpeakerPeopleSettingsSection.swift"] = speakers_src + quote(["transcripted.speakers.refresh.button", "transcripted.speakers.refresh.button_test", "transcripted.speakers.refresh_button", "transcripted.speakers.refresh-inbox"])
    assert any("refresh.button must not come back" in p for p in check(descendant, pressers))
    assert any("refresh.button_test must not come back" in p for p in check(descendant, pressers))
    assert any("refresh_button must not come back" in p for p in check(descendant, pressers))
    assert any("refresh-inbox must not come back" in p for p in check(descendant, pressers))

    changed_prefix = dict(sources)
    changed_prefix[PAGE_ENUM] = sources[PAGE_ENUM].replace("sidebar.", "navigation.")
    assert any("sidebar.home is pressed" in p for p in check(changed_prefix, pressers)), "actual mapping prefix must be used"

    explicit = dict(sources)
    explicit[PAGE_ENUM] = sources[PAGE_ENUM].replace("case .connectAgent:", 'case .home: return "transcripted.settings.sidebar.meetings"\n        case .connectAgent:')
    assert any("sidebar.home is pressed" in p for p in check(explicit, pressers)), "an explicit case replaces the default mapping"
    assert page_identifiers(explicit) == {PAGE_ID_PREFIX + "today", PAGE_ID_PREFIX + "meetings", PAGE_ID_PREFIX + "connect-agent"}

    raw_case = dict(sources)
    raw_case[PAGE_ENUM] = sources[PAGE_ENUM].replace("case home", 'case home = "meetings"')
    assert any("sidebar.home is pressed" in p for p in check(raw_case, pressers)), "rawValue overrides must be used"

    unsupported = dict(sources)
    unsupported[PAGE_ENUM] = sources[PAGE_ENUM].replace('return "transcripted.settings.sidebar.\\(rawValue)"', "return makeIdentifier()")
    assert any("unsupported automationIdentifier" in p for p in check(unsupported, pressers)), "unknown mapping shapes fail closed"
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        commands = root / "Tools/TranscriptedQA/Sources/TranscriptedQA/Commands"
        commands.mkdir(parents=True)
        for filename in ["UISmoke.swift", "UISmokeMenuBarAudit.swift", "UISmokeReport.swift"]:
            (commands / filename).write_text("")
        assert all(str(Path("Tools/TranscriptedQA/Sources/TranscriptedQA/Commands") / filename) in presser_paths(root)
                   for filename in ["UISmoke.swift", "UISmokeMenuBarAudit.swift", "UISmokeReport.swift"])
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

#!/usr/bin/env python3
"""Fail when an AppKit window or panel is not in the screen-capture inventory.

AppKit windows default to `NSWindow.SharingType.readOnly`, which screen sharing
and screenshot capture can read. A panel that shows live transcript text must opt
out with `sharingType = .none`. Nothing at runtime says "someone added a window",
so this check scans `Sources/` for window surfaces and compares them to
`.agents/window-inventory.json`:

* A surface is `NSWindow(` / `NSPanel(` constructed directly, or a class that
  subclasses `NSWindow` / `NSPanel`.
* Every surface found must be listed in the inventory (file + token), with a
  policy: `protected` (excluded from capture) or `capturable`, and a reason.
* The file must set `sharingType` explicitly, to the value the policy says
  (`.none` for protected, `.readOnly` for capturable). A new surface that leaves
  the default fails here even if someone adds it to the inventory.
* An inventory entry whose surface no longer exists fails, so the list stays true.

`Tests/OverlayScreenSharePrivacyTests.swift` builds the real windows and reads
`sharingType` off them; this check is what tells you a window needs a test there.

    python3 scripts/dev/check-window-inventory.py
    python3 scripts/dev/check-window-inventory.py --self-test

Offline, python3 stdlib only, writes nothing.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
INVENTORY = ".agents/window-inventory.json"
POLICIES = {"protected": ".none", "capturable": ".readOnly"}

CONSTRUCTOR = re.compile(r"\b(NSWindow|NSPanel)\(")
SUBCLASS = re.compile(r"\bclass\s+(\w+)\s*:\s*(?:NSWindow|NSPanel)\b")


def strip_comment(line: str) -> str:
    return line.split("//", 1)[0]


def scan_source(text: str) -> set[str]:
    """Surface tokens in one Swift file: `NSWindow(`, `NSPanel(`, or a class name."""
    found: set[str] = set()
    for raw in text.splitlines():
        line = strip_comment(raw)
        for match in CONSTRUCTOR.finditer(line):
            found.add(f"{match.group(1)}(")
        for match in SUBCLASS.finditer(line):
            found.add(match.group(1))
    return found


def scan_tree(root: Path) -> dict[str, set[str]]:
    surfaces: dict[str, set[str]] = {}
    sources = root / "Sources"
    for path in sorted(sources.rglob("*.swift")):
        tokens = scan_source(path.read_text(encoding="utf-8", errors="replace"))
        if tokens:
            surfaces[path.relative_to(root).as_posix()] = tokens
    return surfaces


def check(root: Path) -> list[str]:
    problems: list[str] = []
    inventory_path = root / INVENTORY
    try:
        entries = json.loads(inventory_path.read_text(encoding="utf-8"))["windows"]
    except (OSError, ValueError, KeyError) as error:
        return [f"{INVENTORY}: cannot read inventory ({error})"]

    listed: dict[tuple[str, str], dict] = {}
    for entry in entries:
        key = (entry.get("file", ""), entry.get("surface", ""))
        if key in listed:
            problems.append(f"{INVENTORY}: duplicate entry {key[0]} :: {key[1]}")
        listed[key] = entry
        if entry.get("policy") not in POLICIES:
            problems.append(f"{INVENTORY}: {key[0]} :: {key[1]} needs policy protected or capturable")
        if not str(entry.get("reason", "")).strip():
            problems.append(f"{INVENTORY}: {key[0]} :: {key[1]} needs a reason")

    surfaces = scan_tree(root)
    for file, tokens in surfaces.items():
        text = (root / file).read_text(encoding="utf-8", errors="replace")
        for token in sorted(tokens):
            entry = listed.get((file, token))
            if entry is None:
                problems.append(
                    f"{file}: window surface `{token}` is not in {INVENTORY}. Add it with policy "
                    "protected (shows live transcript text; sharingType = .none) or capturable, "
                    "and cover it in Tests/OverlayScreenSharePrivacyTests.swift."
                )
                continue
            wanted = POLICIES.get(entry.get("policy", ""))
            if wanted and not re.search(rf"sharingType\s*=\s*{re.escape(wanted)}\b", text):
                problems.append(
                    f"{file}: `{token}` is {entry['policy']} in the inventory but the file "
                    f"never sets sharingType = {wanted}"
                )
    for (file, token) in sorted(listed):
        if token not in surfaces.get(file, set()):
            problems.append(f"{INVENTORY}: {file} :: {token} no longer exists; remove the entry")
    return problems


def self_test() -> int:
    failures: list[str] = []

    def expect(name: str, cond: bool) -> None:
        if not cond:
            failures.append(name)

    expect("constructor found", scan_source("let w = NSWindow(contentRect: r)") == {"NSWindow("})
    expect("panel constructor found", scan_source("let p = NSPanel(x)") == {"NSPanel("})
    expect("subclass found", scan_source("final class Foo: NSPanel {") == {"Foo"})
    expect("comment ignored", scan_source("// NSWindow(contentRect:)") == set())
    expect("type annotation ignored", scan_source("private var p: NSPanel?") == set())
    expect("NSWindowController ignored", scan_source("final class C: NSWindowController {") == set())

    def build(entries: list[dict], files: dict[str, str]) -> Path:
        root = Path(tempfile.mkdtemp())
        (root / ".agents").mkdir()
        (root / INVENTORY).write_text(json.dumps({"windows": entries}))
        for name, body in files.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(body)
        return root

    good = {"file": "Sources/A.swift", "surface": "Foo", "policy": "protected", "reason": "live text"}
    src = "final class Foo: NSPanel {\n  init() { sharingType = .none }\n}\n"
    expect("clean tree passes", check(build([good], {"Sources/A.swift": src})) == [])
    expect("unlisted surface fails", len(check(build([], {"Sources/A.swift": src}))) == 1)
    expect(
        "default sharing type fails",
        len(check(build([good], {"Sources/A.swift": "final class Foo: NSPanel {}\n"}))) == 1,
    )
    expect(
        "wrong policy value fails",
        len(check(build([good], {"Sources/A.swift": src.replace(".none", ".readOnly")}))) == 1,
    )
    expect("stale entry fails", len(check(build([good], {"Sources/A.swift": "struct S {}\n"}))) == 1)
    expect(
        "missing reason fails",
        len(check(build([{**good, "reason": ""}], {"Sources/A.swift": src}))) == 1,
    )

    if failures:
        print("check-window-inventory self-test FAILED:")
        for name in failures:
            print(f"  - {name}")
        return 1
    print("check-window-inventory self-test passed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    problems = check(REPO_ROOT)
    if problems:
        print("check-window-inventory: FAILED")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("check-window-inventory: every window surface is in the inventory with its sharing policy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

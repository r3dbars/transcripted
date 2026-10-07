#!/usr/bin/env python3
"""Keep the menu bar glyph's numbers in step with the SVG generator.

Sources/UI/MenuBar/MenuBarGlyph.swift (MenuBarGlyphGeometry) draws the glyph
the app shows; docs/assets/menu-bar-icon/make_menu_bar_icons.py draws the
committed SVGs from the same numbers. Both files say "keep these in sync", and
this is the check that does it: it compares the plain constants and the two
quadratic curves that make the bubble's tail.

The two files agreeing is a fact about two files, not a behavior of the app, so
it lives here instead of in a Swift test that reads the generator as text.

    python3 scripts/dev/check-menu-bar-glyph-sync.py
    python3 scripts/dev/check-menu-bar-glyph-sync.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SWIFT_PATH = "Sources/UI/MenuBar/MenuBarGlyph.swift"
GENERATOR_PATH = "docs/assets/menu-bar-icon/make_menu_bar_icons.py"

# generator assignment names -> Swift constants, in the same order as the numbers.
CONSTANT_PAIRS: list[tuple[str, list[str]]] = [
    ("SW", ["strokeWidth"]),
    ("L, R, TOP, BOT, RAD", ["left", "right", "top", "bottom", "radius"]),
    ("CX, MID", ["centerX", "barMidY"]),
    ("CB", ["crossbarHalfLength"]),
    ("GAP", ["crossbarGap"]),
    ("STEM_BOT", ["stemBottom"]),
    ("SIDE_BARS", ["sideBarOffset", "sideBarHeight"]),
    ("DOT_C, DOT_R, DOT_RING", ["dotCenter.x", "dotCenter.y", "dotRadius", "dotRing"]),
    ("BOX_X, BOX_Y, BOX", ["box.x", "box.y", "box.width"]),
]

NUMBER = re.compile(r"-?\d+(?:\.\d+)?")


def python_numbers(generator: str, names: str) -> list[float]:
    prefix = f"{names} = "
    for line in generator.splitlines():
        if line.startswith(prefix):
            rhs = line[len(prefix):].split("#", 1)[0]
            return [float(n) for n in NUMBER.findall(rhs)]
    return []


def swift_constants(swift: str) -> dict[str, float]:
    start = swift.find("enum MenuBarGlyphGeometry")
    body = swift[start:] if start >= 0 else ""
    values: dict[str, float] = {}
    for m in re.finditer(r"static let (\w+): CGFloat = (-?[\d.]+)", body):
        values[m.group(1)] = float(m.group(2))
    m = re.search(r"static let dotCenter = CGPoint\(x: (-?[\d.]+), y: (-?[\d.]+)\)", body)
    if m:
        values["dotCenter.x"], values["dotCenter.y"] = float(m.group(1)), float(m.group(2))
    m = re.search(
        r"static let box = CGRect\(x: (-?[\d.]+), y: (-?[\d.]+), width: (-?[\d.]+), height: (-?[\d.]+)\)", body
    )
    if m:
        values["box.x"], values["box.y"] = float(m.group(1)), float(m.group(2))
        values["box.width"], values["box.height"] = float(m.group(3)), float(m.group(4))
    return values


def swift_tail(swift: str, bottom: float) -> list[list[float]]:
    """The tail's [start.x, start.y, control.x, control.y, end.x, end.y] curves."""
    m = re.search(r"func addTail\(.*?\n    \}", swift, re.S)
    body = m.group(0) if m else ""
    current: list[float] = []
    curves: list[list[float]] = []
    for line in body.splitlines():
        line = line.replace("y: bottom", f"y: {bottom:g}")
        if "addLine" in line:
            pt = re.search(r"x: (-?[\d.]+), y: (-?[\d.]+)", line)
            if pt:
                current = [float(pt.group(1)), float(pt.group(2))]
        elif "addQuadCurve" in line:
            to = re.search(r"to: CGPoint\(x: (-?[\d.]+), y: (-?[\d.]+)\)", line)
            ctl = re.search(r"control: CGPoint\(x: (-?[\d.]+), y: (-?[\d.]+)\)", line)
            if to and ctl and current:
                end = [float(to.group(1)), float(to.group(2))]
                curves.append(current + [float(ctl.group(1)), float(ctl.group(2))] + end)
                current = end
    return curves


def generator_tail(generator: str, bottom: float) -> list[list[float]]:
    line = next((ln for ln in generator.splitlines() if "d += f'L 404 {BOT} Q " in ln), "")
    tokens = line.replace("{BOT}", f"{bottom:g}").replace("'", " ").split()
    curves: list[list[float]] = []
    current: list[float] = []
    i = 0
    while i < len(tokens):
        try:
            if tokens[i] == "L":
                current = [float(tokens[i + 1]), float(tokens[i + 2])]
                i += 3
                continue
            if tokens[i] == "Q":
                nums = [float(t) for t in tokens[i + 1:i + 5]]
                if len(nums) == 4 and current:
                    curves.append(current + nums)
                    current = nums[2:]
                i += 5
                continue
        except (ValueError, IndexError):
            pass
        i += 1
    return curves


def problems(swift: str, generator: str) -> list[str]:
    out: list[str] = []
    constants = swift_constants(swift)
    for names, swift_names in CONSTANT_PAIRS:
        expected = python_numbers(generator, names)
        actual = [constants.get(n, float("nan")) for n in swift_names]
        if expected != actual:
            out.append(f"{names} in make_menu_bar_icons.py is {expected}; MenuBarGlyphGeometry has {actual}")
    if constants.get("box.width") != constants.get("box.height"):
        out.append("the glyph box should be square")
    bottom = constants.get("bottom", float("nan"))
    from_swift = swift_tail(swift, bottom)
    from_generator = generator_tail(generator, bottom)
    if len(from_generator) != 2:
        out.append(f"the generator should draw the tail as two Q curves, found {len(from_generator)}")
    if from_swift != from_generator:
        out.append(f"tail curves differ: Swift {from_swift}, generator {from_generator}")
    return out


def self_test() -> int:
    swift = (REPO_ROOT / SWIFT_PATH).read_text()
    generator = (REPO_ROOT / GENERATOR_PATH).read_text()
    if problems(swift, generator):
        print("self-test: the committed files should agree", file=sys.stderr)
        return 1
    if not problems(swift.replace("static let radius: CGFloat = 110", "static let radius: CGFloat = 111"), generator):
        print("self-test: a drifted constant should be caught", file=sys.stderr)
        return 1
    if not problems(swift.replace("control: CGPoint(x: 396, y: 748)", "control: CGPoint(x: 397, y: 748)"), generator):
        print("self-test: a drifted tail curve should be caught", file=sys.stderr)
        return 1
    if not problems(swift, generator.replace("DOT_C, DOT_R, DOT_RING = (744, 757), 84, 44", "DOT_C, DOT_R, DOT_RING = (744, 757), 85, 44")):
        print("self-test: a drifted generator number should be caught", file=sys.stderr)
        return 1
    print("menu bar glyph sync self-test OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    found = problems((REPO_ROOT / SWIFT_PATH).read_text(), (REPO_ROOT / GENERATOR_PATH).read_text())
    if found:
        print("menu bar glyph numbers drifted between the app and the SVG generator:", file=sys.stderr)
        for line in found:
            print(f"  - {line}", file=sys.stderr)
        return 1
    print("menu bar glyph sync OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Move mobius's converter environment from Python 3.10 to 3.11.

mobius pins Python 3.10.12 and scipy 1.15.3. scipy 1.15.x wheels ship Fortran
extensions (scipy.sparse.linalg._propack and others) whose Mach-O
__DATA/__thread_bss section is zero-fill with a non-zero offset, and macOS 27's
dyld refuses to load them:

    ImportError: dlopen: section '__DATA/__thread_bss' has a zero-fill section
    type, but offset field is not zero

NeMo imports scipy.signal through torchmetrics, so the converter can't start.
scipy 1.16 wheels load fine, but they need Python 3.11. So this bumps exactly
those two pins in the mobius checkout (our own build workspace) and, after
`uv lock`, checks that every other locked package kept mobius's version
(packages that are only needed below Python 3.11 may drop out).

    converter_env.py patch <pyproject.toml>
    converter_env.py check-lock <original uv.lock> <new uv.lock>
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

PYTHON_FROM = 'requires-python = "==3.10.12"'
PYTHON_TO = 'requires-python = "==3.11.*"'
SCIPY_FROM = '"scipy==1.15.3"'
SCIPY_TO = '"scipy==1.16.3"'

# Packages whose locked version may change: scipy itself. Everything else must
# match mobius's lock exactly.
ALLOWED_CHANGES = {"scipy"}


def patch(pyproject: Path) -> None:
    text = pyproject.read_text()
    if PYTHON_TO in text and SCIPY_TO in text:
        print("converter environment already set to Python 3.11 + scipy 1.16.3")
        return
    for old in (PYTHON_FROM, SCIPY_FROM):
        count = text.count(old)
        if count != 1:
            sys.exit(
                f"error: expected {old} once in {pyproject}, found it {count} times. "
                "mobius's converter pins changed; update converter_env.py to match."
            )
    text = text.replace(PYTHON_FROM, PYTHON_TO).replace(SCIPY_FROM, SCIPY_TO)
    pyproject.write_text(text)
    print("converter environment: Python 3.10.12 -> 3.11, scipy 1.15.3 -> 1.16.3")


def locked_versions(lock: Path) -> dict[str, set[str]]:
    data = tomllib.loads(lock.read_text())
    versions: dict[str, set[str]] = {}
    for package in data.get("package", []):
        source = package.get("source", {})
        if "editable" in source or "virtual" in source:
            continue
        versions.setdefault(package["name"], set()).add(package.get("version", ""))
    return versions


def check_lock(original: Path, new: Path) -> None:
    before = locked_versions(original)
    after = locked_versions(new)
    drift = []
    dropped = []
    for name in sorted(before.keys() | after.keys()):
        if name in ALLOWED_CHANGES:
            continue
        old = before.get(name, set())
        cur = after.get(name, set())
        if old and not cur:
            # Backports only needed below Python 3.11 (tomli, exceptiongroup,
            # ...) may fall out of the lock. Dropping one adds no new code.
            dropped.append(name)
            continue
        if old != cur:
            drift.append(f"  {name}: {', '.join(sorted(old)) or '(none)'} -> {', '.join(sorted(cur)) or '(none)'}")
    if drift:
        sys.exit(
            "error: re-locking the converter for Python 3.11 changed packages other than scipy:\n"
            + "\n".join(drift)
        )
    scipy = ", ".join(sorted(after.get("scipy", set()))) or "(none)"
    if scipy != "1.16.3":
        sys.exit(f"error: the converter lock has scipy {scipy}, expected 1.16.3.")
    if dropped:
        print(f"dropped packages Python 3.11 doesn't need: {', '.join(dropped)}")
    print("converter lock matches mobius's pins except scipy 1.16.3")


def main(argv: list[str]) -> None:
    if len(argv) == 3 and argv[1] == "patch":
        patch(Path(argv[2]))
    elif len(argv) == 4 and argv[1] == "check-lock":
        check_lock(Path(argv[2]), Path(argv[3]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)

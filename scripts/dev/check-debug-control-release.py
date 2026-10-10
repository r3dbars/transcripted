#!/usr/bin/env python3
"""Prove the debug test control surface cannot ship in a release build.

The runtime (`Sources/App/DebugControlChannel.swift` plus the launch/URL
hooks in `Sources/App/TranscriptedApp.swift`) sits behind
`#if TRANSCRIPTED_DEBUG_CONTROL`, which only `build.sh` sets. `build-beta.sh`
never sets it and greps the compiled binary for
`TRANSCRIPTED_DEBUG_CONTROL_DIR`.

That env-var name is the distinctive string: it lives only inside the `#if`
file. Always-compiled sources (`DebugControlCommand.swift`,
`AutomatedLaunchEnvironment.swift`) must not contain it, or a release binary
would trip the grep even without the channel.

    python3 scripts/dev/check-debug-control-release.py
    python3 scripts/dev/check-debug-control-release.py --self-test

Offline, python3 stdlib only, writes nothing (self-test uses $TMPDIR).
"""

from __future__ import annotations

import argparse
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

CHANNEL = "Sources/App/DebugControlChannel.swift"
COMMAND = "Sources/App/DebugControlCommand.swift"
APP = "Sources/App/TranscriptedApp.swift"
ALE = "Sources/Support/AutomatedLaunchEnvironment.swift"
BUILD_SH = "scripts/entrypoints/build.sh"
BUILD_BETA = "scripts/entrypoints/build-beta.sh"
CLI = "scripts/dev/transcripted-debug.py"
DOCS = "docs/debug-control-surface.md"
INFO_PLIST = "Info.plist"

CONTROL_DIR = "TRANSCRIPTED_DEBUG_CONTROL_DIR"
COMPILE_FLAG = "TRANSCRIPTED_DEBUG_CONTROL"
HARNESS_KEY = "TRANSCRIPTED_AUTOMATED_HARNESS"
URL_SCHEME = "transcripted-debug"
SWIFTC_DEFINE = "APP_SWIFTC_TAIL_ARGS+=(-D TRANSCRIPTED_DEBUG_CONTROL)"
BINARY_GREP = 'grep -a -q -F "TRANSCRIPTED_DEBUG_CONTROL_DIR"'

ALLOWED_SOURCE_HITS = {CHANNEL}

REQUIRED_COMMANDS = (
    "ping",
    "state",
    "start_dictation",
    "stop_dictation",
    "start_meeting",
    "stop_meeting",
    "import_audio",
    "paste_target_open",
    "open_screen",
    "settings_get",
    "settings_set",
)


def read(root: Path, rel: str, problems: list[str]) -> str:
    path = root / rel
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        problems.append(f"{rel}: cannot read it")
        return ""


def preprocessor_lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip().startswith("#")]


def channel_is_guarded(text: str) -> list[str]:
    problems: list[str] = []
    directives = preprocessor_lines(text)
    if not directives or directives[0] != f"#if {COMPILE_FLAG}":
        problems.append(
            f"{CHANNEL}: first preprocessor line must be `#if {COMPILE_FLAG}` "
            "so a release compile sees an empty file"
        )
    if not text.rstrip().endswith("#endif"):
        problems.append(f"{CHANNEL}: file must end with `#endif` (no unguarded trailing code)")
    if directives.count(f"#if {COMPILE_FLAG}") != 1:
        problems.append(f"{CHANNEL}: wrap the whole file in one `#if {COMPILE_FLAG}`")
    if CONTROL_DIR not in text:
        problems.append(f"{CHANNEL}: must name {CONTROL_DIR} (the release binary grep target)")
    return problems


def unguarded_channel_refs(text: str) -> list[int]:
    depth = 0
    hits: list[int] = []
    for index, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith(f"#if {COMPILE_FLAG}"):
            depth += 1
        elif stripped.startswith("#endif") and depth:
            depth -= 1
        if "DebugControlChannel." in line and depth == 0:
            hits.append(index)
    return hits


def source_hits(root: Path, needle: str) -> list[str]:
    hits: list[str] = []
    sources = root / "Sources"
    if not sources.is_dir():
        return hits
    for path in sorted(sources.rglob("*.swift")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if needle in text:
            hits.append(str(path.relative_to(root)).replace("\\", "/"))
    return hits


def check(root: Path) -> list[str]:
    problems: list[str] = []
    channel = read(root, CHANNEL, problems)
    command = read(root, COMMAND, problems)
    app = read(root, APP, problems)
    ale = read(root, ALE, problems)
    build_sh = read(root, BUILD_SH, problems)
    build_beta = read(root, BUILD_BETA, problems)
    cli = read(root, CLI, problems)
    docs = read(root, DOCS, problems)
    info = read(root, INFO_PLIST, problems)

    if channel:
        problems.extend(channel_is_guarded(channel))

    if command and CONTROL_DIR in command:
        problems.append(
            f"{COMMAND}: must not contain {CONTROL_DIR}; it is compiled into every build"
        )
    if ale and CONTROL_DIR in ale:
        problems.append(
            f"{ALE}: must not contain {CONTROL_DIR}; use {HARNESS_KEY} so the "
            "distinctive string stays inside the #if file"
        )
    if ale and HARNESS_KEY not in ale:
        problems.append(f"{ALE}: keys must include {HARNESS_KEY} so the debug CLI activates the harness")

    for rel in source_hits(root, CONTROL_DIR):
        if rel not in ALLOWED_SOURCE_HITS:
            problems.append(
                f"{rel}: contains {CONTROL_DIR}. Only {CHANNEL} may name it, "
                "or a release binary will fail the build-beta grep even without the channel"
            )

    if app:
        if f"#if {COMPILE_FLAG}" not in app:
            problems.append(f"{APP}: launch/URL hooks must sit behind `#if {COMPILE_FLAG}`")
        if "DebugControlChannel.startIfRequested" not in app:
            problems.append(f"{APP}: missing DebugControlChannel.startIfRequested hook")
        if "DebugControlChannel.handleOpenURLs" not in app:
            problems.append(f"{APP}: missing DebugControlChannel.handleOpenURLs URL-scheme hook")
        unguarded = unguarded_channel_refs(app)
        if unguarded:
            problems.append(
                f"{APP}: DebugControlChannel refs outside `#if {COMPILE_FLAG}` at lines "
                + ", ".join(str(n) for n in unguarded)
            )

    if build_sh:
        if SWIFTC_DEFINE not in build_sh:
            problems.append(f"{BUILD_SH}: must always compile with `{SWIFTC_DEFINE}`")
        lab_if = build_sh.find('if [ "$TRANSCRIPTED_LAB_BUILD" = "1" ]')
        define_at = build_sh.find(SWIFTC_DEFINE)
        if define_at != -1 and lab_if != -1 and define_at > lab_if:
            problems.append(
                f"{BUILD_SH}: `{SWIFTC_DEFINE}` must stay on every local build, "
                "not only `--lab`"
            )
        if URL_SCHEME not in build_sh:
            problems.append(f"{BUILD_SH}: must register the {URL_SCHEME} URL scheme on the copied Info.plist")
        if "CFBundleURLSchemes" not in build_sh:
            problems.append(f"{BUILD_SH}: must add CFBundleURLSchemes for the debug URL hook")

    if build_beta:
        if 'TRANSCRIPTED_DEBUG_CONTROL:-0' not in build_beta and "${TRANSCRIPTED_DEBUG_CONTROL:-0}" not in build_beta:
            problems.append(f"{BUILD_BETA}: must refuse when TRANSCRIPTED_DEBUG_CONTROL is set")
        if SWIFTC_DEFINE in build_beta:
            problems.append(f"{BUILD_BETA}: must never add `{SWIFTC_DEFINE}`")
        if BINARY_GREP not in build_beta:
            problems.append(
                f"{BUILD_BETA}: must grep the compiled binary for {CONTROL_DIR} "
                f"(`{BINARY_GREP}`)"
            )

    if info and URL_SCHEME in info:
        problems.append(
            f"{INFO_PLIST}: must not register {URL_SCHEME}; only the copied debug Info.plist does"
        )

    if cli:
        if CONTROL_DIR not in cli:
            problems.append(f"{CLI}: must set {CONTROL_DIR} when launching")
        if HARNESS_KEY not in cli:
            problems.append(f"{CLI}: must set {HARNESS_KEY}=1 so AutomatedLaunchEnvironment is active")
        if "--self-test" not in cli:
            problems.append(f"{CLI}: must expose --self-test")

    if docs:
        if "schema_version" not in docs:
            problems.append(f"{DOCS}: must describe the versioned JSON state schema")
        missing = [name for name in REQUIRED_COMMANDS if name not in docs]
        if missing:
            problems.append(f"{DOCS}: missing command(s): {', '.join(missing)}")
        if URL_SCHEME not in docs:
            problems.append(f"{DOCS}: must name the {URL_SCHEME} URL scheme")
        if CONTROL_DIR not in docs:
            problems.append(f"{DOCS}: must name {CONTROL_DIR}")

    return problems


def run(root: Path) -> int:
    problems = check(root)
    if problems:
        print("Debug control release contract broken:")
        for item in problems:
            print(f"  - {item}")
        return 1
    print(
        "Debug control release contract OK: channel is #if-guarded, "
        f"{CONTROL_DIR} stays out of always-compiled sources, "
        "build.sh compiles it, build-beta.sh refuses and greps the binary."
    )
    return 0


def self_test() -> None:
    good = {
        CHANNEL: (
            f"// header\n#if {COMPILE_FLAG}\n"
            f'static let environmentKey = "{CONTROL_DIR}"\n#endif\n'
        ),
        COMMAND: "enum DebugControlCommandParser {}\n",
        APP: (
            f"#if {COMPILE_FLAG}\n"
            "DebugControlChannel.startIfRequested(appDelegate: self)\n"
            "#endif\n"
            f"#if {COMPILE_FLAG}\n"
            "func application(_ application: NSApplication, open urls: [URL]) {\n"
            "    DebugControlChannel.handleOpenURLs(urls, appDelegate: self)\n"
            "}\n"
            "#endif\n"
        ),
        ALE: f'static let keys = ["{HARNESS_KEY}"]\n',
        BUILD_SH: (
            f"{SWIFTC_DEFINE}\n"
            'if [ "$TRANSCRIPTED_LAB_BUILD" = "1" ]; then\n'
            "    APP_SWIFTC_TAIL_ARGS+=(-D TRANSCRIPTED_LAB_CONTROL)\n"
            "fi\n"
            "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string transcripted-debug\n"
        ),
        BUILD_BETA: (
            'if [ "${TRANSCRIPTED_DEBUG_CONTROL:-0}" != "0" ]; then\n'
            "    exit 1\n"
            "fi\n"
            f"{BINARY_GREP} \"$APP_BINARY\"\n"
        ),
        CLI: (
            f'CONTROL_ENV = "{CONTROL_DIR}"\n'
            f'HARNESS_ENV = "{HARNESS_KEY}"\n'
            "parser.add_argument('--self-test', action='store_true')\n"
        ),
        DOCS: (
            "schema_version\n"
            + "\n".join(REQUIRED_COMMANDS)
            + f"\n{URL_SCHEME}\n{CONTROL_DIR}\n"
        ),
        INFO_PLIST: "<plist></plist>\n",
    }

    def build(files: dict[str, str]) -> Path:
        tmp = Path(tempfile.mkdtemp())
        for rel, text in files.items():
            path = tmp / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return tmp

    assert check(build(good)) == []

    cases = [
        (CHANNEL, f"#if {COMPILE_FLAG}", "#if DEBUG", "unguarded channel"),
        (CHANNEL, CONTROL_DIR, "OTHER_DIR", "channel missing distinctive string"),
        (COMMAND, "enum DebugControlCommandParser {}", f"let x = \"{CONTROL_DIR}\"", "command leaked env name"),
        (ALE, HARNESS_KEY, "OTHER_HARNESS", "ALE missing harness key"),
        (ALE, f'static let keys = ["{HARNESS_KEY}"]\n', f'static let keys = ["{HARNESS_KEY}", "{CONTROL_DIR}"]\n', "ALE leaked env name"),
        (APP, "DebugControlChannel.startIfRequested(appDelegate: self)\n", "", "missing start hook"),
        (APP, f"#if {COMPILE_FLAG}\nDebugControlChannel.startIfRequested(appDelegate: self)\n#endif\n", "DebugControlChannel.startIfRequested(appDelegate: self)\n", "unguarded start hook"),
        (BUILD_SH, SWIFTC_DEFINE, "", "build.sh missing define"),
        (BUILD_SH, URL_SCHEME, "other-scheme", "build.sh missing URL scheme"),
        (BUILD_BETA, BINARY_GREP, "grep -a -q -F OTHER", "build-beta missing binary grep"),
        (BUILD_BETA, 'if [ "${TRANSCRIPTED_DEBUG_CONTROL:-0}" != "0" ]; then', "if false; then", "build-beta missing refuse"),
        (INFO_PLIST, "<plist></plist>", f"<string>{URL_SCHEME}</string>", "repo Info.plist registered scheme"),
        (CLI, HARNESS_KEY, "OTHER", "CLI missing harness key"),
        (DOCS, "schema_version", "no_schema", "docs missing schema"),
    ]
    for rel, old, new, why in cases:
        broken = dict(good)
        broken[rel] = broken[rel].replace(old, new, 1)
        assert check(build(broken)), why

    leaked = dict(good)
    leaked["Sources/Support/Other.swift"] = f'let key = "{CONTROL_DIR}"\n'
    assert check(build(leaked)), "distinctive string in another Sources file"

    assert check(build({})), "missing files should fail"
    print("check-debug-control-release self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    return run(REPO_ROOT)


if __name__ == "__main__":
    raise SystemExit(main())

"""audio-tap-install-unguarded: every `installTap(onBus:)` runs inside AudioTapInstallGuard.

`-[AVAudioNode installTapOnBus:...]` raises an Objective-C exception when the
input format moves between the caller's format read and the install. AirPods do
exactly that: opening their mic flips them to the 24 kHz call profile. Swift
can't catch the raise, so an unguarded call crashes the app at meeting or
dictation start. `AudioTapInstallGuard.run` turns it into a thrown error.

Two shapes are flagged:
  1. `.installTap(onBus: ...)` whose nearest enclosing closure isn't the
     `AudioTapInstallGuard.run { ... }` closure. Control-flow blocks (`if`,
     `guard`, `for`, `switch`, `do` ...) and inline synchronous closures
     (`autoreleasepool`, `withExtendedLifetime`) inside the guard closure are
     looked through; any other closure in between (a queue hop, a callback) is not,
     because the install would then run outside the guard.
  2. `installTap(onBus: ..., format: nil)`, guarded or not: a nil format
     assumes whatever the bus had last, which on AirPods is a stale 48 kHz
     (-10868). Pass the live hardware input format.

The driver protocol method `func installTap(on:format:onBuffer:)` doesn't match
`.installTap(onBus`, so the seams themselves aren't flagged.
"""

from __future__ import annotations

import re

from lint_rules._base import swift_file

RULE = {
    "id": "audio-tap-install-unguarded",
    "summary": "installTap(onBus:) called outside AudioTapInstallGuard.run, or with format: nil",
    "why": ("AVFoundation raises an uncatchable ObjC exception when the input format changes between "
            "validation and installTap (AirPods flipping to 24 kHz), crashing recording start: "
            "a6b2f4938, e25b7ee5f (Sentry APPLE-MACOS-2K), 3e1bea858; format: nil read a stale 48 kHz bus "
            "on AirPods (1e2b1352e)"),
    "fix": ("wrap the call: `try AudioTapInstallGuard.run(operation: \"<stage>\") { node.installTap(onBus: 0, "
            "bufferSize: ..., format: liveFormat) { ... } }` (Sources/TranscriptedCore/Audio/AudioTapInstallGuard.swift); "
            "for dictation go through ParakeetAudioGraphStartDriver.installTap, for meetings through "
            "MeetingMicGraphStartSequence; always pass the live hardware input format, never nil"),
    "owner_doc": "Sources/Speech/AGENTS.md",
    "level": "lint",
    "paths": ["Sources/**/*.swift", "Tools/**/*.swift"],
    "exclude": [],
    "ratchet": False,
    "proof": [
        # e25b7ee5f^: before the guard existed (ParakeetEngine, AudioDeviceRecovery, AudioFileManager)
        "edeb216363298fafbe3d66f29722a5d1fbc056fb:Sources/TranscriptedCore/Audio/AudioDeviceRecovery.swift",
        "edeb216363298fafbe3d66f29722a5d1fbc056fb:Sources/Speech/ParakeetEngine.swift",
        "edeb216363298fafbe3d66f29722a5d1fbc056fb:Sources/TranscriptedCore/Audio/AudioFileManager.swift",
        # a6b2f4938^: meeting mic tap install crashed when AirPods switched format
        "b98ba08e39c9027683ca28b00a999babb76c3296:Sources/TranscriptedCore/Audio/AudioDeviceRecovery.swift",
        # 1e2b1352e^: dictation tap installed with format: nil
        "c35aea2d024ab294a2ebd860a5716df4f233fa84:Sources/Speech/ParakeetEngine.swift",
    ],
}

_CALL = re.compile(r"\.\s*installTap\s*\(\s*onBus\b")
# Arguments up to the trailing closure: no braces in between, may span lines.
_NIL_FORMAT = re.compile(r"\binstallTap\s*\(\s*onBus\b[^{}]*?\bformat\s*:\s*nil\b")
_GUARD = re.compile(r"\bAudioTapInstallGuard\s*\.\s*run\b")
_CONTROL_HEAD = re.compile(r"\A\s*(?:\}\s*)?(?:if|else|guard|for|while|repeat|switch|case|default|do|catch|defer)\b")
# Closures that run inline, synchronously, in the caller: still inside the guard.
_INLINE_CLOSURE = re.compile(r"\b(?:autoreleasepool|withExtendedLifetime)\s*(?:\(|\{|$)")
_WINDOW = 4

UNGUARDED_MSG = ("`installTap(onBus:)` outside `AudioTapInstallGuard.run { }`: a format change between your "
                 "format read and the install (AirPods flipping to 24 kHz) raises an ObjC exception Swift "
                 "can't catch and the app crashes; wrap it in `try AudioTapInstallGuard.run(operation:) { ... }`")
NIL_FORMAT_MSG = ("`installTap(..., format: nil)` takes the bus's last format, which is stale on AirPods "
                  "(-10868); pass the live hardware input format (see Sources/Speech/AGENTS.md)")


def _guarded(sf, offset: int) -> bool:
    if sf.balanced:
        for scope in reversed(sf.enclosing(offset)):
            if scope.kind != "block":
                return False  # reached a func/type without passing the guard closure
            if _GUARD.search(scope.head):
                return True
            last = scope.head.strip().split("\n")[-1] if scope.head.strip() else ""
            if _CONTROL_HEAD.match(last) or _INLINE_CLOSURE.search(last):
                continue  # if/for/switch body or inline closure inside the guard closure
            return False  # some other closure sits between the guard and the call
        return False
    # Scope answers are unreliable when braces don't balance: fall back to the
    # same line or the few lines above (the guard closure's opening).
    line = sf.line_of(offset)
    lo = max(0, line - 1 - _WINDOW)
    return any(_GUARD.search(l) for l in sf.code_lines[lo:line])


def check(path: str, text: str):
    if "installTap" not in text:
        return []
    sf = swift_file(text)
    out = []
    for line, m in sf.find(_CALL):
        if not _guarded(sf, m.start()):
            out.append((line, UNGUARDED_MSG))
    for line, _m in sf.find(_NIL_FORMAT):
        out.append((line, NIL_FORMAT_MSG))
    return out

"""main-actor-blocking-io: blocking file, SQLite or window-server work on the main actor.

Views and @MainActor controllers keep calling synchronous disk helpers inline:
a Settings delete that rewrites a day file, a rename that lists folders, a
stats read that opens SQLite. Each one froze the window for someone on an
evicted iCloud file or a busy disk. The same helpers are fine from a detached
task, a background queue or the CLI, so this can't be a type rule; it's a
curated list of calls that block, flagged only where the enclosing code is
main-actor isolated.

How isolation is decided (inner scope to outer, first answer wins):
  - a `nonisolated` decl or a `@concurrent` func            -> off main
  - `@MainActor` on the decl, or a closure `{ @MainActor in` -> main
  - a closure handed to an offload call anywhere in the statement that opens
    it (Task.detached, DispatchQueue.global, someQueue.async/asyncAfter,
    withChecked(Throwing)Continuation, group.addTask, Thread.detachNewThread,
    BlockOperation / queue.addOperation, addObserver(..., queue: <not main>))
    -> off main. `.sync`, `asyncAndWait` and `concurrentPerform` still block
    the caller, so they are not offloads. The whole statement is read, so a wrapped
    `Task.detached(\n priority: .x\n) {` still counts.
  - `DispatchQueue.main.async {` / `MainActor.run {`          -> main
  - an `actor`                                              -> off main
  - a type or extension that is @MainActor or inherits View, NSView,
    NSWindowController ... in this file, or (for an extension of a type
    declared elsewhere) anywhere under Sources/              -> main
Other closures inherit their context. That's right for `Task { }`, SwiftUI
actions and stored UI callbacks, which is where the real hits were.
"""

from __future__ import annotations

import functools
import re

from lint_rules._base import MAIN_ACTOR_SUPERTYPES, REPO_ROOT, swift_file

RULE = {
    "id": "main-actor-blocking-io",
    "summary": "No synchronous disk, file-library, SQLite or window-list calls on the main actor (views, @MainActor controllers).",
    "why": "Froze the UI on slow or evicted files: 5f7a490b8 (dictation delete/undo in Settings), "
           "5649d7cd7 (rename/speaker edit file lookups), f2a61b145 (NSSound startup), 3a6cfbc10 (stats SQLite), 86d7a8ec1.",
    "fix": "Move the call into `try await Task.detached(priority: .userInitiated) { ... }.value` (see "
           "deleteDictationWithUndo in Sources/UI/Settings/TranscriptedSettingsView+Pages.swift), a background "
           "DispatchQueue, or a `nonisolated` helper, and hop back to the main actor only to update UI state.",
    "owner_doc": "Sources/UI/AGENTS.md",
    "level": "lint",
    "paths": [
        "Sources/UI/**/*.swift",
        "Sources/App/**/*.swift",
        "Sources/Meeting/**/*.swift",
        "Sources/Dictation/**/*.swift",
        "Sources/Writing/**/*.swift",
        "Sources/Support/**/*.swift",
        "Sources/Speech/**/*.swift",
    ],
    "exclude": [],
    "ratchet": True,
    "proof": [
        "7d9e0fb43:Sources/UI/Settings/TranscriptedSettingsView+Pages.swift",
        "a30f0e725:Sources/UI/Settings/TranscriptedSettingsView+HomeMeetingActions.swift",
        "a30f0e725:Sources/Meeting/MeetingCaptureBridge.swift",
    ],
}

# Apple APIs that hit the disk, SQLite or the window server synchronously.
_APPLE = (
    r"FileManager\.default\.(?:removeItem|moveItem|copyItem|contentsOfDirectory|createDirectory"
    r"|attributesOfItem|setAttributes|replaceItem|trashItem)\b"
    r"|\bData\(\s*contentsOf:"
    r"|\bString\(\s*contentsOf:"
    r"|\.write\(\s*to:"
    r"|\bNSSound\(\s*(?:contentsOf|named:)"
    r"|\bAVAudioPlayer\(\s*contentsOf"
    r"|\bsqlite3_(?:open|exec|step|prepare)\w*\("
    r"|\bCGWindowListCopyWindowInfo\("
    r"|\.resourceValues\(\s*forKeys:"
)

# Project helpers that do file-library work synchronously. Each of these is
# meant to be called from a detached task or background queue.
_HELPER_TYPES = (
    "DictationTranscriptStore", "DictationAudioArchive", "OwnFileResolver", "HomeMeetingRename",
    "HomeMeetingSpeakerRename", "MeetingAudioArchiveResolver", "RecordingAudioArchiver", "TranscriptSaver",
)
# Pure members on those types (string parsing, in-memory state) don't block.
_PURE_HELPER_MEMBERS = (
    "takeStem", "hasReplacementReservation", "extractYAMLQuotedString", "lockStorageMutation",
    "unlockStorageMutation",
)
_HELPERS = (r"\b(?:" + "|".join(_HELPER_TYPES) + r")\.(?!(?:" + "|".join(_PURE_HELPER_MEMBERS)
            + r")\b)[a-z]\w*\(")

BLOCKING_RE = re.compile(r"(?:" + _APPLE + r")|(?:" + _HELPERS + r")")

# Cheap pre-filter: a file must look like UI or main-actor code at all.
_SCOPE_HINT = re.compile(r"@MainActor|:\s*[^{\n]*\bView\b|NSApplicationDelegate|NSViewController|NSWindowController"
                         r"|\bextension\s+\w")

_OFFLOAD_RE = re.compile(
    r"\bTask\.detached\b"
    r"|\bDispatchQueue\.global\b"
    r"|\bwithChecked(?:Throwing)?Continuation\b"
    r"|\bwithUnsafe(?:Throwing)?Continuation\b"
    r"|\.addTask(?:UnlessCancelled)?\b"
    r"|\bThread\.detachNewThread\b"
    r"|\bThread\s*\{"
    r"|\bBlockOperation\b"
    r"|\.addOperation\b"
    # NotificationCenter.addObserver(forName:object:queue: someBackgroundQueue) { }
    r"|\baddObserver\s*\([^{}]*\bqueue\s*:\s*(?!nil\b|\.main\b|OperationQueue\.main\b)[\w.]"
)
# `.sync` / `asyncAndWait` / `concurrentPerform` still block the caller, so
# they are not an offload.
_QUEUE_CALL_RE = re.compile(r"([\w.()\[\]]*?)\.(?:async|asyncAfter)\b(?!AndWait)")
_MAIN_HOP_RE = re.compile(r"\bMainActor\.run\b|\bDispatchQueue\.main\b|\bRunLoop\.main\.perform\b|\bOperationQueue\.main\b")


def _block_isolation(head: str):
    """Isolation a closure gets from the statement that opens it, or None
    when it inherits. `head` may span several lines."""
    flat = re.sub(r"\s+", " ", head)
    if _MAIN_HOP_RE.search(flat):
        # `DispatchQueue.main.async {` / `await MainActor.run {`: main, unless an
        # offload call comes later in the same statement.
        last_main = max(m.start() for m in _MAIN_HOP_RE.finditer(flat))
        last_off = max((m.start() for m in _OFFLOAD_RE.finditer(flat)), default=-1)
        return "main" if last_main > last_off else "off"
    if _OFFLOAD_RE.search(flat):
        return "off"
    for m in _QUEUE_CALL_RE.finditer(flat):
        receiver = m.group(1)
        if re.search(r"\bmain\b", receiver):
            return "main"
        return "off"
    return None


_TYPE_DECL_RE = re.compile(
    r"^[ \t]*((?:@[A-Za-z_][\w.]*(?:\([^()\n]*\))?\s+)*)"
    r"(?:(?:public|private|fileprivate|internal|package|open|final|indirect)\s+)*"
    r"(class|struct|enum|extension)\s+([A-Za-z_][\w.]*)(?:<[^{>]*>)?\s*(?::\s*([^{]*?))?(?:\bwhere\b[^{]*)?\{",
    re.M,
)


def _main_actor_names(text: str) -> set:
    names = set()
    for m in _TYPE_DECL_RE.finditer(text):
        attrs, kind, name, inherits = m.group(1), m.group(2), m.group(3), m.group(4) or ""
        parents = {p.strip().split(".")[-1] for p in re.sub(r"<[^<>]*>", "", inherits).split(",")}
        if "@MainActor" in attrs or MAIN_ACTOR_SUPERTYPES.intersection(parents):
            names.add(name.split(".")[-1])
    return names


@functools.lru_cache(maxsize=1)
def _repo_main_actor_types() -> frozenset:
    """Main-actor type names declared anywhere under Sources/ (a regex scan,
    only run when a file extends a type it doesn't declare)."""
    names = set()
    root = REPO_ROOT / "Sources"
    for path in root.rglob("*.swift"):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "@MainActor" in text or "View" in text or "NS" in text:
            names |= _main_actor_names(text)
    return frozenset(names)


def _isolation(sf, offset: int, known) -> str | None:
    for s in reversed(sf.enclosing(offset)):
        if "nonisolated" in s.modifiers or "concurrent" in s.attrs:
            return "off"
        if "MainActor" in s.attrs:
            return "main"
        if s.kind == "block":
            iso = _block_isolation(s.head)
            if iso:
                return iso
            continue
        if s.kind == "actor":
            return "off"
        if s.is_type:
            base = s.name.split(".")[-1]
            if base in known or MAIN_ACTOR_SUPERTYPES.intersection(s.inherits):
                return "main"
            if s.kind != "extension":
                # A nested non-UI type inside a UI type isn't main-actor.
                return None
    return None


def check(path: str, text: str):
    if not BLOCKING_RE.search(text) or not _SCOPE_HINT.search(text):
        return []
    sf = swift_file(text)
    hits = list(sf.find(BLOCKING_RE))
    if not hits:
        return []
    known = set(sf.main_actor_types)
    declared = {s.name.split(".")[-1] for s in sf.scopes if s.is_type and s.kind != "extension"}
    extended = {s.name.split(".")[-1] for s in sf.scopes if s.kind == "extension"}
    if extended - declared - known:
        known |= _repo_main_actor_types()
    out = []
    seen = set()
    for line, m in hits:
        if line in seen:
            continue
        if _isolation(sf, m.start(), known) != "main":
            continue
        seen.add(line)
        call = re.sub(r"\s+", "", m.group(0)).rstrip("(")
        out.append((line, f"`{call}` blocks on disk/SQLite/window server and runs on the main actor here"))
    return out

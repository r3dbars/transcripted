# Agent Surface Consolidation Plan

Status: proposal. Nothing in here changes runtime behavior yet. This is the
map for collapsing Transcripted's agent-facing surfaces into two contracts:
the capture file format, and one query engine.

## The problem

An agent (or a curious user) currently has five ways to get at capture data:

1. raw folder reads of the capture Markdown
2. `transcripted-cli` (context commands; not distributed to end users)
3. `transcripted-mcp` (12 stdio tools; bundled with the app)
4. the `AgentLiveMeeting/` sidecar file protocol (`state.json`,
   `agent-handoff.md`, `agent-watcher-state.json`)
5. the tokenized loopback preview server for live meetings

Behind those surfaces sit three parsers of the same Markdown (the app's
`TranscriptFrontmatter`/scanner, `TranscriptedCaptureKit`, and the styler's
own body parser), two derived stores (`state/stats.sqlite` in the app,
`mcp_index.sqlite` in the MCP helper), and a four-tier directory resolution
order that still checks the legacy `com.justinbetker.draft` preference domain.

Costs of this shape today:

- the MCP helper rebuilds its whole index from disk on every startup, and its
  file watcher runs full reconcile scans on change
- CLI and MCP can disagree with the app about which directories are live
- every format change must be mirrored by hand in `TranscriptedCaptureKit`
- the sidecar asks agents to correctly run a multi-file polling protocol from
  prose instructions

## Target architecture

### One helper binary

Merge `TranscriptedCLI`'s context commands and `TranscriptedMCP` into a single
`transcripted` helper:

```text
transcripted mcp            # stdio MCP server (what Connect wires up)
transcripted status         # resolved dirs, counts, index freshness
transcripted recent|search|read-meeting|read-dictation ...
```

One distribution story (bundled in the app, optional "Install command line
tool" action that symlinks into PATH), one resolver, one set of models, one
README. The offline diarization commands move to a separate dev-only tool or
stay compile-gated out of the shipped binary; their `--help` must not
advertise features a stub build cannot run.

### One index, maintained by the writer

The app already knows every capture at save time. It should maintain the
catalog/index as part of saving (either the existing SQLite shape or an
append-friendly `captures/index` catalog), and the helper opens it read-only.

- helper startup stops scaling with library size (no full rescan)
- the file watcher shrinks to a cheap invalidation check for edits made
  outside the app
- every consumer (MCP, CLI subcommands, third parties) reads one catalog
- the catalog can list multiple roots, which turns "move the capture library"
  into "add a root" and stops relocation from stranding history

The helper keeps a fallback: if no app-written index exists (deleted, stale
schema, external edits), it rebuilds from disk exactly as today.

### One resolution order

Directory resolution lives in `TranscriptedCaptureKit` only, exposes which
rule won (for `status` and self-test output), and drops the legacy Draft
preference domain behind a deprecation window: log when a legacy path is the
only source of captures, offer a one-time migration in the app, then remove
the fallback.

### One file format

Prerequisite work tracked separately: a `docs/capture-format.md` spec,
`format_version` in frontmatter, and ending the two-format meeting lifecycle
by styling at save time instead of restyling asynchronously after save. Once
the writer emits the final format once, the styler's body parser disappears
and `TranscriptedCaptureKit` becomes the only reader implementation.

### Live meetings ride the same surface

The loopback preview server already exists. Long-term, the live sidecar
should be exposed through the same helper surface (an MCP resource/tool for
live state plus a "capture saved" event) instead of a prose-driven file
polling protocol. The `AgentLiveMeeting/` files stay as the local substrate;
agents stop needing to know their names.

## Migration steps

1. **Spec + version the format** (separate PR series; no behavior change).
2. **Expose resolution source + `status`** in CaptureKit/MCP so the current
   system becomes observable before it changes.
3. **Move CLI context commands into the MCP package** as subcommands of one
   executable; keep `transcripted-cli` building as a thin shim for one
   release, then delete it. Update `docs/agent-connect.md`, `build.sh`
   bundling, and the Connect installer path.
4. **App-maintained index**: app writes/updates the catalog at save, restyle,
   rename, and delete (the `CaptureLibraryChangeBroadcaster` call sites are
   the natural hooks). Helper prefers the catalog, falls back to rescan.
5. **Multi-root catalog + relocation flow**: Settings relocation registers
   the old root instead of forgetting it; MCP/CLI read all roots.
6. **Legacy Draft deprecation**: log-only release, then in-app migration
   offer, then remove the `com.justinbetker.draft` domain and
   `~/Documents/Transcripted` fallbacks from the resolver.
7. **Live sidecar over the helper surface** once steps 3–4 are stable.

Each step is independently shippable and reversible; nothing requires a
flag-day change to saved files.

## Risks

- **Index ownership moves across a process boundary.** The app writes, the
  helper reads. SQLite WAL handles this, but schema changes now need a
  compatibility gate on both sides (`user_version` check + fallback rescan).
- **The shim release.** Anything that hardcodes the `transcripted-cli` or
  `transcripted-mcp` binary names (user configs, `claude_desktop_config.json`
  entries written by old app versions) must keep working; the Connect
  self-heal path already rewrites the helper, which covers most installs.
- **Deleting the legacy fallback can orphan real data.** The deprecation
  window exists so removal only happens after the app has offered migration
  and telemetry shows legacy-only libraries are gone.

## Verification

- steps 2–3: `swift test` for the affected `Tools/` packages plus
  `bash run-e2e-smoke.sh`
- steps 4–6: the `.agents/test-matrix.yml` app rules
  (`build.sh --no-open`, `run-tests.sh`, integration smoke) plus a manual
  relocation walk-through
- every step: `transcripted status` (or `--self-test`) before/after must
  report the same directories and counts on an unchanged library

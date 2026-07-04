# Capture Markdown format

This is the authoritative spec for the Markdown files Transcripted saves under
the capture library (`<capture-library>/meetings/`,
`<capture-library>/dictations/`, and `<capture-library>/timeline/`). Agents and standalone tools parse these
files, so treat this document as the contract. Writers live in
`Sources/TranscriptedCore/Storage/TranscriptFormatter.swift`,
`Sources/Meeting/MeetingTranscriptStyler.swift`,
`Sources/Meeting/MeetingQuickSummaryWriter.swift`,
`Sources/Meeting/LocalMeetingSummarizer.swift`, and
`Sources/Dictation/DictationTranscriptWriter.swift`; timeline day output is
written by `Sources/Timeline/TimelineMarkdownWriter.swift`. Readers include the app's
Home scanner (`TranscriptFrontmatter`), `Tools/TranscriptedCaptureKit` (used by
the CLI and MCP tools), and `Tools/TranscriptedQA`. If you change the written
format, update this doc, the CaptureKit parsers, and their tests in the same
change.

## Versioning

Two flat frontmatter keys carry the contract:

- `format_version: 1` — the capture-format version. **Absent means the file
  predates versioning; parse it exactly like version 1.** The grammar below has
  not changed since before the key existed — the key was added so future
  breaking changes have somewhere to land. Bump the number only for a breaking
  change; additive changes stay within the current version.
- `transcript_style: raw | styled` — which meeting body grammar the file
  currently carries (meetings only; see the lifecycle below). Absent means the
  file predates the key: sniff the body heading instead (`## Full Transcript`
  → raw, `## Transcript` → styled).

Dictation day files carry `format_version` but no `transcript_style` (they have
a single body grammar).

Timeline day files carry `format_version` but no `transcript_style` (they have
a single body grammar).

## Stability rules

1. **Flat `key: value` frontmatter only.** The app's own scanner
   (`TranscriptFrontmatter.values(from:)`) skips indented lines, so nested YAML
   is invisible to it (see the Issue #500 comment in
   `TranscriptFormatter.swift`). New keys must be top-level. The only nested
   blocks are the pre-existing `gap_events`, `speakers`, `tags`, `aliases`, and
   `cssclasses`; parsers that need them re-read the raw frontmatter lines.
2. **Parsers must ignore unknown keys.** Writers append keys over a file's
   lifetime (`auto_summary_*`, `local_summary_*`), and future app versions will
   add more.
3. **Additive changes only within a version.** Never rename or remove a key, or
   change an existing key's value format, without bumping `format_version`.
4. Frontmatter values may be quoted or bare; parsers strip surrounding double
   quotes. Escaping for quoted scalars follows `TranscriptSaver.escapeYAML`.
5. Key order is not guaranteed. Match by key, not position.

## Meeting file lifecycle

A meeting transcript is written once and then rewritten in place up to two
times. **Any stage after the first can be skipped** (the restyle fails closed
on bodies it cannot parse; the app can also quit first), so all intermediate
shapes exist in the wild:

1. **Initial save** — `TranscriptFormatter.formatTranscriptMarkdown` writes the
   raw form to `Call_<YYYY-MM-dd_HH-mm-ss>.md` (collision suffix `_<n>`), with
   `format_version: 1` and `transcript_style: raw`.
2. **Quick-summary injection** — `MeetingQuickSummaryWriter` appends the
   `auto_summary_*` keys to the frontmatter. Frontmatter-only; the body is
   preserved verbatim, and all non-`auto_summary_*` keys (including
   `format_version` / `transcript_style`) survive. Idempotent: it never re-runs
   once `auto_summary_version` exists.
3. **Restyle + rename (async)** — `MeetingTranscriptStyler.restyleTranscript`
   rewrites the body into the styled form, re-emits `title:` first, preserves
   every other frontmatter line (including `format_version`), rewrites
   `transcript_style` to `styled` (replacing the `raw` marker — never
   duplicated; legacy files without the key gain it), and renames the file to
   `<YYYY-MM-dd> <title>.md` (collision suffix ` <n>`). Retained audio
   directories and summary sidecars follow the rename
   (`MeetingArtifactRenamer`).

Later optional writers: the heavy local summarizer (`local_summary_*` keys plus
a managed body block) and the Home title editor (rewrites `title:` and renames
again). All are frontmatter-preserving.

## Meeting frontmatter keys

Written at initial save (all flat unless noted):

| Key | Example | Notes |
|-----|---------|-------|
| `capture_id` | `"5E9A…"` | UUID, quoted. Same value as `transcript_id`. |
| `capture_type` | `meeting` | Discriminator; dictation day files use `dictation_day`. |
| `format_version` | `1` | See Versioning. Absent = pre-versioning. |
| `transcript_style` | `raw` / `styled` | See Versioning and lifecycle. |
| `transcript_id` | `"5E9A…"` | UUID, quoted. |
| `date` | `2026-04-07` | `yyyy-MM-dd`, local time. |
| `time` | `09:14:00` | `HH:mm:ss`, local time. |
| `duration` | `"12:30"` | `m:ss` (minutes may exceed 59), quoted. |
| `processing_time` | `"41.3s"` | Seconds with one decimal + `s`, quoted. |
| `transcription_engine` | `parakeet_local` | Engine identifier. |
| `diarization_engine` | `pyannote_offline` | |
| `sources` | `[mic, system_audio]` | Inline list of captured channels. |
| `mic_utterances` | `12` | |
| `system_utterances` | `34` | |
| `mic_speakers` | `1` | |
| `system_speakers` | `2` | |
| `total_word_count` | `1204` | |
| `title` | `"Weekly Sync"` | Optional at save (imported audio, detected meetings); the restyle always writes one. |

Recording-health keys (optional, only when health info exists):

| Key | Example | Notes |
|-----|---------|-------|
| `capture_quality` | `excellent` | `excellent` / `good` / `fair` / `degraded`. |
| `audio_gaps` | `0` | |
| `device_switches` | `0` | |
| `gap_events` | — | **Nested** list of quoted strings; invisible to flat parsers. Omitted when empty. |
| `audio_health` | `mic_attenuated_by_call_app` | Flat; omitted for healthy meetings. |
| `mic_boost_prompt` | `"declined"` | Flat; only alongside `audio_health`. |

Speaker metadata (optional, **nested** `speakers:` block — flat parsers skip
it; CaptureKit and the app re-read the raw lines):

```yaml
speakers:
  - id: "0"
    channel: mic          # mic | system; older files may omit (treat as system)
    db_id: "1111…"        # optional persistent speaker DB UUID
    name: "Justin"
    confidence: high      # high | medium | manual | unknown
    source: db_scan
```

Obsidian metadata (optional, when the user enables it): nested `tags:`
(`transcripted`, `meeting`, `speaker/<name>`), `aliases:`, `cssclasses:`
blocks; named speakers in the body are wrapped in `[[wiki links]]`.

Summary namespaces appended later (all flat, quoted values, bullet lines
flattened with `" | "`):

- `auto_summary_*` (always-on cheap extraction): `auto_summary_version`,
  `auto_summary_generated_at`, `auto_summary_method`,
  `auto_summary_participants`, `auto_summary`, `auto_summary_decisions`,
  `auto_summary_action_items`, `auto_summary_open_questions`,
  `auto_summary_risks_or_followups`, `auto_summary_accuracy_notes`.
- `local_summary_*` (opt-in heavy summarizer): `local_summary_version`,
  `local_summary_source_transcript`, `local_summary_title`,
  `local_summary_generated_at`, `local_summary_provider`,
  `local_summary_model`, `local_summary_runtime`, `local_summary_profile`,
  `local_summary_chunk_count`, `local_summary_participants`, `local_summary`,
  `local_summary_next_steps`, `local_summary_commitments`,
  `local_summary_decisions`, `local_summary_action_items`,
  `local_summary_open_questions`, `local_summary_risks_or_followups`,
  `local_summary_accuracy_notes`.

Index precedence: prefer `local_summary_*` when present, else `auto_summary_*`.

## Meeting body: raw form (`transcript_style: raw`)

Written at initial save. Filename `Call_<YYYY-MM-dd_HH-mm-ss>.md`.

```markdown
# Meeting Recording - Apr 7, 2026 at 9:14 AM

**Duration:** 12:30 | **Words:** 42 | **Utterances:** 2

---

---

## Channel & Speaker Analytics

### Microphone (You)
- **Utterances:** 1
- **Words:** ~20
- **Speaking Time:** 22s

### Meeting Audio (Remote Participants)
- **Utterances:** 1
- **Words:** ~22
- **Speaking Time:** 31s
- **Speakers Detected:** 1

#### Remote Speaker Breakdown

- **Sarah:** 1 utterances, ~22 words, 31s

---

## Full Transcript

[00:00] [Mic/You] Thanks for making time today.

[00:04] [System/Sarah] Happy to help. Let's get started.

---

*Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 12:30 | 42 words | 2 speakers*
```

Transcript grammar: one entry per line under `## Full Transcript`, blank line
between entries:

```
[<MM:SS>] [<Mic|System>/<speaker label>] <text>
```

Mic labels default to `You` (or a named speaker with local-speaker review);
system labels default to `Speaker <n>` until named. With Obsidian metadata
enabled, named labels are wiki-linked: `[System/[[Sarah]]]`. Multi-speaker mic
captures add a `### Microphone (People in the Room)` heading and a
`#### Local Speaker Breakdown` section. When mic capture is disabled the
microphone section is omitted and `sources` reflects it.

## Meeting body: styled form (`transcript_style: styled`)

Produced by the async restyle. Filename `<YYYY-MM-dd> <title>.md`.

```markdown
---
title: "Meeting with Sarah"
capture_id: "5E9A…"
capture_type: meeting
format_version: 1
transcript_id: "5E9A…"
date: 2026-04-07
time: 09:14:00
…all other preserved keys…
transcript_style: styled
---

# Meeting with Sarah

Recorded Apr 7, 2026 at 9:14 AM  •  12 min, 30 sec  •  42 words  •  2 turns

## Transcript

**00:00**  [Mic/You]
Thanks for making time today.

**00:04**  [System/Sarah]
Happy to help. Let's get started.
```

Details:

- The detail line joins parts with `  •  ` (two spaces around a bullet):
  `Recorded <medium date, short time>`, humanized duration, word count and turn
  count when nonzero.
- Transcript entries are blank-line-separated blocks: a header line
  `**<MM:SS>**  [<Mic|System>/<label>]` (two spaces after the bold timestamp)
  followed by the utterance text on the next line(s).
- An empty transcript renders as `_No transcript captured._`.
- A managed local-summary body block (between
  `LocalMeetingSummaryMarkdownUpdater` markers), when present, is preserved
  after the transcript.
- The restyle fails closed: if the body carries transcript text the entry
  parser cannot understand, the file is left byte-for-byte untouched (still
  raw-form, still `transcript_style: raw` if it had it).

## Dictation day files

`Sources/Dictation/DictationTranscriptWriter.swift` appends completed
dictations into one file per local day:
`<capture-library>/dictations/Dictations_<YYYY-MM-dd>.md`.

```markdown
---
title: "Dictations for April 7, 2026"
date: 2026-04-07
capture_type: dictation_day
format_version: 1
---

# Dictations for April 7, 2026

## 9:15 AM - first note from the morning

Entry ID: `dictation-20260407-091500-123-8c…`
Captured: 2026-04-07T09:15:00.000Z
Source app: Slack
Bundle ID: `com.tinyspeck.slackmacgap`
Delivery: pasted
Words: 5
Characters: 27

first note from the morning

## 4:45 PM - second note from the afternoon

…
```

Details:

- The day header is written once, when the file is created; later saves append
  sections only. Header keys are flat; `format_version` follows the same
  convention as meetings.
- Section heading: `## <h:mm a> - <title>` where the title is the first ~7
  words of the text (or `Dictation <MMM d> at <h:mm a>` for very short text).
- Metadata lines, in order: `Entry ID:` (backticked), `Captured:` (ISO 8601
  with fractional seconds), `Source app:`, optional `Bundle ID:` (backticked,
  omitted when unknown), `Delivery:`, `Words:`, `Characters:`. Older files may
  carry `Timestamp:` instead of `Captured:`.
- `Delivery` values: `pasted`, `copied`, `failed`, `saved_without_paste`.
- The dictated text follows after a blank line and runs to the next `## `
  heading or end of file.

## Timeline day files

`Sources/Timeline/TimelineMarkdownWriter.swift` writes one file per local day:
`<capture-library>/timeline/<YYYY-MM-dd>.md`.

```markdown
---
capture_type: timeline
format_version: 1
date: 2026-04-07
card_count: 2
active_minutes: 75
categories:
  - "Meetings"
  - "Work"
---

# Timeline - 2026-04-07

1. **9:15 AM - 9:45 AM - Launch review**
   _Meetings_
   - Kind: meeting
   - Summary: Reviewed launch milestones.
   - Details: Waiting on packaging proof.
   - Transcript: [transcript](../meetings/Call_2026-04-07_09-15-00.md)

2. **10:00 AM - 10:45 AM - Plan cleanup**
   _Work_
   - Kind: activity
   - Summary: Consolidated next actions.
```

Details:

- Filename is the stable local day key: `<YYYY-MM-dd>.md`.
- Frontmatter keys are flat except `categories`, which is a simple YAML list.
- `card_count` must match the number of numbered cards in the body.
- `active_minutes` is the sum of nonnegative card durations rounded down to
  whole minutes.
- Timeline Markdown is an agent-readable digest only. It must not include
  screenshots or raw OCR text.
- Meeting links are relative to the timeline folder and point at
  `../meetings/<filename>.md`.

## Parser guidance

- Detect meetings via `capture_type: meeting`; fall back to the transcript
  headings for pre-`capture_type` files. Detect dictation day files via
  `capture_type: dictation_day` or the `Dictations_` filename prefix. Detect
  timeline day files via `capture_type: timeline`.
- Choose the meeting body grammar by `transcript_style` when present, else by
  heading: `## Full Transcript` (raw) vs `## Transcript` (styled). Robust
  parsers accept both grammars in either file (see
  `Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureMarkdownParser.swift`).
- Treat every key as optional. Missing `format_version` = version 1 semantics.
- `Tools/TranscriptedCaptureKit` exposes `format_version` / `transcript_style`
  as optional `formatVersion` / `transcriptStyle` fields on
  `ParsedMeetingCapture` and `formatVersion` on `ParsedDictationDayCapture`.
  It also exposes `TimelineMarkdownParser` for timeline day files.

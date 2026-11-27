# Capture Markdown format

This is the authoritative spec for the Markdown files Transcripted saves under
the capture library (`<capture-library>/meetings/`,
`<capture-library>/dictations/`, and `<capture-library>/writing/`). Agents and
standalone tools parse these files, so treat this document as the contract.
Writers live in
`Sources/TranscriptedCore/Storage/TranscriptFormatter.swift`,
`Sources/Meeting/MeetingTranscriptStyler.swift`,
`Sources/Dictation/DictationTranscriptWriter.swift`, and the main app's Writing
day-file writer (never the keyboard). Readers include the app's
Home scanner (`TranscriptFrontmatter`), `Tools/TranscriptedCaptureKit` (used by
the CLI and MCP tools), and `Tools/TranscriptedQA`. If you change the written
format, update this doc, the CaptureKit parsers, and their tests in the same
change.

## Versioning

Two flat frontmatter keys carry the contract:

- `format_version` — the capture-format version. **Absent means the file
  predates versioning; parse it exactly like version 1.** Raw meetings,
  dictation and writing day files are version 1. Since 2026-11-27 the meeting
  restyle writes **version 2**: compact frontmatter (pipeline keys move to a
  hidden sidecar), merged turns as `[MM:SS] **Speaker:** text`, and an
  optional `## Summary`. Files already on disk stay version 1 until they are
  restyled again (a re-transcribe does that), so readers must handle both.
  Bump the number only for a breaking change; additive changes stay within
  the current version.
- `transcript_style: raw | styled` — which meeting body grammar the file
  currently carries (meetings only; see the lifecycle below). Absent means the
  file predates the key: sniff the body heading instead (`## Full Transcript`
  → raw, `## Transcript` → styled).

Dictation and writing day files carry `format_version` but no
`transcript_style` (they have a single body grammar).

## Stability rules

1. **Flat `key: value` frontmatter only.** The app's own scanner
   (`TranscriptFrontmatter.values(from:)`) skips indented lines, so nested YAML
   is invisible to it (see the Issue #500 comment in
   `TranscriptFormatter.swift`). New keys must be top-level. The only nested
   blocks are the pre-existing `gap_events`, `speakers`, `tags`, `aliases`, and
   `cssclasses`; parsers that need them re-read the raw frontmatter lines.
2. **Parsers must ignore unknown keys.** Older files may contain summary
   metadata from features that no longer write new fields. Future app versions
   may add more keys too.
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
2. **Restyle + rename (async)** — `MeetingTranscriptStyler.restyleTranscript`
   rewrites the body into the version 2 styled form, rewrites the frontmatter
   as described under "Version 2 frontmatter" (`title:` first, then
   `format_version: 2` and `transcript_style: styled`, never duplicated),
   moves pipeline keys to `.meta/<capture_id>.json`, and renames the file to
   `<YYYY-MM-dd> <title>.md` (collision suffix ` <n>`). Retained audio
   directories follow the rename (`MeetingArtifactRenamer`). Unknown
   frontmatter keys, a `## Summary` section and unknown trailing Markdown
   sections from older files are preserved. Restyling a version 2 file again
   changes nothing.

The Home title editor may later rewrite `title:` and rename the file again. It
also preserves unknown frontmatter and trailing sections. With **Titles and
summaries** on, the on-device label then adds `ai_*` keys and the body's
`## Summary` (see below).

New meetings no longer get the heuristic `auto_summary_*` keys. Older files
keep them, and readers still parse them.

## Meeting frontmatter keys

Written at initial save (all flat unless noted). A version 2 restyle keeps
only some of them in the Markdown; see "Version 2 frontmatter" below.

| Key | Example | Notes |
|-----|---------|-------|
| `capture_id` | `"5E9A…"` | UUID, quoted. Same value as `transcript_id`. The stable identity: readers fall back to it when `transcript_id` is absent (version 2 drops `transcript_id`). |
| `capture_type` | `meeting` | Discriminator; dictation day files use `dictation_day`, writing day files `writing_day`. |
| `format_version` | `1` | See Versioning. Absent = pre-versioning. |
| `transcript_style` | `raw` / `styled` | See Versioning and lifecycle. |
| `transcript_id` | `"5E9A…"` | UUID, quoted. |
| `date` | `2026-04-07` | `yyyy-MM-dd`, local time. |
| `time` | `09:14:00` | `HH:mm:ss`, local time. |
| `duration` | `"12:30"` | `m:ss` (minutes may exceed 59), quoted. |
| `processing_time` | `"41.3s"` | Seconds with one decimal + `s`, quoted. |
| `transcription_engine` | `parakeet_local` | Engine identifier. |
| `transcription_language` | `"auto"` / `"fi"` | Optional immutable requested language for this job. Absent legacy files retry as Automatic. |
| `transcription_language_resolution` | `detected` | Optional `explicit`, `detected`, `automaticUncertain`, `multilingual`, or `unsupported`. Detection is bounded evidence, not proof of a recording's only language. |
| `transcription_language_resolved` | `"fi"` | Optional language passed to the recognizer; absent when Automatic remains uncertain, multilingual, or unsupported by that engine. Historical exception: transcripts saved by retired Apple Speech (`apple_speech_local`) could not detect languages, so their Automatic runs used the Mac's language and wrote `automaticUncertain` together with that code. |
| `diarization_engine` | `nemotron_offline` | The diarizer that actually ran for this meeting. See below. |
| `voiceprint_model` | `"redimnet2-b4"` | Optional, quoted. The model that embedded each speaker's voiceprint. Absent in files saved before 2026-09-29 and when no diarizer ran. |
| `sources` | `[mic, system_audio]` | Inline list of captured channels. |
| `mic_utterances` | `12` | |
| `system_utterances` | `34` | |
| `mic_speakers` | `1` | |
| `system_speakers` | `2` | |
| `total_word_count` | `1204` | |
| `title` | `"Weekly Sync"` | Optional at save (imported audio, detected meetings); the restyle always writes one. |
| `imported_at` | `2026-09-24T19:34:04Z` | Imported files only: when the file was transcribed, as a UTC ISO 8601 instant. `date`/`time` stay the original recording time; the app lists an import by this key so it shows up where it was just made. Kept when the same file is re-transcribed. |
| `starred` | `true` | Optional. Set from a meeting's ⋯ menu or its opened card on Home; absent means not starred. Automatic meeting-audio deletion skips starred meetings. Kept when the meeting is re-transcribed. |

The `transcription_engine` value identifies the concrete model used, not a
later picker selection. Current identifiers are additive within format version 1:

| Identifier | Model | Raw transcript footer name |
| --- | --- | --- |
| `parakeet_local` | Parakeet TDT v3 (default) | `Parakeet` (preserved for compatibility) |
| `parakeet_ultra_local` | Parakeet Ultra (experimental, installed by `scripts/models/parakeet-ultra`) | `Parakeet Ultra` |
| `whisper_large_v3_turbo_local` | Whisper Large v3 Turbo | `Whisper Large V3 Turbo` |
| `parakeet_v2_local` | Parakeet TDT v2 (retired, read-only legacy) | `Parakeet V2` |
| `whisper_large_v3_local` | Whisper Large v3 (retired, read-only legacy) | `Whisper Large V3` |
| `apple_speech_local` | Apple Speech (retired, read-only legacy) | `Apple Speech` |

Readers should preserve unknown identifiers rather than assuming every local
capture uses Parakeet v3.

`diarization_engine` records the backend that diarized the meeting, read when
the diarizer ran, not the one the app asked for. Values are additive within
format version 1:

| Value | Meaning |
| --- | --- |
| `nemotron_offline` | NVIDIA Nemotron 3 Diarization (the app default since 2026-09-28). |
| `pyannote_offline` | pyannote community-1. Also what a Nemotron load failure falls back to. |
| `none` | No diarizer ran (for example a mic-only meeting without local speaker split). |

Files saved before 2026-09-29 always say `pyannote_offline`, even when Nemotron
diarized them, so treat that value in older files as "unknown backend".
`voiceprint_model` uses the embedder's identifier: `redimnet2-b4` (default),
`eres2net`, `wespeaker` (pyannote's native offline WeSpeaker), or
`wespeaker-fluid-online`. Missing means unknown; readers keep unknown values.
The raw footer names the diarizer too (`Parakeet + Nemotron (local)`, or just
`Parakeet (local)` when none ran); like the STT name there, it's descriptive. The footer is descriptive; use the frontmatter key
for model identity.

The selected language survives saved-audio retranscription and failed-job retry.
Automatic detection is resolved once per pipeline invocation from at most three
non-overlapping, speech-candidate windows of up to ten seconds spread across
the recording. Its result is shared by both channels and all speaker segments.
A retry can resolve Automatic again using its current engine; the previous
resolved language is descriptive metadata, not a permanent forced override.

Recording-health keys (optional, only when health info exists):

| Key | Example | Notes |
|-----|---------|-------|
| `capture_quality` | `excellent` | `excellent` / `good` / `fair` / `degraded`. |
| `audio_gaps` | `0` | |
| `device_switches` | `0` | |
| `system_audio_signal_verified` | `true` | Optional flat boolean: finite nonzero system PCM was observed during this live recording. `false` means unverified, not permission denied; ordinary silence after observed signal remains `true`. Omitted for imports and legacy captures, for "Record Just My Mic", and when no system audio was heard but macOS confirmed System Audio Recording access (a quiet Mac). Independent of `capture_quality`. |
| `gap_events` | — | **Nested** list of quoted strings; invisible to flat parsers. Omitted when empty. |
| `audio_health` | `mic_attenuated_by_call_app` | Flat; omitted for healthy meetings. |
| `mic_boost_prompt` | `"declined"` | Flat; only alongside `audio_health`. |
| `microphone_audio_unusable` | `true` | Flat; microphone audio was missing or unusable and excluded from a system-audio-only partial transcript. |
| `system_audio_missing` | `true` | Flat; no system track survived to save, so the transcript holds only the mic side and `capture_quality` is `degraded`. |
| `mic_only` | `true` | Flat; the user picked "Record Just My Mic", so only their side was recorded on purpose and the other side of any call is not in the transcript. Not a capture problem: the grade is unaffected and `system_audio_missing` is never set with it, and `sources` lists only the mic. A retry or Home re-transcribe keeps the key but writes no `capture_quality`/`audio_gaps`/`device_switches`, since nothing measured the capture. Omitted for two-sided meetings. |

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
  - id: "1"
    channel: system
    db_id: "2222…"
    name: "Speaker 1"
    confidence: unknown
    source: db_pending
    call_app_name: "Maya Lindqvist"   # optional; see below
    call_app_agreement: no_voiceprint_guess  # agrees | conflicts | no_voiceprint_guess
    call_app_seconds: 42.5
    call_app_share: 0.92
    call_app_coverage: 0.61
```

The `call_app_*` keys are optional context on a `channel: system` row. They
never change `name`, `confidence`, `source` or the body labels: a speaker's
name comes only from the voiceprint or from the person naming the voice.
While a meeting records, Transcripted reads who the call app (Zoom, Meet,
Teams, Slack huddles) shows as the one talking; after the meeting, timed
active-speaker evidence that overlaps a voice's speech is saved next to it:

- `call_app_name`: the name the call app showed while this voice talked.
- `call_app_agreement`: `agrees` when it's the same person as the
  voiceprint's name or suggestion (compared trimmed, case-insensitively,
  ignoring a ` (likely)` hedge), `conflicts` when the voiceprint says
  someone else (both are kept; `name` stays the voiceprint's), and
  `no_voiceprint_guess` when the voiceprint had no name for the voice.
- `call_app_seconds`: seconds of this voice's speech while the call app
  showed only that name speaking. `call_app_share`: that name's share of all
  single-speaker evidence overlapping the voice (0–1). `call_app_coverage`:
  how much of the voice's speech any single-speaker evidence covered (0–1).
- `call_app_withheld`: written instead of a name when the call app showed
  something but not enough to point at one person (`too_little_evidence`,
  `names_disagree`, `low_coverage`).

Treat them as a second opinion. Two voices can carry the same
`call_app_name` (the diarizer may split one person). The keys stay when the
voice is later named or the review is put off. A roster alone never gives a
name: visible tiles do not prove a complete roster or reliable self
identification.

`name_source` (legacy, read-only): files saved before 2026-11-04 may have
`name_source: call_app` on a row whose `name` (and body labels) came from
the call app while the voice waited for review (`source: db_pending`). Treat
that name as a hint, not an identity. Naming or confirming the voice, or
renaming or merging that person in Settings › Speakers, rewrites the row
with the real name and drops `name_source`. New files never write it.

Obsidian metadata (legacy app format; optional Core output): older transcripts
written while the retired `enableObsidianFormat` flag existed may carry nested `tags:`,
`aliases:`, and `cssclasses:` blocks, with named body speakers wrapped in
`[[wiki links]]`. The current app and CLI write plain output; the app no longer
reads that preference. Core's public `TranscriptFormatOptions` still allows
an embedder to explicitly set `includeObsidianMetadata: true` when formatting
or saving new transcripts. Its default is false. Parsers and speaker-rename
rewrites still tolerate and preserve the legacy form.

Older files may contain `auto_summary_*`, `local_summary_*`, or other summary
frontmatter and trailing sections. These are legacy data: current meeting
writers leave them untouched.

On-device title and summary (optional; only with Settings › Meetings ›
**Titles and summaries** on). After a meeting is transcribed, imported or
transcribed again, a small model on the Mac (Gemma 4 E2B instruct) reads the
transcript and the app appends these flat keys. It never changes `title:` or
the filename. The body gets two readable mirrors: the summary as a
`## Summary` section right before `## Transcript` (inserted or replaced; a
label without a summary removes the section only when its text is the old
`ai_summary`), and the `# ` heading follows `ai_title` while it stands in for
`title:` (and shows `title:` again when it no longer does):

| Key | Example | Notes |
|-----|---------|-------|
| `ai_title` | `"Billing provider switch"` | 6 words at most (20 characters for Chinese or Japanese). Only written on positive evidence that the app made `title:`: the restyle generated it in that pass, an import's pipeline save named the file (and the file has `imported_at`), `ai_title_replaces` already stood in for it, or the file alone shows the app's rule title: `Meeting with <names>` only when those are exactly the names the rule takes from the file's own speakers today, `Meeting at <time>` (any clock format) and `Quick notes` by shape. A title a live recording brought with it (a calendar event's or a requested one), a name the person gave the meeting, a title an earlier label kept, or a title nothing vouches for is kept, and only the line and summary are written. Nothing in the file marks a calendar title, so a meeting labeled later from the file alone (the feature was off when it saved) can still have a calendar title replaced when it reads exactly like a rule title: `Meeting with Dana` for a meeting whose one named remote speaker is Dana, `Meeting at 3:00 PM`, or `Quick notes`. |
| `ai_title_replaces` | `"Meeting with Priya"` | Written with `ai_title`: the exact `title:` it stands in for. When `title:` is later anything else, `title:` shows again. |
| `ai_summary_line` | `"The team switches providers next month."` | One or two sentences, about 45 words at most (90 characters unspaced). Optional. |
| `ai_summary` | `"…"` | Two or three sentences. Optional. |
| `ai_summary_model` | `"gemma-4-e2b-it-q4km"` | Which model wrote the keys. |
| `ai_summary_version` | `"1"` | A file already at the current version is skipped; a newer version replaces every `ai_*` key. |
| `ai_summary_generated_at` | `"2026-11-18T18:44:53Z"` | When the keys were written, UTC ISO 8601. |
| `ai_summary_speakers` | `"3f9a1c0b7d2e"` | The first 12 hex digits of a SHA-256 over the sorted speaker names the model read (`You` and `Unknown speaker` included). Holds no names. When the file's names no longer give the same hash (a speaker review answered, a rename or merge), the meeting is labeled once more; the model's own earlier `ai_title` may be replaced then, a title the person set may not. A change made while the app runs is picked up right away; the check at launch reads a labeled file in full only when it changed in the last 30 days. Not checked for `too_short`. |
| `ai_summary_status` | `too_short` | Only when this version had nothing to write: `too_short` (under about 40 words) or `no_usable_reply`, written with `ai_summary_model`, `ai_summary_version`, `ai_summary_speakers` and `ai_summary_generated_at` and no title, line or summary. It stops the meeting being read again until the version changes (or, for `no_usable_reply`, the speaker names do). A meeting that already has a title, line or summary at this version keeps them when a relabel comes back with nothing usable: only `ai_summary_speakers` is updated, and no status is written. A failed request or a helper that couldn't start records nothing and retries on the next launch. |
| `title_set_by_user` | `true` | The person chose `title:`. Written only by Home's Rename; never inferred. Not an `ai_*` key and independent of the feature: "Transcribe again" carries it into the fresh file in the same write that replaces it, like `starred`. |

Which title to show: `title:` when `title_set_by_user: true` or when it differs
from `ai_title_replaces`; otherwise `ai_title` when present; else `title:`.
Agents reading the files should follow the same rule. Sentences that hand the
recorder a task ("You will…", "Your next step…") are dropped before saving,
and a transcript under about 40 words gets only `ai_summary_status:
too_short` with the model, version, speakers and time keys (no title, line or
summary). A new meeting is labeled only after its speaker review is answered.
"Transcribe again" drops the `ai_*` keys (it keeps `title_set_by_user` and
`starred`) and the job runs again. Transcript text, titles and summaries never
leave the Mac.

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
[<MM:SS or HH:MM:SS>] [<Mic|System>/<speaker label>] <text>
```

Elapsed timestamps use `MM:SS` below one hour and `HH:MM:SS` from one hour
onward, truncating fractional seconds: `59:59`, `01:00:00`, `100:00:00`.
Hours have at least two digits and do not wrap at 24. Readers also accept older
total-minute timestamps such as `60:00` and `6000:00`, and unpadded hours such
as `1:00:00`. Speaker renaming preserves the original timestamp spelling.
These already-supported clock forms remain within format version 1; duration
metadata and speaking-time summaries keep their existing formats.

Mic labels default to `You` (or a named speaker with local-speaker review);
system labels default to `Speaker <n>` until named. In legacy
Obsidian-formatted files, named labels are wiki-linked: `[System/[[Sarah]]]`
(read-side tolerance only; new files never write this). Multi-speaker mic
captures add a `### Microphone (People in the Room)` heading and a
`#### Local Speaker Breakdown` section. When mic capture is disabled the
microphone section is omitted and `sources` reflects it.

## Meeting body: styled form (`transcript_style: styled`)

Produced by the async restyle. Filename `<YYYY-MM-dd> <title>.md`.

### Version 2 (current)

```markdown
---
title: "Meeting with Sarah"
capture_id: "5E9A…"
capture_type: meeting
format_version: 2
transcript_style: styled
recorded_at: 2026-04-07T09:14:00-05:00
date: 2026-04-07
time: 09:14:00
duration: "12:30"
total_word_count: 42
system_speakers: 1
speakers:
  - id: "0"
    channel: system
    …
---

# Meeting with Sarah

Recorded Apr 7, 2026 at 9:14 AM  •  12 min, 30 sec  •  42 words  •  2 turns

## Summary

Sarah agreed to start the pilot next week.

## Transcript

[00:00] **You:** Thanks for making time today.

[00:04] **Sarah:** Happy to help. Let's get started.
```

Transcript rows: one line per turn, blank-line separated:

```
[<MM:SS or HH:MM:SS>] **<label>:** <text>
```

- **The label is the display name alone.** Its channel comes from the
  frontmatter `speakers:` rows: the one `channel:` (`mic` / `system`; a row
  without one is `system`) that rows with that name use. A name with no row,
  or rows on both channels, is the mic when it is `You` and the call audio
  otherwise. Whenever that rule would give a row the wrong channel (the same
  name on both channels, a mic voice with no row), the label spells the
  channel out: `**Mic/Dana:**` / `**System/Dana:**`. Legacy wiki-link names
  stay as written (`**[[Alex]]:**`).
- **Turns are merged.** Consecutive turns by the same speaker become one row
  while the next turn starts at most 8 s after the previous one, the row spans
  at most 25 s (start to start), and its text stays at most 320 characters.
  The row keeps the first turn's timestamp. Timestamps use the same
  elapsed-time and legacy-read rules as raw transcripts.
- The detail line joins parts with `  •  `: `Recorded <medium date, short
  time>`, humanized duration, word count and the number of rows, when nonzero.
- `## Summary` (optional) sits between the detail line and `## Transcript`.
  It is the on-device `ai_summary`; readers of the transcript skip it.
- An empty transcript renders as `_No transcript captured._`.
- Unknown trailing Markdown sections, including old generated summary blocks,
  are preserved after the transcript.
- The restyle fails closed: if the body carries transcript text the entry
  parser cannot understand, the file is left byte-for-byte untouched (still
  raw-form, still `transcript_style: raw` if it had it).

### Version 2 frontmatter

The restyle writes, in this order: `title`, `capture_id`, `capture_type`,
`format_version: 2`, `transcript_style: styled`, `recorded_at` (the
recording start, ISO 8601 with the Mac's UTC offset), `date`, `time`,
`duration`, `total_word_count`. `date` and `time` stay so every existing
reader keeps working. Then, in their original order, every other key except
the ones moved out:

| Kept only when | Keys |
|---|---|
| Set | `starred`, `title_set_by_user`, `imported_at`, `mic_only`, `audio_health`, `mic_boost_prompt`, `system_audio_missing`, `microphone_audio_unusable`, `ai_*`, legacy `auto_summary_*` / `local_summary_*`, unknown keys |
| Abnormal | `capture_quality` (`fair` / `degraded`), `audio_gaps` (> 0), `device_switches` (> 0), `system_audio_signal_verified` (`false`) |
| Informative | `system_speakers` (> 0, read by speaker naming), `transcription_language` (not `auto`), `transcription_language_resolution` / `_resolved` (an explicit selection, or Automatic that `detected` a language) |
| Non-empty | `speakers:`; `gap_events:` minus sub-second reconnect noise (`audio_gaps` drops the same events) |

Always moved out: `processing_time`, `transcription_engine`,
`diarization_engine`, `voiceprint_model`, `mic_utterances`,
`system_utterances`, `mic_speakers`, `sources` and the duplicate
`transcript_id`.

### Pipeline sidecar: `.meta/<capture_id>.json`

Everything the version 2 restyle removed from the frontmatter is written to
`<meetings folder>/.meta/<capture_id>.json` (hidden folder `0700`, file `0600`,
atomic write):

```json
{
  "capture_id" : "5E9A…",
  "frontmatter" : {
    "capture_quality" : "good",
    "gap_events" : ["System audio reconnect: 0.4s"],
    "processing_time" : "41.3s",
    "sources" : ["mic", "system_audio"],
    "transcription_engine" : "parakeet_local"
  },
  "schema_version" : 1
}
```

Values are the original frontmatter strings (`gap_events` and `sources` as
string lists). It holds no transcript text, titles or names. It is keyed by
`capture_id`, so title renames never orphan it; a later restyle merges into
it, and deleting the meeting from Home moves it to the Trash with the
transcript (Undo restores it). Writing it is best effort: a failure never fails
the transcript save. CaptureKit reads it with `CaptureMeetingMetadataSidecar`;
a key in the frontmatter wins over the sidecar. Known gap: moving the capture
library in Settings copies Markdown and audio but not `.meta/` yet, so moved
meetings lose this diagnostic copy (the Markdown is complete without it).

### Version 1 (legacy, read-only)

Files restyled before version 2 look like this; readers and speaker renames
still handle them:

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

Entries are blank-line-separated blocks: a header line
`**<MM:SS or HH:MM:SS>**  [<Mic|System>/<label>]` (two spaces after the bold
timestamp) followed by the utterance text on the next line(s). Version 1
never merged turns.

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
- Two edits rewrite a day file in place: Delete removes one section, and
  Transcribe again replaces one section's heading title, `Words:`,
  `Characters:`, and body. `Entry ID:`, `Captured:`, the source app,
  `Delivery:`, and `Audio:` never change, so readers can key on the Entry ID.
- Section heading: `## <h:mm a> - <title>` where the title is the first ~7
  words of the text (or `Dictation <MMM d> at <h:mm a>` for very short text).
- Metadata lines, in order: `Entry ID:` (backticked), `Captured:` (ISO 8601
  with fractional seconds), `Source app:`, optional `Bundle ID:` (backticked,
  omitted when unknown), `Delivery:`, `Words:`, `Characters:`, optional
  `Audio:` (backticked). Older files may carry `Timestamp:` instead of
  `Captured:`.
- `Audio:` is present only when the take's audio was kept (Settings → Storage →
  Keep dictation audio). Its value is a path relative to the dictations folder,
  `audio/<session-uuid>.m4a`. The file may be the `.wav` sibling while
  compression is pending, and it may be gone entirely once it ages out of the
  keep window or the user switched to Don't keep: readers must treat a missing
  file as normal and never resolve the path outside `dictations/audio/`.
  Additive within `format_version: 1`; older readers skip the line.
- `Delivery` values: `pasted`, `copied`, `failed`, `saved_without_paste`.
- The dictated text follows after a blank line and runs to the next `## `
  heading or end of file.

## Writing day files

The main Transcripted app (never the keyboard) appends settled typed text into
one file per local day:
`<capture-library>/writing/Writing_<YYYY-MM-dd>.md`, in a `writing/` folder
beside `meetings/` and `dictations/`. The shape extends dictation day files and
follows the same stability rules.

```markdown
---
title: "Writing for September 25, 2026"
date: 2026-09-25
capture_type: writing_day
format_version: 1
---

# Writing for September 25, 2026

## 10:42 AM - Pushing the launch to Thursday so QA

Entry ID: `writing-20260925-104211-387-4f2a9c1e`
Captured: 2026-09-25T15:42:11.387Z
Source app: Slack
Bundle ID: `com.tinyspeck.slackmacgap`
Words: 12
Characters: 65
Accepted words: 3

Pushing the launch to Thursday so QA can finish the AirPods pass.

## 11:05 AM - …
```

Details:

- The day header is written once, when the file is created; later saves append
  sections only, same as dictations. Header keys are flat.
- Section heading: `## <h:mm a> - <title>` where the title is the first ~7
  words of the text (or `Writing <MMM d> at <h:mm a>` for very short text).
- Metadata lines, in order:
  - `Entry ID:` (backticked, `writing-<yyyyMMdd>-<HHmmss>-<SSS>-<8 hex>`)
  - `Captured:` (ISO 8601 UTC with milliseconds; the entry's first keystroke)
  - `Source app:` (display name)
  - optional `Bundle ID:` (backticked, omitted when unknown)
  - `Words:`
  - `Characters:`
  - `Accepted words:` (words that came from accepted suggestions)
- There is no `Delivery:` line; nothing is pasted.
- The text follows after one blank line and runs to the next `## ` heading or
  end of file. It is the settled text: characters removed with plain Backspace
  inside the keyboard's own buffer aren't saved. Option- or Cmd-Backspace
  breaks the segment instead, so the word it deleted stays in the saved text.
  Pastes, mouse edits, and the host app's autocorrect aren't seen (a known v1
  limit).
- A text line that starts with `## ` is written as `\## ` so it can't open a
  new section. Readers strip that one backslash
  (`CaptureMarkdownParser.unescapeWritingBody`). So a line that literally
  starts with `\## ` doesn't round-trip: it reads back as `## `. Whole-day
  reads (MCP `read_writing` without `entry_id` when it returns the file
  unpaged, and `read-writing` without `--entry-id`) return the raw Markdown
  with the escape still in it. Entry reads, pages, and parsed entries are
  unescaped.
- An entry is one app's continuous writing. A new entry starts on an app
  switch, after 2 minutes idle, or on a caret jump or segment break the
  keyboard reports. A caret the host reports late, or never moves (some
  terminals report it at 0), isn't a jump: a word typed in one go is saved
  as that word. A scrap under 3 words (a quick "sounds good") doesn't end
  at a segment break when the same app's next segment starts within a
  minute: it folds into that entry, each segment on its own line. Box
  fragments (one character, or up to 5 characters with no letters, like a
  card or code box) don't count toward the 3 words, so a card or code typed
  over several boxes stays one entry. Entries under 2 characters after
  trimming aren't saved.
- Nothing is written for secure input, excluded apps (password managers
  always), apps outside the user's scope, or while Save my writing is off.
- Secrets are scrubbed before an entry is written: a password typed at a
  terminal prompt (`sudo`, `ssh`, `passwd`, `read -s`, …), a line that is only
  a password-shaped token, one-time codes and PINs, card numbers (also split
  across boxes, with the expiry and CVV after them), values after labels like
  `password:`, `API_KEY=`, `--token` or `Bearer`, credentials in URLs, and
  known token formats. Each becomes `⟨redacted:<kind>⟩`, where kind is
  `password`, `code`, `card`, `secret`, `api-key`, `jwt`, `pem`, `iban` or
  `ssn`. Emails and phone numbers are kept. An entry that was nothing but a
  secret is saved as just its token (a sudo password becomes a
  `⟨redacted:password⟩` section), so the command before it never runs into
  the line after it on disk. `Words:` and `Characters:` count the scrubbed
  text, and the heading title comes from it.
- Day files written before the scrubber (or under older rules) are
  rescrubbed once when Writing starts: changed sections get their title and
  counts redone (`Accepted words:` never more than `Words:`), sections that
  were only a secret keep their heading with just the `⟨redacted:…⟩` token as
  their text (so the command before them never runs into the line after, and
  a second pass changes nothing), and files with nothing to scrub aren't
  touched. A file that changes while it's being rescrubbed, or that Writing
  stopped before reaching, is left for the next launch. One that can't be
  read as a day file at all (a symlink, not UTF-8) is skipped and doesn't hold
  the version back. The rules version it ran with is
  remembered per Mac (`WritingDayFilesScrubbedRulesVersion`), so day files
  that arrive later from another Mac aren't rescrubbed until the next rules
  bump, and nothing runs while Writing is off.
- Files are created 0600 and the `writing/` folder 0700.

## Parser guidance

- Detect meetings via `capture_type: meeting`; fall back to the transcript
  headings for pre-`capture_type` files. Detect dictation day files via
  `capture_type: dictation_day` or the `Dictations_` filename prefix.
- Detect writing day files via `capture_type: writing_day` or the `Writing_`
  filename prefix. Check for them before falling back to "any other Markdown
  file with frontmatter is a meeting", or they get read as meetings.
- Choose the meeting body grammar by `transcript_style` when present, else by
  heading: `## Full Transcript` (raw) vs `## Transcript` (styled). Robust
  parsers accept both grammars in either file (see
  `Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureMarkdownParser.swift`).
- Treat every key as optional. Missing `format_version` = version 1 semantics.
- `Tools/TranscriptedCaptureKit` exposes `format_version` / `transcript_style`
  as optional `formatVersion` / `transcriptStyle` fields on
  `ParsedMeetingCapture` and `formatVersion` on `ParsedDictationDayCapture`
  and `ParsedWritingDayCapture` (`CaptureMarkdownParser.parseWritingDay`).
  A dictation entry's `Audio:` line is `audioRelativePath` on
  `ParsedDictationDayCapture.Entry` (nil when absent).
  Detect writing day files via `capture_type: writing_day` or the `Writing_`
  prefix, and check for them before the "frontmatter means meeting" fallback.

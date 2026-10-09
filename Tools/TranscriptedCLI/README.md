# Transcripted CLI

## Import a recording as a meeting

`import-audio` is the headless equivalent of choosing an audio file: local
transcription, speaker separation, timestamps, and Transcripted-compatible
Markdown. It never captures the microphone, requests recording permissions,
plays audio, or deletes/moves the source file.

App builds include the full CLI on Apple Silicon/macOS 26+. Invoke the helper
directly; no Swift installation, repository checkout, or PATH changes are needed:

```sh
CLI="/Applications/Transcripted.app/Contents/Helpers/transcripted-cli"
"$CLI" build-info
"$CLI" import-audio "/path/to/voice memo.m4a" --no-download
```

Replace the app path if you keep it elsewhere. The full helper reports
`{"diarization":true,"meetingImport":true,"mode":"meeting","transcription":true}`.
`build-info` reads only compiled capabilities: it does not load models, access
recordings, or make network requests. For `transcribe` and `import-audio`, model
resolution checks explicit model directories first, then the containing app's
bundled models, standard installed-app locations, and the shared FluidAudio
cache. Moving the whole app does not require reinstalling models. Thin local
builds may still need the cache or explicit model paths.

To build from source instead, use an Apple Silicon Mac with Xcode and macOS 26+
(the shared meeting pipeline's minimum):

```sh
bash build-deps.sh
TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 swift build --package-path Tools/TranscriptedCLI
CLI="$PWD/Tools/TranscriptedCLI/.build/debug/transcripted-cli"
"$CLI" import-audio "/path/to/voice memo.m4a" --no-download
```

The basic `transcribe`, `diarize`, and retrieval commands remain available;
their existing macOS 14 build modes and output shapes are unchanged. For raw
text/JSON/SRT without a saved meeting, use `transcribe` instead.

Explicit audio build modes fail with a dependency error if the prebuilt bundle
is missing or incomplete; they never silently build retrieval-only instead.

```sh
# Save in the app-selected meeting library, retaining a playback WAV.
"$CLI" import-audio memo.m4a --json

# Save Markdown only in this exact directory (no extra meetings/ subfolder).
"$CLI" import-audio memo.m4a --output-dir "$PWD/notes" --no-retain-audio --json

# Name the note just "memo.md" (handy for Obsidian, which shows the file name
# as the title). If memo.md already exists, the capture ID is added instead.
"$CLI" import-audio memo.m4a --output-dir "$PWD/notes" --plain-filename

# Number speakers without consulting saved voice profiles.
"$CLI" import-audio interview.mp4 --no-speaker-identification --title "Interview"

# Fully local models: incomplete or missing bundles fail without downloading.
"$CLI" import-audio memo.wav --no-download \
  --models-dir /path/to/parakeet-tdt-0.6b-v3 \
  --diarization-models-dir /path/to/speaker-diarization
```

### What gets saved

- Default destination follows the shared capture-library resolver: directory
  environment overrides, then the app's selected library, then the default
  `~/Library/Application Support/Transcripted/captures/meetings`. Legacy folders
  are read fallbacks, not new-import destinations. `--output-dir` wins over all
  defaults. `TRANSCRIPTED_MEETINGS_DIR` is the simplest automation override;
  `TRANSCRIPTED_DATA_DIR` keeps its existing shared-directory semantics.
- One Markdown meeting, with a unique capture UUID in its filename, canonical
  frontmatter, numbered/recognized speakers, and timestamped utterances.
  `--plain-filename` names it just `<title>.md` instead, and only adds the
  capture UUID when that name is already taken.
- By default, a separate 16 kHz mono Float32 playback WAV under
  `audio/<transcript-stem>_audio/system_audio.wav`. It is normalized audio, not a
  byte-identical original or a lossless archive of every original channel.
- `--no-retain-audio` skips that durable duplicate. Temporary decode/model-job
  files are cleaned on normal completion/failure/cooperative cancellation. The
  input always remains untouched, and there is no hidden reference to it for
  playback. Power loss/SIGKILL may leave private temporary files or an orphaned
  uncommitted audio directory; no existing captures are deleted to recover them.
  An absolute `TMPDIR` can isolate temporary jobs; its directory must already exist.
- No AI summary/restyling, new speaker learning, app stats update, or background
  watcher. The app/context reader can read the saved meeting.

### Network output and an uncertain save

Meeting imports publish the completed Markdown with a hard link so a competing
writer cannot be overwritten and readers cannot see an incomplete transcript.
Some mounted filesystems, including some SMB configurations, do not support this
operation even when ordinary file creation works. `--plain-filename` changes
collision naming; it does not change filesystem support. The CLI does not fall
back to an overwriting rename or an incomplete copy under the final filename.

For an unsupported destination, export to an explicitly **local** folder first:

```sh
"$CLI" import-audio recording.m4a --output-dir /path/to/local/export \
  --no-retain-audio --json
```

Then copy the finished Markdown to the desired destination using a copy operation
that refuses to replace an existing entry. Keep the local file until the copied
bytes are verified. A manual copy can be visible before it finishes; this is an
export workaround, not the CLI's atomic-publication guarantee. The original
recording is untouched. `--no-retain-audio` means the copied note has no retained
playback audio and no hidden playback reference to the original recording.

An I/O or connection error during publication may mean the final link was created
but its reply was lost. The CLI reports that it **could not confirm publication**,
returns an error instead of a success receipt, and does not try a second filename.
It preserves the hidden `.transcripted-import-*.tmp` Markdown and any owned
`audio/<transcript-stem>_audio/` archive in the output directory. Check the output
before retrying or removing these files: a final Markdown file may already refer
to that audio. The staged Markdown's `capture_id` identifies the import. A proven
collision or unsupported-operation failure still cleans up its own uncommitted
files; it never removes an existing final transcript.

This behavior does not establish compatibility with any particular NAS or SMB
server. Direct publication still requires filesystem support and validation on a
scratch share.

The command uses Parakeet v3's multilingual automatic transcription, not the
app's selected Whisper model or explicit language picker. It does not claim a
detected language code. Files need at least two seconds of decodable audio and
actual speech. AVFoundation-supported audio and audio-bearing MP4/MOV work;
unsupported WebM/MKV need conversion. Whole-file processing uses memory
proportional to duration; split very long recordings if memory is constrained.

### Speakers and safety

Recognition reads a consistent SQLite snapshot, including committed WAL data.
It never migrates, repairs, or learns into the app's live speaker database.
Only names passing the same confidence, ambiguity, confirmation-history, and
profile-health gates as the app are applied automatically. Uncertain speakers
stay numbered. Matching quality still depends on voices and audio quality;
numbered speakers do not mean the import failed.

**Which voiceprints and which database.** Each voiceprint model keeps its own
people, in `~/Library/Application Support/Transcripted/state/`:

| Model | Database | Notes |
|---|---|---|
| ReDimNet2 | `speakers_redimnet2-b4.sqlite` | The app's default since 1.1.67. Your saved people were carried over from `speakers.sqlite` the first time the app ran it. |
| WeSpeaker | `speakers.sqlite` | The older model. The app no longer writes this file once it's on ReDimNet2. |
| ERes2Net | `speakers_eres2net.sqlite` | Older opt-in. |

`--speaker-embedder app` (the default) picks the same model and database the app
uses: the app's setting or `TRANSCRIPTED_SPEAKER_EMBEDDER`, ReDimNet2 when
nothing is set, and WeSpeaker with `speakers.sqlite` when the chosen model isn't
installed or failed to load in this app build. The app and the CLI share this
rule, so they can't disagree. `redimnet2`, `wespeaker`, and `eres2net` pick a
model explicitly; an explicit model that isn't installed or can't load is an
error, never a silent fallback. The state folder follows the app's
`TRANSCRIPTED_CONTAINER_DIR` override; `TRANSCRIPTED_DATA_DIR` and
`TRANSCRIPTED_MEETINGS_DIR` only move where the Markdown goes. `--speaker-db`
overrides the read-only source database; pair it with the matching
`--speaker-embedder` (a database holding another model's voiceprints is an
error). Explicit databases must already carry the app's persisted model identity;
an unstamped custom copy is rejected rather than guessing from its vector size.
Open the canonical database in the updated app before copying it. Retrieval-only
builds parse the flags but cannot run imports or validate Core model choices.
An invalid explicit database fails; a missing or
unreadable default database warns and produces numbered speakers. Runs from a
script or launchd agent use the same people as long as they run as the same
macOS user; another account has its own (usually empty) speaker database.

In 1.1.70 and earlier the CLI always read WeSpeaker's `speakers.sqlite`, so people you
confirmed in the app after it moved to ReDimNet2 never got named by the CLI.

**The 5-meeting rule.** The CLI, like the app's "Transcribe a file", names
someone silently only after you've confirmed them in 5 distinct meetings, and
only on a strong, unambiguous match with that model's bars (ReDimNet2's are
stricter than WeSpeaker's). Until then the app asks "Is this NAME?" and the CLI
leaves them numbered. Importing the same audio file again doesn't count as a new
meeting. `--name-likely-speakers` opts in to naming someone who clears every bar
except the confirmation count (confirmed at least once), written as
`NAME (likely)`, with frontmatter `source: db_pending` so it never reads as a
confirmed name. It never counts as a confirmation; confirm people in the app.

**Why a speaker stayed numbered.** stderr names the voiceprint model and the
database it read, then gives one line per speaker that wasn't named, e.g.:

```text
Voiceprints: ReDimNet2 (the app's setting). Saved speakers: /Users/you/Library/Application Support/Transcripted/state/speakers_redimnet2-b4.sqlite
Speaker 1: matched Maya, but only 2 of 5 confirmed meetings
Speaker 2: didn't match anyone saved in this voiceprint database
```

Other reasons: no saved database for the model (or one that hasn't been carried
over yet: open the app once), a match below the model's similarity bar, another
saved person too close, recent corrections, or `--no-speaker-identification`.
stdout is unchanged: the path, or exactly one `--json` receipt.

Output is no-clobber, including concurrent imports. A selected symlink library
root is resolved once, but generated audio-directory symlinks are rejected.
Markdown is the final publication step after audio/file sync; successful return
means files exist, not a guarantee against every filesystem/power-loss failure.
The source can be a symlink to a regular file, but FIFOs/devices/directories are
rejected. Inputs should be finished syncing before invoking the command.

### Automation contract

Progress and diagnostics go to stderr. Default stdout is the committed Markdown
path plus a newline. `--json` prints exactly one JSON receipt:

```json
{"audioPath":"/notes/audio/unique_audio/system_audio.wav","captureID":"UUID","transcriptPath":"/notes/unique.md"}
```

`audioPath` is omitted for Markdown-only imports. Exit 0 means publication
succeeded; errors are nonzero. SIGINT/SIGTERM cancel cooperatively and return
130/143 before publication, though the current CoreML inference may finish first.
A signal arriving after publication does not delete the saved meeting. A broken
stdout pipe can occur after publication, so check the destination before retrying
an interrupted caller. Repeating an import intentionally creates a new capture;
the command does not deduplicate identical inputs.

An external folder watcher should wait until sync has finished and serialize
work. Keep a durable receipt before moving a successfully processed source. For
example, run this once per file (not concurrently for the same file):

```sh
input="/path/to/inbox/memo.m4a"
receipt="/path/to/receipts/memo.json"
processed="/path/to/processed/memo.m4a"
# Refuse to reuse a receipt or overwrite an already-processed input.
if [ ! -e "$receipt" ] && [ ! -e "$processed" ]; then
  pending=$(mktemp "${receipt}.pending.XXXXXX") || exit 1
  if "$CLI" import-audio "$input" --no-retain-audio --no-download --json > "$pending"; then
    # Keep the receipt even if moving the source later fails; do not re-import it.
    if ln "$pending" "$receipt"; then
      mv -n "$input" "$processed"
    fi
  fi
  rm -f "$pending"
fi
```

Create the receipt/processed parent directories first. This is a simple serialized
recipe, not a crash-proof queue: after a crash between publication and receipt
creation, reconcile the output before retrying. The CLI itself never moves input.

## Verification

```sh
# Retrieval-only and original basic-ASR modes remain buildable.
swift test --package-path Tools/TranscriptedCLI
TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1 swift test --package-path Tools/TranscriptedCLI
TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 swift test --package-path Tools/TranscriptedCLI
```

Opt-in real-model end-to-end test: builds/runs the actual CLI, seeds an isolated
eligible speaker profile, imports a speech file with/without retained audio,
parses the whole stdout receipt, reads it back using `read-meeting`, and checks
that source audio/database/WAL bytes and metadata are unchanged. It does not use
the real app library or people database. Without these variables it skips.

```sh
# File generation only: say -o does not play through speakers.
fixture=$(mktemp -d /tmp/transcripted-cli-fixture.XXXXXX)
say -v Samantha -r 150 -o "$fixture/voice.aiff" \
  "Today we are testing the local meeting transcription workflow. The original recording must stay safe. We will save a readable transcript, identify a familiar speaker, and check that the command reports success only after all files have been written. Tomorrow we will review the project schedule and confirm the next steps."
TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 \
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
TRANSCRIPTED_CLI_E2E_BINARY="$CLI" \
TRANSCRIPTED_CLI_E2E_AUDIO="$fixture/voice.aiff" \
TRANSCRIPTED_CLI_E2E_MODELS="/path/to/parakeet-tdt-0.6b-v3" \
TRANSCRIPTED_CLI_E2E_DIARIZATION="/path/to/speaker-diarization" \
TRANSCRIPTED_CLI_E2E_EXPECTED_WORDS="recording transcript schedule" \
TRANSCRIPTED_CLI_E2E_DENY_NETWORK=1 \
swift test --package-path Tools/TranscriptedCLI --filter ImportAudioExecutableE2ETests
```

Same-fixture recognition proves executable/model/database plumbing, not speaker
accuracy across different microphones, compression, accents, or new recordings.

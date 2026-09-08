# Same-build meeting audio crossover

This is a manual test with a willing receiving participant, outside a real
customer meeting. Nothing in this checklist starts audio automatically. Keep the
currently installed build for the first comparison; do not replace it or change
several audio settings at once. No harness is required for this first test.

## Record the baseline

Use built-in microphone and speakers first. Record locally:

- Transcripted version, build revision if available, and install channel
- full macOS and Zoom versions, timezone, and UTC test start time
- system input/output, Zoom microphone selection (explicit or Same as system), and speaker selection
- Transcripted requested processing mode and actual `voice_processing_active`
- macOS Mic Mode for each app; use `unknown` if unavailable
- Zoom noise-removal mode and automatic microphone-volume setting
- persistent recommended-input preference and whether dictation was already active
- start action (menu or detected prompt), model warmup, and whether recovery requires recording stop or app quit

Do not put customer speech, device identifiers, meeting links or private
screenshots in a public issue. Use a neutral spoken phrase such as:
“Recording test one two three. The next number is four.”

## First discriminator

1. With Transcripted idle, speak for 15–20 seconds. Separately observe Zoom's
   input meter, the receiving participant's heard speech, captions, and what
   the local tester hears from the remote participant.
2. Start Transcripted from the same action as the failing reproduction. Keep
   speaking normally. If either direction fails, stop promptly; otherwise
   observe for 20–30 seconds. Stop recording **without quitting the app** and
   check both directions again.
3. With recording stopped, change only Transcripted's microphone processing
   from Apple voice processing to Software autogain. Keep the same app build,
   route, Zoom settings and macOS Mic Modes. Repeat step 2. Confirm the new
   session actually reports `voice_processing_active=false`.
4. If the first mode failed and the second worked, one short return to the
   original mode can strengthen causality if the tester is comfortable doing
   so. Stop immediately on loss; do not require repetition of severe failures.
5. Record the final preference, and restore the tester's chosen setting while
   recording is stopped. Do not silently change persisted preferences.

If the original failing state did not use Apple voice processing, capture that
baseline first; do not turn processing on merely to fit this hypothesis.

| Observation | Idle before | Original mode recording | After stop | Software autogain recording | After stop |
| --- | --- | --- | --- | --- | --- |
| Receiving participant hears ordinary local speech | not_run | not_run | not_run | not_run | not_run |
| Local tester hears remote speech | not_run | not_run | not_run | not_run | not_run |
| Zoom input meter moves | not_run | not_run | not_run | not_run | not_run |
| Captions advance | not_run | not_run | not_run | not_run | not_run |
| Transcripted mic/system capture present | n/a | not_run | n/a | not_run | n/a |
| Actual voice processing active | n/a | unknown | n/a | unknown | n/a |
| Input/output scalar observations | unknown | unknown | unknown | unknown | unknown |

## Interpret the result

- Failure only with actual Apple voice processing active supports investigating
  that processing path; it is not by itself evidence of a specific OS defect.
- Failure in both modes weakens that explanation. Do not ship a processing
  guard as a verified repair without a discriminating result.
- Received speech intact but captions absent narrows the failure to captioning
  or speech classification for that run. Singing and repeated syllables are
  poor substitutes for ordinary speech in this test.
- A healthy saved Transcripted recording and stable sliders are insufficient
  for a pass. `cross_app_capture_status=unmeasured` is intentional: automatic
  diagnostics do not know what the receiving participant heard.
- A menu-started test and a prompted test are separate observations. Model
  warmup events do not imply an audio repair.

## Follow-up rows, one variable at a time

Only after the first comparison, vary the relevant item:

| Variable | Comparison | Question |
| --- | --- | --- |
| Zoom input | Same as system / explicit built-in | Does following the default route matter? |
| macOS Mic Mode | Observed mode / Standard for one app at a time | Does OS processing matter? |
| Zoom processing | Noise removal / Original sound | Does Zoom filtering matter? |
| Start action | Menu / prompt, with warm models | Is the initiation path relevant? |
| Dictation order | None / already active / started after meeting | Does capture ownership order matter? |
| Persistent input preference | Off / on | Does route maintenance matter? |
| Hardware | Built-in first, then USB, then Bluetooth | Does the problem follow a route? |

If these do not isolate the cause, plan an explicitly activated developer
harness comparing permission preflight, mic-only, system-audio-only and combined
capture. It must not start mic or ScreenCaptureKit capture by default. Do not
mistake that future harness or a synthetic buffer test for a two-client pass.

A candidate repair needs the same failing row repeated on its exact packaged
build, plus the existing meeting-audio matrix. A diagnostic-only change makes
no claim of repairing cross-app transmission.

# Dictation hardening — local trial

This change follows the September 7 dictation audit. It preserves final-only dictation, per-app Auto Enter, recovery audio, daily Markdown storage, decoder serialization, and existing device-settling safeguards.

## Workflow and ownership

- Coordinator: session completion ownership, asynchronous session-cap persistence, save timing, combined build and trial artifact.
- Audio review: shared dominant-channel microphone conversion and antialiased stopped-audio resampling.
- Speech review: caller-bounded readiness waits and cancelable queued inference.
- Support review: paste attempt ownership, bounded AX/snapshot work, duplicate-word cleanup and dictionary cache.
- Adversarial review: speech reviewer checks audio and controller changes; support reviewer checks readiness and ASR handoff. Final integration belongs to the coordinator. Other model/hardware lanes were skipped because they add no distinct proof to these source-level checks.

## Resulting behavior

A canceled dictation's writer may finish saving its text, but can only clean its own recovery checkpoint and cannot reset a newer dictation's overlay or session. Saves triggered by the session cap also run off the main actor. Persistence diagnostics carry captured session context; writer timestamps exclude Auto Enter and delayed UI publication.

Model readiness observes state changes with the existing timeout and caller cancellation. Waiting does not cancel shared model loading. Queued ASR requests can cancel before acquiring the serialized decoder; cancellation during handoff still releases its reservation correctly.

Microphone downmix selects the strongest channel rather than averaging potentially silent/opposite-polarity channels. Stopped-audio conversion uses antialiasing, preserves segment sample rates, drains converter output, and retains native buffers if conversion fails. It is a quality safeguard with a small added conversion cost, not an inference speed optimization.

Duplicate `I` runs are collapsed in one pass while preserving existing output and removal counts. Dictionary parsing is cached by the raw preference value as well as the existing compiled matcher cache. Pasteback keeps positive delivery checks and the existing Auto Enter/restoration delays; target lookup and clipboard snapshot timings are now separate.

## Measurement semantics

- `request_to_recording_ms` on `dictation_started` covers the controller request through successful start, across fast and waiting paths. Physical hotkey disambiguation before the controller is outside this span. The engine's existing `start_to_first_sample_ms` remains a separate audio-flow measurement.
- Local ASR diagnostics distinguish `queue_wait_ms` from `inference_ms`; existing end-to-end `decode_ms` remains unchanged.
- `save_ms` measures the actual writer call, including its storage lock wait, and `stop_to_save_ms` ends at writer completion.
- `save_publication_wait_ms` and `finalization_ms` explain delayed publication/Auto Enter separately.
- `paste_ax_capture_ms` and `paste_clipboard_snapshot_ms` split preparation work. No new raw text or audio is sent off-device.

## Trial acceptance

Use the exact local candidate for built-in mic, Bluetooth output with built-in input, and selected Bluetooth input. Try short and long dictations, route switching, cancel/restart, Auto Enter, an ordinary clipboard copy after dictation, and dictation while Zoom owns its mic. Check final inserted text and saved Markdown, not only a successful dispatch event. These physical-device checks remain a user trial; unit tests and synthetic benchmarks do not establish them.

The task's local validation report records exact build identity, gate results, measurements, and remaining trial checks. This document does not assert release readiness or publish a new version.

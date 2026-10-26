# Capture telemetry (off by default)

Per-second capture statistics and route-change lines for reproducing system-audio
loss on a tester's Mac, for example "unmuting a USB headset in Zoom silenced the
system track" (Jabra report, 2026-10-20). Local `app.jsonl` only: no samples, no
device names or UIDs, nothing sent to Sentry or analytics.

## Turn it on

```sh
defaults write com.justinbetker.draft capture-telemetry -bool true   # off: -bool false or delete
# or for one launch:
TRANSCRIPTED_CAPTURE_TELEMETRY=1 open -a Transcripted
```

Read at each recording start, so start a new recording after changing it. The
env var wins over the default (`0` forces it off).

## What it logs (`~/Library/Application Support/Transcripted/logs/app.jsonl`)

- `audio.system` **"System capture window"** and `audio.mic` **"Mic capture window"**, once a second:
  - `peak_dbfs`, `rms_dbfs` (`-inf` = exact digital zeros)
  - `zeros`, `zero_ratio`, `subnormals`, `nonfinite`
  - `buffers`, `frames`, `window_ms`
  - `max_gap_ms`: the longest wait between buffers, including the time since the last one. The system tap measures it at its 10–50 ms drain, the mic at its callback.
  - System only:
    - `host_min_ms`, `host_max_ms`, `host_jumps`: buffer-to-buffer host-time deltas, and buffers that don't start where the last one ended
    - `watch` (silence watch armed) and `unheard`
- `audio.system` **"Capture route state changed"**: the full state at start, then only the changed fields as `old->new`, once per change. `trigger` is the Core Audio selector that fired (`dOut`, `prs#`, `nsrt`, `livn`, `gone`, `stm#`, `slay`) or `poll` (the 1 s re-read that catches what no listener reports, such as a default-input change or a process starting input).
  - Prefixes: `out_*` default output, `in_*` default input, `agg_*` the tap's private aggregate.
  - Fields per prefix: `id` (session-local), `class` (usb, built_in, ...), `rate`, `alive`, `running`, `streams`, `channels`, `fmt`.
  - Process fields: `procs_out` and `procs_in` (other processes running output or input), `zoom_out` and `zoom_in`.

## Reading a repro

Look at the windows just before and after the unmute:

- **`rms_dbfs` drops to `-inf` with `zero_ratio` 1.000 and buffers keep coming:** the tap delivers digital zeros. The silence watch should arm and rebuild.
- **`rms_dbfs` drops to around -100 to -60 dBFS:** hiss that the zero-only silence check does not treat as loss.
- **`buffers` 0, a large `max_gap_ms`, or `host_jumps`:** the aggregate's clock or callbacks stalled.
- **A route line at the same second:**
  - `in_running` or `out_running` flips, `out_fmt` or `out_rate` changes, or `zoom_in` becomes true: the USB device reconfigured when the mic opened.
  - `agg_alive` false: the aggregate itself went away.

Also run `log stream --predicate 'process == "coreaudiod" OR process CONTAINS "zoom"'` during the repro.

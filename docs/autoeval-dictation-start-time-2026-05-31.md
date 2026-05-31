# Dictation Start Time Autoeval - 2026-05-31

## Goal

Improve the ready-engine dictation start path, measured by `dictation_recording_fast_start` `start_ms`.

## Event Source

`~/Library/Application Support/Transcripted/logs/events.jsonl`

## Baseline Raw Results

Command:

```bash
ruby -rjson -rtime -e 'path = ARGV.fetch(0); cutoff = Time.now - 24 * 60 * 60; sets = { "all" => [], "last_24h" => [] }; fallbacks = []; waits = []; timeouts = []; File.foreach(path) do |line| e = JSON.parse(line) rescue next; t = (Time.parse(e["timestamp"]) rescue nil); c = e["context"] || {}; case e["event"]; when "dictation_recording_fast_start"; ms = c["start_ms"].to_f; row = { t: t, ms: ms, trigger: c["trigger"], route: c["route_shape"], version: e["appVersion"] }; sets["all"] << row; sets["last_24h"] << row if t && t >= cutoff; when "dictation_fast_start_fell_back_to_wait", "dictation_recording_retry", "audio_start_deferred"; fallbacks << { t: t, event: e["event"], ms: c["start_ms"] || c["wait_ms"], trigger: c["trigger"], route: c["route_shape"], version: e["appVersion"] }; when "dictation_started_after_wait"; waits << { t: t, ms: c["wait_ms"].to_f, trigger: c["trigger"], route: c["route_shape"], version: e["appVersion"] }; when "microphone_start_timeout"; timeouts << { t: t, ms: c["wait_ms"], trigger: c["trigger"], route: c["route_shape"], version: e["appVersion"] }; end; end; def pct(values, q); return nil if values.empty?; sorted = values.sort; sorted[[((sorted.length * q).ceil - 1), 0].max]; end; sets.each do |name, rows| values = rows.map { |r| r[:ms] }; puts "#{name}: fast_start_samples=#{values.length} min=#{values.min&.round(1)} p50=#{pct(values,0.50)&.round(1)} p90=#{pct(values,0.90)&.round(1)} p95=#{pct(values,0.95)&.round(1)} max=#{values.max&.round(1)}"; end; puts "fallback_like_count=#{fallbacks.length} after_wait_count=#{waits.length} timeout_count=#{timeouts.length}"' "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"
```

Route breakdown command:

```bash
ruby -rjson -rtime -e 'path = ARGV.fetch(0); rows=[]; File.foreach(path) do |line| e = JSON.parse(line) rescue next; next unless e["event"] == "dictation_recording_fast_start"; c = e["context"] || {}; rows << { t: (Time.parse(e["timestamp"]) rescue nil), ms: c["start_ms"].to_f, trigger: c["trigger"], route: c["route_shape"] || "unknown", version: e["appVersion"] }; end; def pct(values, q); return nil if values.empty?; sorted = values.sort; sorted[[((sorted.length * q).ceil - 1), 0].max]; end; rows.group_by { |r| r[:route] }.sort_by { |_route, rs| -rs.length }.each do |route, rs| v = rs.map { |r| r[:ms] }; puts "route=#{route} samples=#{v.length} min=#{v.min.round(1)} p50=#{pct(v,0.50).round(1)} p90=#{pct(v,0.90).round(1)} p95=#{pct(v,0.95).round(1)} max=#{v.max.round(1)} versions=#{rs.map { |r| r[:version] }.compact.uniq.join(",")}"; end' "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"
```

Results:

| Slice | Samples | p50 | p90 | p95 | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| All routes, all logs | 573 | 86 ms | 134 ms | 432 ms | 1178 ms |
| Last 24h | 38 | 91 ms | 106 ms | 116 ms | 124 ms |
| Built-in input to built-in output | 401 | 87 ms | 120 ms | 134 ms | 402 ms |
| Built-in input to Bluetooth output | 172 | 86 ms | 478 ms | 556 ms | 1178 ms |

Fallback/recovery baseline:

| Event group | Count |
| --- | ---: |
| `dictation_fast_start_fell_back_to_wait` / `dictation_recording_retry` / `audio_start_deferred` | 126 |
| `dictation_started_after_wait` | 64 |
| `microphone_start_timeout` | 2 |

The current built-in route is already fast. The bad p95 comes mostly from historical Bluetooth-output sessions.

## Knobs Considered

| Knob | Decision | Why |
| --- | --- | --- |
| Move overlay work after recording start | Not tested | Current `start_ms` begins after the pre-start overlay call, so this would not improve the primary metric. |
| Move logging/sound after start | Not tested | These already happen after `startRecording()` succeeds, so they do not affect `start_ms`. |
| Change readiness polling interval | Not first | This affects the slow recovery path, not the ready-engine fast path. |
| Reduce fixed input-override settle delay | Tested | Slow Bluetooth-output starts consistently showed `dictation_input_device_override_settled` before fast start. |
| Cache/skip device lookup | Deferred | Plausible, but riskier and less directly tied to the observed p95 spike. |

## Experiment

Changed the input-override settle rule:

- Before: after applying a preferred input-device override, always wait `audioRecoveryDelay` (300 ms).
- After: if the immediate CoreAudio snapshot is already `.ready`, skip the fixed wait.
- Still wait 300 ms for `.routeNotSettled` or `.invalid`.

Files changed:

- `Sources/Speech/ParakeetEngine.swift`
- `Sources/Speech/ParakeetStartRecordingFailurePolicy.swift`
- `Tests/ParakeetStartRecordingFailurePolicyTests.swift`

## Results Table

Historical projection command:

```bash
ruby -rjson -e 'path=ARGV[0]; rows=[]; File.foreach(path) do |line| e=JSON.parse(line) rescue next; next unless e["event"] == "dictation_recording_fast_start"; c=e["context"] || {}; ms=c["start_ms"].to_f; eligible = c["route_shape"] == "built_in_input_to_bluetooth_output" && c["selection_overrode_default"] == "true" && ms >= 300; rows << { ms: ms, projected: eligible ? ms - 300 : ms, route: c["route_shape"], eligible: eligible }; end; def pct(values, q); s=values.sort; s[((s.length - 1) * q).round]; end; all_before=rows.map { |r| r[:ms] }; all_after=rows.map { |r| r[:projected] }; bt=rows.select { |r| r[:route] == "built_in_input_to_bluetooth_output" }; bt_before=bt.map { |r| r[:ms] }; bt_after=bt.map { |r| r[:projected] }; puts "eligible_projected_samples=#{rows.count { |r| r[:eligible] }}"; puts "all p50=#{pct(all_before,0.50).round(1)}->#{pct(all_after,0.50).round(1)} p90=#{pct(all_before,0.90).round(1)}->#{pct(all_after,0.90).round(1)} p95=#{pct(all_before,0.95).round(1)}->#{pct(all_after,0.95).round(1)} max=#{all_before.max.round(1)}->#{all_after.max.round(1)}"; puts "bluetooth_output p50=#{pct(bt_before,0.50).round(1)}->#{pct(bt_after,0.50).round(1)} p90=#{pct(bt_before,0.90).round(1)}->#{pct(bt_after,0.90).round(1)} p95=#{pct(bt_before,0.95).round(1)}->#{pct(bt_after,0.95).round(1)} max=#{bt_before.max.round(1)}->#{bt_after.max.round(1)}"' "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"
```

Projection rule: subtract the old 300 ms fixed wait from fast-start samples that matched the observed slow path: `built_in_input_to_bluetooth_output`, `selection_overrode_default=true`, and `start_ms >= 300`.

| Slice | Eligible samples | p50 before | p50 projected | p90 before | p90 projected | p95 before | p95 projected | Max before | Max projected |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| All routes | 30 | 87 ms | 87 ms | 134 ms | 132 ms | 402 ms | 168 ms | 1178 ms | 878 ms |
| Bluetooth output | 30 | 86 ms | 86 ms | 478 ms | 191 ms | 555 ms | 255 ms | 1178 ms | 878 ms |

This is a projected historical win, not a live post-change measurement.

## Winner

Winner for this pass: skip the fixed 300 ms input-override settle delay when the immediate audio format is already ready.

Why it wins:

- It targets the observed p95 spike.
- It keeps the safety wait for stale or invalid routes.
- It is small and covered by policy tests.

## Verification

Commands run:

```bash
bash build-deps.sh --force
bash build.sh --no-open
bash run-tests.sh
```

Results:

- `bash build-deps.sh --force`: passed.
- `bash build.sh --no-open`: passed after one rerun. First run failed because an unrelated edit touched `Sources/UI/Overlay/DictationSessionController.swift` during compilation.
- `bash run-tests.sh`: passed, 2929 passed / 0 failed.

## Remaining Risks

- No live post-change Bluetooth-output sample was captured from this worktree build because the installed `/Applications/Transcripted.app` was already running. I did not interrupt it.
- The next autoeval loop should collect 10-20 live starts on the Bluetooth-output route and confirm no increase in fallback events or `microphone_start_timeout`.
- Full-log historical p95 still contains old samples; use fresh samples or a bounded time window for future scoring.

## Continued Loop Notes

This is not a final "done forever" verdict. Experiment 1 found a real bottleneck, but the normal built-in fast path still needed more scrutiny.

Normal built-in path from current logs:

| Metric | Samples | p50 | p90 | p95 | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| `start_ms` (`sttRouter.startRecording()`) | 410 | 87 ms | 120 ms | 134 ms | 402 ms |
| `audio_engine_started` -> fast-start event | 408 | 3 ms | 4 ms | 5 ms | 11 ms |
| fast-start event -> `audio_samples_detected` | 410 | 102 ms | 104 ms | 104 ms | 124 ms |

Interpretation:

- Normal built-in dictation is fast, but it is not fully proven end-to-end.
- Existing logs say post-start event/log/UI work is tiny, around 3-5 ms p95.
- First audio-buffer arrival is consistently about 100 ms after fast-start, with 4800-frame buffers.
- The old metric missed true request-to-recording time, so the next code change adds that instrumentation.

### Experiment 2 - Add Missing End-to-End Timing

Added fields for future samples:

- `request_to_recording_ms` on `dictation_recording_fast_start` and `dictation_started_after_wait`
- `pre_recording_overhead_ms` on fast-start success/fallback
- `start_to_first_sample_ms` on `audio_samples_detected`

Also updated `scripts/ops/performance-budget.rb` so it prints request-to-recording and start-to-first-sample p95 when logs include those fields.

Decision: keep as measurement infrastructure. This is not a claimed speed win.

### Rejected Experiment - Eager Sample-Buffer Reserve

`ParakeetEngine.startRecording()` reserves capacity for a 30-minute Float buffer. That looked suspicious, so I microbenchmarked the exact reserve size:

```bash
swift -e 'import Foundation
let count = 86_400_000
var times: [Double] = []
for _ in 0..<10 {
  var values: [Float] = []
  let start = CFAbsoluteTimeGetCurrent()
  values.reserveCapacity(count)
  times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
  values.removeAll(keepingCapacity: false)
}
print(times)'
```

Result: p50 `0.000 ms`, max `0.013 ms`.

Decision: reject as a start-latency knob. It may still be worth a memory-footprint pass, but it is not the current dictation-start p95 problem.

Still-open knobs:

- stage timing inside `audioInputSnapshot`
- whether route lookup can be cached safely
- whether first-sample cadence can move below about 100 ms without weakening AirPods/HFP compatibility
- live 10-20 sample proof on both built-in and Bluetooth-output routes

## Continued Loop - Fresh Branch Samples

Branch build tested:

- Branch: `codex/dictation-start-autoeval`
- App path: `/Users/redbars/transcripted-latest/build/Transcripted.app`
- Trigger: synthetic Right Option physical-key event
- Route: `built_in_input_to_built_in_output`
- Sample method: warm model once, then 20 start/stop cycles with TextEdit as the paste target

Fresh built-in baseline from branch build:

| Cutoff | Samples | Metric | p50 | p90 | p95 | Max | Guardrails |
| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |
| `2026-05-31T19:48:16Z` | 20 intended starts | `request_to_recording_ms` | 88 ms | 93 ms | 98 ms | 100 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T19:48:16Z` | 20 intended starts | `pre_recording_overhead_ms` | 10 ms | 12 ms | 13 ms | 14 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T19:48:16Z` | 20 intended starts | `start_ms` | 78 ms | 88 ms | 91 ms | 91 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T19:48:16Z` | 20 intended starts | `start_to_first_sample_ms` | 183 ms | 192 ms | 196 ms | 196 ms | 4800-frame first buffers |

Same-cadence 1024-buffer rerun:

| Cutoff | Samples | Metric | p50 | p90 | p95 | Max | Guardrails |
| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |
| `2026-05-31T20:01:08Z` | 20 | `request_to_recording_ms` | 94 ms | 100 ms | 100 ms | 100 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T20:01:08Z` | 20 | `pre_recording_overhead_ms` | 10 ms | 11 ms | 11 ms | 11 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T20:01:08Z` | 20 | `start_ms` | 84 ms | 89 ms | 90 ms | 90 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T20:01:08Z` | 20 | `start_to_first_sample_ms` | 189 ms | 194 ms | 194 ms | 194 ms | 4800-frame first buffers |

### Tested Knob - Tap Buffer Size

Changed `TranscriptedConstants.audioTapBufferSize` from `1024` to `256`, rebuilt, warmed the model, then ran the same 20-cycle sampler.

Result:

| Cutoff | Samples | Metric | p50 | p90 | p95 | Max | Guardrails |
| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |
| `2026-05-31T19:55:59Z` | 20 | `request_to_recording_ms` | 89 ms | 100 ms | 102 ms | 102 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T19:55:59Z` | 20 | `pre_recording_overhead_ms` | 9 ms | 12 ms | 13 ms | 13 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T19:55:59Z` | 20 | `start_ms` | 80 ms | 87 ms | 93 ms | 93 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T19:55:59Z` | 20 | `start_to_first_sample_ms` | 185 ms | 192 ms | 198 ms | 198 ms | 4800-frame first buffers |

Decision: reject and revert.

Why:

- It did not reduce the actual first buffer size. The first buffer stayed at 4800 frames.
- It did not improve request-to-recording p95.
- It did not improve start-to-first-sample p95.

An earlier aggressive sampler run started again while the overlay was still in the short no-speech cleanup state and caused one `audio_format_read_timeout`. That was treated as a harness error, not as the knob score. The clean rerun above had no fallback, retry, or timeout events.

### Current Knob Ledger

| Knob | Status | Evidence |
| --- | --- | --- |
| Skip ready input-override settle delay | Kept | Historical Bluetooth-output projection improved p95 from 555 ms to 255 ms while keeping the wait for unready routes. |
| Add end-to-end timing fields | Kept | Enabled live scoring for `request_to_recording_ms`, `pre_recording_overhead_ms`, and `start_to_first_sample_ms`. |
| Eager sample-buffer reserve | Rejected | Microbench max was 0.013 ms. Not a start-latency problem. |
| Tap buffer size 1024 -> 256 | Rejected | Same 4800-frame first buffers; p95 `start_to_first_sample_ms` was 198 ms vs 194 ms on same-cadence 1024 rerun. |
| Overlay/UI pre-start work | Ruled out for now | `pre_recording_overhead_ms` p95 is 11-13 ms, so even deleting it all cannot hit a 20-30% win. |
| Diagnostics/logging hot path | Ruled out for primary metric | The primary request-to-recording fields are captured before the expensive post-start delivery/transcription path. |
| Cache route/device lookup on normal built-in route | Ruled out for current route | Built-in route uses `selection_reason=defaultIsSafe` with no input override; no live evidence of lookup cost in the 20-sample runs. |
| Preferred-input override delay beyond kept fix | Blocked | Needs live Bluetooth-output samples. Current branch samples were built-in input to built-in output only. |
| Slow-path recovery knobs | Separate lane | Relevant to fallback recovery, not normal ready-engine p95. Do not mix into the normal fast-start score. |

### Next Experiments

The normal built-in path is now probably close to the floor for this route: p95 request-to-recording is about 100 ms and p95 first sample is about 194 ms.

The remaining high-value tests are:

1. Collect 20 live Bluetooth-output starts on this branch.
2. If Bluetooth still has p95 spikes, test only override/route-settle knobs there.
3. If built-in needs more speed anyway, add stage timing inside `audioInputSnapshot` and `installTapAndStartEngine`; do not guess at cache changes without that split.

## Continued Loop - Stage Timing And Prepare Knob

### Bluetooth-Output Case

Status: blocked for this run.

Commands:

```bash
which SwitchAudioSource || true
system_profiler SPAudioDataType -json
```

Result:

- `SwitchAudioSource` was not installed.
- CoreAudio only reported `MacBook Pro Microphone` and `MacBook Pro Speakers`.
- No Bluetooth output route was available to switch to, so 20 Bluetooth-output samples could not be collected.

### Measurement Patch - Audio Start Stage Timing

Added a local `dictation_audio_start_timing` event with:

- `audio_input_selection_load_ms`
- `audio_input_device_check_ms`
- `audio_input_snapshot_read_ms`
- `audio_input_override_settle_sleep_ms`
- `audio_input_settled_snapshot_read_ms`
- `audio_input_total_ms`
- `audio_tap_remove_ms`
- `audio_tap_install_ms`
- `audio_engine_prepare_ms`
- `audio_engine_start_ms`
- `audio_start_work_ms`

Command:

```bash
bash build.sh --no-open
# launch /Users/redbars/transcripted-latest/build/Transcripted.app
# warm once, then run 20 Right Option start/stop cycles
```

Instrumented built-in route result:

| Cutoff | Samples | Metric | p50 | p90 | p95 | Max | Guardrails |
| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |
| `2026-05-31T20:09:41Z` | 20 | `request_to_recording_ms` | 95 ms | 106 ms | 106 ms | 106 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T20:09:41Z` | 20 | `pre_recording_overhead_ms` | 10 ms | 15 ms | 18 ms | 18 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T20:09:41Z` | 20 | `start_ms` | 85 ms | 91 ms | 97 ms | 97 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T20:09:41Z` | 20 | `start_to_first_sample_ms` | 189 ms | 195 ms | 200 ms | 200 ms | 4800-frame first buffers |

Stage timing summary:

| Stage | Samples | p50 | p90 | p95 | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| `audio_input_selection_load_ms` | 20 | 0 ms | 0 ms | 1 ms | 1 ms |
| `audio_input_snapshot_read_ms` | 20 | 16 ms | 18 ms | 19 ms | 19 ms |
| `audio_input_total_ms` | 20 | 17 ms | 19 ms | 19 ms | 19 ms |
| `audio_tap_remove_ms` | 20 | 0 ms | 0 ms | 0 ms | 0 ms |
| `audio_tap_install_ms` | 20 | 0 ms | 0 ms | 0 ms | 0 ms |
| `audio_engine_prepare_ms` | 20 | 21 ms | 25 ms | 28 ms | 28 ms |
| `audio_engine_start_ms` | 20 | 45 ms | 47 ms | 49 ms | 49 ms |
| `audio_start_work_ms` | 20 | 66 ms | 72 ms | 78 ms | 78 ms |

Decision:

- Keep the measurement event for now. It proved route lookup is not the built-in p95 problem.
- Cache route/device lookup is ruled out for the built-in route because selection load was 0-1 ms and no device override check ran.
- The actual built-in hot chunk is CoreAudio prepare/start, not app route lookup.

### Tested Knob - Skip Explicit `audioEngine.prepare()`

Changed the start path to call `audioEngine.start()` without a separate `audioEngine.prepare()` call. `AVAudioEngine.start()` can prepare implicitly, so this tests whether the explicit prepare is only duplicating work.

Command:

```bash
bash build.sh --no-open
# launch /Users/redbars/transcripted-latest/build/Transcripted.app
# warm once, then run 20 Right Option start/stop cycles
```

Result:

| Cutoff | Samples | Metric | p50 | p90 | p95 | Max | Guardrails |
| --- | ---: | --- | ---: | ---: | ---: | ---: | --- |
| `2026-05-31T20:15:13Z` | 20 | `request_to_recording_ms` | 93 ms | 97 ms | 98 ms | 98 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T20:15:13Z` | 20 | `pre_recording_overhead_ms` | 9 ms | 11 ms | 11 ms | 11 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T20:15:13Z` | 20 | `start_ms` | 85 ms | 87 ms | 88 ms | 88 ms | 0 fallback / 0 retry / 0 timeout |
| `2026-05-31T20:15:13Z` | 20 | `start_to_first_sample_ms` | 189 ms | 192 ms | 193 ms | 193 ms | 4800-frame first buffers |

Stage comparison:

| Stage | With explicit prepare p95 | Skip explicit prepare p95 | Decision |
| --- | ---: | ---: | --- |
| `audio_engine_prepare_ms` | 28 ms | 0 ms | removed |
| `audio_engine_start_ms` | 49 ms | 69 ms | start absorbs some work |
| `audio_start_work_ms` | 78 ms | 69 ms | 9 ms p95 win |
| `request_to_recording_ms` | 106 ms | 98 ms | 8 ms p95 win |
| `start_ms` | 97 ms | 88 ms | 9 ms p95 win |

Decision: keep as a small win.

This is not the requested 20-30% win, but it is measured, isolated, and had no fallback/retry/timeout regression in 20 samples.

### Updated Knob Ledger

| Knob | Status | Evidence |
| --- | --- | --- |
| Stage timing inside `audioInputSnapshot` / tap / engine start | Kept | Added `dictation_audio_start_timing`; 20/20 starts emitted timing events. |
| Cache route/device lookup on built-in route | Ruled out | Selection load p95 was 1 ms; no override device check ran on built-in route. |
| Further preferred-input override delay tuning | Blocked | Needs Bluetooth-output route; current machine only exposed built-in input/output. |
| First audio buffer cadence via tap buffer | Rejected | 1024 -> 256 kept 4800-frame first buffers and did not improve p95. |
| Overlay/UI pre-start work | Ruled out for now | `pre_recording_overhead_ms` p95 was 11-18 ms, below the requested 20-30% win by itself. |
| Diagnostics/logging hot path | Ruled out for primary start win | Stage data shows CoreAudio start work dominates; post-start delivery/transcription logging is outside request-to-recording. |
| Skip explicit `audioEngine.prepare()` | Kept | p95 request-to-recording 106 -> 98 ms in the instrumented run, with no guardrail events. |
| Keep engine running between starts | Ruled out | Would likely keep mic hardware active after stop, weakening privacy/battery expectations. |

### Current Verdict

Built-in route: small measured win, no 20-30% win.

Bluetooth-output route: blocked until a Bluetooth output device is connected.

Best next run:

1. Connect Bluetooth output and rerun the 20-sample branch sampler.
2. If Bluetooth still spikes, tune only the route/override path.
3. If no Bluetooth route is available, treat this as a built-in-route no-win except for the kept 8-9 ms p95 prepare/start cleanup.

Verification:

- `bash run-tests.sh` - 2938 passed, 0 failed.
- `bash build.sh --no-open` - build, signing, launch smoke, and performance budget passed.

## Continued Loop - Slow-Path Recovery Knobs

This lane scores the fallback wait path separately from normal built-in starts. It should not be mixed into the normal p95 score because the recovery path only runs after the ready-engine fast start cannot start recording.

### Current Audio Route Availability

Command:

```bash
system_profiler SPAudioDataType -json | ruby -rjson -e 'data=JSON.parse(STDIN.read); devices=(data["SPAudioDataType"]||[]).flat_map{|x| x["_items"]||[]}; puts devices.map{|d| [d["_name"], d["coreaudio_default_audio_input_device"], d["coreaudio_default_audio_output_device"]].compact.join(" | ")}; bluetooth=devices.select{|d| d.to_s.downcase.include?("bluetooth") || d.to_s.downcase.include?("airpods")}; warn "bluetooth_count=#{bluetooth.length}"'
```

Result:

```text
bluetooth_count=0
MacBook Pro Microphone | spaudio_yes
MacBook Pro Speakers | spaudio_yes
```

No Bluetooth route is currently available for fresh route-recovery samples.

### Historical Recovery Signal

Command:

```bash
ruby -rjson -e 'path=File.expand_path("~/Library/Application Support/Transcripted/logs/events.jsonl"); counts=Hash.new(0); waits=[]; recovery_starts=[]; File.foreach(path){|line| begin; e=JSON.parse(line); rescue JSON::ParserError; next; end; event=e["event"]||e["name"]; ctx=e["context"]||e["properties"]||{}; next unless event; if %w[dictation_recording_recovery_start dictation_readiness_refresh_timeout microphone_start_timeout dictation_started_after_wait].include?(event); route=ctx["route_shape"]||"unknown"; counts[[event,route]]+=1; waits << ctx["wait_ms"].to_i if event=="dictation_started_after_wait" && ctx["wait_ms"]; recovery_starts << ctx["readiness_refreshes"].to_i if event=="dictation_recording_recovery_start" && ctx["readiness_refreshes"]; end}; counts.sort.each{|(event,route),count| puts "#{event},#{route},#{count}"}; if waits.any?; s=waits.sort; p95=s[((s.length-1)*0.95).ceil]; puts "started_after_wait_wait_ms:n=#{s.length},p50=#{s[s.length/2]},p95=#{p95},max=#{s[-1]}"; end; if recovery_starts.any?; hist=Hash.new(0); recovery_starts.each{|v| hist[v]+=1}; puts "recovery_start_readiness_refreshes=#{hist.sort.to_h}"; end'
```

Result:

| Event | Route | Count |
| --- | --- | ---: |
| `dictation_readiness_refresh_timeout` | `built_in_input_to_bluetooth_output` | 1 |
| `dictation_readiness_refresh_timeout` | `built_in_input_to_built_in_output` | 1 |
| `dictation_recording_recovery_start` | `built_in_input_to_bluetooth_output` | 5 |
| `dictation_recording_recovery_start` | `built_in_input_to_built_in_output` | 1 |
| `dictation_started_after_wait` | `built_in_input_to_bluetooth_output` | 3 |
| `dictation_started_after_wait` | `built_in_input_to_built_in_output` | 62 |
| `microphone_start_timeout` | `built_in_input_to_bluetooth_output` | 2 |

Historical `dictation_started_after_wait` values: `n=65`, `p50=386 ms`, `p95=681 ms`, `max=6547 ms`.

Recovery-start refresh counts seen historically: `{0=>1, 1=>1, 4=>4}`.

This is useful context, but it is not a clean fresh branch corpus. The Bluetooth-output recovery path cannot be proven better or worse until Bluetooth output is connected again.

### Deterministic Policy Score

Command:

```bash
ruby -c scripts/ops/dictation-recovery-autoeval.rb
ruby scripts/ops/dictation-recovery-autoeval.rb
ruby scripts/ops/dictation-recovery-autoeval.rb --details
```

Result:

The existing `scripts/ops/dictation-recovery-autoeval.rb` scorer had drifted from the live policy constants. This pass updated its baseline to match current code:

- poll interval: `100 ms`
- refresh interval: `300 ms`
- refresh timeout: `900 ms`
- forced recovery threshold: `5` refreshes
- ready-start attempt cap: `2`

Knob summary after fixing the scorer:

| Knob | p95 ms | p95 delta | Max ms | Max delta | Unexpected failures | Starts | Start delta | Refreshes | Refresh delta | Recovery starts | Forced | Refresh timeouts | Mic timeouts |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | 1990 | 0 | 1990 | 0 | 0 | 17 | 0 | 21 | 0 | 7 | 5 | 1 | 1 |
| poll_75ms | 2140 | +150 | 2140 | +150 | 0 | 17 | 0 | 19 | -2 | 7 | 5 | 1 | 1 |
| poll_50ms | 2040 | +50 | 2040 | +50 | 0 | 17 | 0 | 20 | -1 | 7 | 5 | 1 | 1 |
| refresh_interval_200ms | 1720 | -270 | 1720 | -270 | 0 | 18 | +1 | 24 | +3 | 7 | 6 | 1 | 1 |
| refresh_interval_150ms | 1720 | -270 | 1720 | -270 | 0 | 18 | +1 | 24 | +3 | 7 | 6 | 1 | 1 |
| refresh_timeout_600ms | 3800 | +1810 | 3800 | +1810 | 2 | 21 | +4 | 42 | +21 | 10 | 8 | 13 | 3 |
| recovery_start_after_3_refreshes | 2020 | +30 | 2020 | +30 | 0 | 18 | +1 | 16 | -5 | 7 | 6 | 1 | 1 |
| recovery_start_after_2_refreshes | 2020 | +30 | 2020 | +30 | 0 | 20 | +3 | 13 | -8 | 8 | 7 | 1 | 1 |
| max_ready_start_attempts_1 | 1990 | 0 | 1990 | 0 | 0 | 17 | 0 | 20 | -1 | 7 | 7 | 1 | 1 |
| force_after_4_refreshes | 1800 | -190 | 1800 | -190 | 0 | 14 | -3 | 14 | -7 | 2 | 7 | 1 | 1 |
| combo_poll100_refresh200_attempts2 | 1720 | -270 | 1720 | -270 | 0 | 18 | +1 | 24 | +3 | 7 | 6 | 1 | 1 |

Important per-scenario regressions from `--details`:

| Knob | Regressed scenario | Delta | Why it was rejected |
| --- | --- | ---: | --- |
| `refresh_interval_200ms` | `bluetooth_late_ready_stale_flag` | +600 ms | Starts recovery earlier, wastes the guarded attempt, then waits for forced recovery. |
| `refresh_interval_150ms` | `bluetooth_late_ready_stale_flag` | +600 ms | Same regression as 200 ms with no extra p95 gain. |
| `refresh_timeout_600ms` | `selected_input_stale_until_force` | timeout | Adds false stale-refresh failures. |
| `refresh_timeout_600ms` | `ready_flag_start_keeps_failing` | timeout | Turns an expected success into `microphone_start_timeout`. |
| `recovery_start_after_3_refreshes` | `bluetooth_late_ready_stale_flag` | +900 ms | Starts too early and loses the useful guarded attempt. |
| `recovery_start_after_2_refreshes` | `bluetooth_reconnect_stale_flag` | +900 ms | Too aggressive for Bluetooth route settle. |
| `max_ready_start_attempts_1` | `first_start_fails_retry_succeeds` | +600 ms | Forces hard recovery instead of allowing the cheap retry. |
| `force_after_4_refreshes` | `bluetooth_reconnect_stale_flag` | +680 ms | Skips the faster guarded recovery start and forces a slower rebuild. |

Decision:

- `dictationReadinessPollInterval`: rejected. 75 ms and 50 ms worsened aggregate p95 in the deterministic suite.
- `dictationReadinessRefreshInterval`: rejected. 200 ms/150 ms improved aggregate p95 by 270 ms, but increased starts/refreshes/forced recoveries and regressed the late Bluetooth settle scenario by 600 ms.
- `dictationReadinessRefreshTimeout`: rejected. 600 ms created 2 unexpected failures and 3 simulated microphone timeouts.
- recovery-start threshold: rejected. Starting after 3 or 2 refreshes regressed late Bluetooth scenarios by 900 ms.
- ready-start attempt cap: rejected. One attempt regressed cheap retry success by 600 ms and repeated ready-start failure recovery by 700 ms.
- forced recovery threshold: rejected. Forcing after 4 refreshes improved aggregate p95 by 190 ms, but regressed Bluetooth reconnect by 680 ms.
- `dictationRecoveryBudget` 6 s: ruled out for latency. Lowering it only fails faster; raising it worsens start latency. Keep the current budget unless the metric changes to recovery success rate.
- forced recovery attempt budget: ruled out for this latency goal. The scorer already keeps attempts bounded; more attempts would increase worst-case latency and fewer attempts would reduce recovery chance.

### Final Knob Ledger

| Knob | Status | Decision |
| --- | --- | --- |
| Stage timing inside `audioInputSnapshot` / tap / engine start | Kept | Added `dictation_audio_start_timing`; proved CoreAudio start work dominates built-in p95. |
| Cache route/device lookup until route changes | Ruled out for built-in | Selection load p95 was 1 ms; no built-in override check ran. |
| Preferred-input override delay tuning | Kept then blocked | The safe ready-route skip is kept; deeper Bluetooth tuning is blocked without Bluetooth output. |
| First audio buffer cadence via tap buffer | Rejected | 1024 -> 256 did not reduce 4800-frame first buffers or improve p95. |
| Overlay/UI pre-start work | Ruled out | `pre_recording_overhead_ms` p95 was 11-18 ms, too small for the requested win. |
| Diagnostics/logging hot path | Ruled out | Stage timing shows post-start diagnostics are not the request-to-recording bottleneck. |
| Skip explicit `audioEngine.prepare()` | Kept | Built-in p95 request-to-recording improved 106 -> 98 ms with no guardrail events. |
| Keep engine running between starts | Ruled out | Would keep mic hardware active after stop and weaken privacy/battery expectations. |
| Recovery poll interval | Rejected | 75 ms and 50 ms worsened deterministic p95. |
| Recovery refresh interval | Rejected | 200 ms/150 ms improved aggregate p95 but regressed late Bluetooth settle by 600 ms and increased starts/refreshes/forced recoveries. |
| Recovery refresh timeout | Rejected | 600 ms created 2 unexpected failures and 3 simulated microphone timeouts. |
| Recovery start threshold | Rejected | Earlier recovery starts regressed Bluetooth settle scenarios by 900 ms. |
| Recovery budget | Ruled out | Lower budget fails faster rather than starting faster; higher budget worsens latency. |

## Final Verdict

Built-in route: no 20-30% win found. The kept measured win is small: p95 request-to-recording improved 106 -> 98 ms, and p95 start improved 97 -> 88 ms in the instrumented run.

Bluetooth-output route: blocked by missing hardware in the current environment. The prior safe improvement for ready Bluetooth routes is kept, but deeper route-settle tuning cannot be scored right now.

Slow recovery route: no safe code change kept. After updating the deterministic scorer to current constants, every recovery knob either worsened p95, created failure regressions, or improved aggregate p95 while hurting a Bluetooth-settle scenario enough to reject it.

Conclusion: this autoeval found a small built-in-route keeper and then hit a clear no-win/blocker boundary for the remaining knobs.

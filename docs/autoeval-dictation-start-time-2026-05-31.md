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

# Hosted full QA bench

Swift CI's `full_bench_source_sha` dispatch input runs the literal full bench on
GitHub-hosted Apple Silicon. Use the full trusted candidate commit SHA. Leave
`staged_update_source_sha` empty and `run_hardware_smokes` false. Normal CI and
owner hardware jobs do not run in this mode.

The workflow and its fixture helper come from `github.workflow_sha`; the
candidate lives in a separate checkout at the requested SHA. Both identities
are checked before prerequisites. The candidate's bench and validators are
unchanged. Builds, launch smokes and timing-sensitive tests remain enabled;
failures are not retried until green.

## Synthetic artifact prerequisites

A fresh runner has no saved meeting library. The candidate's `validate-all`
command treats an absent meetings directory as a failure, while the full bench
also validates saved artifacts. `scripts/ci/prepare-hosted-qa-artifacts.py`
therefore requires the disposable hosted `runner` account, absent current and
legacy application paths, and no capture-directory environment overrides. It
first requires exactly the two expected missing-meetings failures. Any other
failure stops preparation.

It then invokes the candidate's existing `generate-fixtures` command in a new
owned temporary directory and copies its three synthetic transcripts, speaker
and statistics databases, and synthetic log into the complete default layout.
The generator must exit first. Each quiescent SQLite family includes the main
file, WAL and shared-memory companions; copied database files use mode 0600.
On macOS, copying the main file alone can break read-only queries even when
its bytes are complete and the WAL is empty. The regression test checks actual
SQLite integrity, schema, rows and WAL mode after a clean source close.
The unchanged validator must pass against those artifacts before the bench
starts. An empty directory is insufficient. This setup does not prove real
saved customer artifacts, recordings, Bluetooth, or human pasteback behavior.

## Evidence and failure handling

Only `full-qa-bench-receipt.json` and `qa-artifact-setup-receipt.json` are uploaded,
with seven-day retention. They contain exact source/workflow identities, bench
statuses, and allowlisted validator check identifiers/statuses/counts. Raw
logs, capture content, file paths and validator details stay on the runner.
Unknown or malformed diagnostic checks fail closed.

Run 37245799079 tested source `e42ad0f759612e0080f2d11bb5de12fda6b590bd`
with workflow `21424e8783e9593d8f1f5a7cb4f8472b62772c6a`. Fourteen of fifteen
steps passed; `21-qa-validate-all` failed. That run did not retain its detailed
validator log, so its exact cause remains unrecovered. The new missing-layout
preflight tests the fresh-runner hypothesis independently; it does not recover
or retrospectively change the original failure.

A successful automated bench still reports HOLD for separate signed-release,
live-service and human gates. Read actual step statuses separately from that
release verdict.

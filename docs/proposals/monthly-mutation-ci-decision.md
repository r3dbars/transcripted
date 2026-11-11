# Monthly mutation CI: owner decision

Status: unselected proposal for REVIEW.md item BUILD-CI-1. No workflow, runner,
VM image, admission rule, schedule, credential, or service configuration changes.

## The routing mismatch

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

`.github/workflows/mutation-monthly.yml` schedules a report-only `probe` job on
the `transcripted-mac` label, with a manual dispatch option and a nonempty runner
heartbeat condition. It sets a 240-minute job timeout and asks the probe for at
most twelve mutants per listed file. It is not a required PR check.

The checked-in automatic Mac service does not route that job:

- `waiting_mac_jobs` in `scripts/ci/mac-runner.sh` enumerates `swift-ci.yml`
  runs and looks for `checks`, `spm-tests`, and `app-build` jobs. It does not
  discover the monthly workflow's `probe` job.
- The same script's `hook_decision` permits only those job names (or an empty
  name), and only push, manual dispatch, or eligible same-repository PR events.
  It does not admit `probe` or a scheduled event.
- `docs/self-hosted-mac-runner.md` describes these restrictions as part of
  keeping untrusted work off the Mac. They must not be widened accidentally.
- `.github/AGENTS.md` and `docs/rules.md` describe monthly mutation reporting,
  while `docs/mutation-testing.md` separately documents the local probe.

The heartbeat condition alone does not make these routing and admission rules
compatible. This is a source finding about the documented automatic path, not
an audit of installed runners, hosted run history, existing reports, or costs.
No runner, VM, service, workflow dispatch, credential, or mutation probe was run.

## Choose where this report should run

All options are unselected; the owner may revise them.

- [ ] A. Support the report on the isolated Mac runner. Review routing, explicit
      job and event admission, VM isolation, resource limits and report handling
      together. Preserve repo/fork checks and existing job restrictions; do not
      admit all scheduled jobs or all jobs carrying the runner label.
- [ ] B. Use a compatible hosted runner. Confirm the required macOS/toolchain
      and dependencies, choose the allowed runtime and usage budget, and update
      the heartbeat condition, runner selection, and docs consistently. No hosted
      price or monthly usage estimate is established by this worksheet.
- [ ] C. Retire the automatic monthly report. Decide whether to retain the local
      manual probe, and update the workflow and coverage claims together. Do not
      present local probe self-tests as a completed monthly mutation report.

Owner conditions: pending, including report cadence, coverage, runtime budget,
allowed events, and who reviews surviving mutants.

After a decision, add deterministic routing/admission tests appropriate to that
choice, then verify the actual runner and report artifact in an approved isolated
run. Keep failures, survivors, skipped files and missing artifacts visible.
Static checks or a successful VM boot alone do not prove a mutation run finished.

This worksheet selects no execution policy and does not complete BUILD-CI-1.

# Dayflow Timeline Manual QA

This checklist is for the Dayflow-style Timeline once the feature is wired into
the app. It is intentionally short and separates automated fixture proof from
real Screen Recording / TCC proof.

Automated green is not real screen-recording proof.

## Before manual QA

- Run `python3 scripts/dev/check-build-source-lists.py`.
- Run `bash build.sh --no-open`.
- Run `bash run-tests.sh`.
- Run `python3 scripts/ops/privacy-leak-sweep.py --write-report build/privacy-leak-sweep-report.json`.
- Use synthetic data in notes, screenshots, logs, reports, and PR text.

## Manual checklist

- [ ] Enable Timeline from onboarding/settings and confirm Screen Recording permission is requested only after opt-in.
- [ ] Run for at least 30 minutes and confirm screenshot cadence, pause/resume, and timeline card generation without raw text in logs.
- [ ] Record one meeting and one dictation and confirm both project into the same day timeline.
- [ ] Revoke Screen Recording permission and confirm capture pauses with recoverable UI instead of crashing.
- [ ] Run privacy leak sweep before sharing PR notes, QA reports, or release notes.

## Hold conditions

- Any raw OCR text, window title, app name, screenshot path, transcript text,
  speaker name, meeting title, email, token, or absolute path appears in shared
  QA output.
- Timeline capture starts before explicit opt-in and Screen Recording approval.
- Permission revocation crashes the app or tight-loops retries.
- Meeting/dictation projections disappear from the day timeline after refresh.

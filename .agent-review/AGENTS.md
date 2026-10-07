# Agent review folder

Sanitized review evidence from local agent runs. `README.md` here has the rules; the short version:

- Only sanitized material belongs here: no private transcripts, customer data, tokens, personal paths, or real user content.
- `visuals/` holds screenshots or GIFs for PRs that change UI, app copy, or user-facing flow. Prefer small PNGs; GIFs only when motion matters. `.agents/test-matrix.yml` expects them for UI changes.
- Nothing here is current UI truth. A visual is evidence for the PR or issue it came from. For the current look, read the code or take a fresh screenshot from your branch.
- `test-audit-2026-09-30/` is a point-in-time test audit. It lists tests deleted since, so `scripts/dev/check-doc-paths.py` skips its files; don't trust its paths.

# SCRIPTS-OPS-A: duplicate nightly-digest output documentation

SCRIPTS-OPS-A and DOCS-12 identify the same personal output-directory wording
in `scripts/README.md`. The correction is proposed in
[PR #2430](https://github.com/r3dbars/transcripted/pull/2430), at commit
`70ed121b1815b820303e59b8e57f7778290cb7a7`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. DOCS-12 remains that PR's primary report ID.

The actual `scripts/ops/generate-nightly-digest.py` derives its default report
directory from the checkout containing the script: `build/nightly-digest/`.
Its `--output-dir` argument overrides that default, and `write_reports` receives
the selected directory. #2430 updates only the README's output-location list;
it keeps the four dated/latest HTML/JSON filenames and documents the existing
override. It does not change or execute the generator.

The report lists this correction under both IDs within the pending broad audit
proposal. This dedicated SCRIPTS-OPS-A disposition records that shared scope
without repeating the README patch or claiming another implementation.
The broad proposal's other script and tool changes are excluded from #2430.

At verification, #2430 is an open, unmerged draft. Accepting this document alone
does not apply its correction or prove digest generation or scheduled operation.
Review the actual patch and validation in #2430. No automation memories or logs
were read, no digest was run, and no observability service was contacted for
this disposition. No landed fix or app/hardware runtime proof is claimed.

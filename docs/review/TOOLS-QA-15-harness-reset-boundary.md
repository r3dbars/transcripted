# TOOLS-QA-15: fixture reset baseline remains active

On audited main `8a38235`, `GenerateFixtures.run()` refuses to replace a
nonempty output folder unless it contains `.transcripted-qa-fixtures`.
That is a real guard. It is different from proving that a caller-selected
output path resolves under a root the harness owns.

The existing `harness-delete-outside-owned-root` rule still reports the
`removeItem(outputURL)` call at line 26. Its current Swift checks recognize
containment or symlink-related guards, not this empty-folder/marker condition.
The unchanged lint baseline allows exactly one finding for this file.
Running lint on the file reports one grandfathered finding and none over
baseline. The raw rule independently returns that same one finding.

Consequently, removing the baseline entry alone would leave one finding over
the current rule's allowance. The finding does not establish that this entry
is obsolete under the current checker. This is static evidence, not a runtime
deletion-safety certification or a validated exploit report.

A separate ownership-policy choice remains unselected:

- Keep the current custom-output behavior and tracked baseline while reviewing
  its reset boundary.
- Restrict resets to a specifically owned root, with tests for rejected paths
  and ownership boundaries before shrinking the baseline.
- Treat marker ownership as sufficient only after reviewing its provenance
  and path/type boundaries, then change the checker with appropriate controls.

This disposition changes no CLI behavior, marker semantics, checker, baseline,
or waiver. No option is approved by accepting the factual correction alone.
`generate-fixtures` and its deletion path were not executed for this review.

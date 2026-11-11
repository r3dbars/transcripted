# MCP speaker identity: owner decision

Status: unselected worksheet for REVIEW.md item TOOLS-MCP-3.

The accompanying correction counts distinct meeting filenames and excludes all
names already matched by a lookup from its co-speaker lists. It preserves the
existing matching rule and sums the metrics of those already-matched rows.
It does not establish that every name match is the same person.

Name queries currently expand nicknames, then accept case-insensitive equality
or substring `LIKE` matches. That preserves short queries such as “Jenny” for
“Jenny Wen” and “Nate” for “Nate Smith”, but can include unrelated people with
overlapping names. `%` and `_` in a query also retain SQLite wildcard meaning.
UUID lookup uses the persistent speaker ID. Name matching is also used by
utterance search, semantic search, and summary-owner filters, so a new rule
needs coordinated review across those paths.

All options remain unselected:

- [ ] Prefer exact names or persistent IDs; decide what a short-name lookup
      should return when there is no exact match.
- [ ] Keep short names through a word-boundary fallback; define nickname,
      Unicode, wildcard escaping, and multiple-person ambiguity behavior.
- [ ] Keep broad matching, but expose ambiguous candidates and require a
      choice before presenting a combined person profile.

Owner conditions: pending. Include examples with shared first names, nickname
variants, full names containing another name, and literal `%` / `_` characters.
Also decide how the profile should choose its displayed name and ID when a
name lookup matches rows carrying different persistent IDs.

No identity policy is selected here. Cross-person name conflation remains open
until the owner chooses a rule and its behavior is implemented and verified.

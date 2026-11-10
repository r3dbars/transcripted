# Hybrid search ranking: owner decision

Status: unselected proposal for REVIEW.md item TOOLS-MCP-2. The accompanying
repair corrects recall claims and makes equal-score ordering explicit. It does
not adopt lexical-first ranking or change the default search mode.

## Current behavior

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

- `ToolHandlers+Search.swift` defaults `search` and `search_context` to hybrid.
  A caller can explicitly request lexical or semantic search.
- `SemanticSearchFusion.swift` adds reciprocal-rank contributions from the
  lexical and semantic candidate lists, ranks their union, then returns only
  `maxMeetings` or `maxItems` rows. A semantic candidate can displace an exact
  lexical hit. Hybrid is not a superset of lexical recall at a fixed limit.
- Within a returned meeting, lexical snippets come first, followed by distinct
  semantic snippets up to the snippet limit. This does not reserve a result
  slot for every meeting with a lexical hit.
- The candidate lists are already bounded upstream. Fusion's meeting total is
  the number of distinct filenames in those supplied lists, not proof of the
  number of matching meetings across the whole library.
- `TranscriptIndex+Context.swift` also ranks across capture kinds and applies a
  final limit. Writing search is lexical-only. This repair leaves both paths
  unchanged, along with index construction, providers and fallback behavior.

For example, two disjoint six-row candidate lists with a six-row output limit
cannot both fit. With equal-score ties in first-seen order, the result can
contain the first three lexical and first three semantic candidates, excluding
the last three lexical candidates. This is a synthetic ranking example, not
evidence of how often real queries encounter that mix.

## Choose the ranking contract

Both options are unselected.

- [ ] A. Keep reciprocal-rank fusion and its fixed output limit. Describe the
      result as a relevance-ranked mixture that can omit lexical candidates.
- [ ] B. Reserve lexical candidates first, then fill remaining slots with
      semantic-only candidates. Define exactly which lexical ordering and
      limits this protects before changing what agents see first.

Owner fill-ins:

- Selected ranking contract and user-facing explanation: pending.
- Whether the contract applies to meetings, dictations and cross-kind context:
  pending.
- Behavior when lexical results alone exceed the requested limit: pending.
- Evidence and representative query set for comparing ranking quality: pending.

## Validation boundary

The pure fusion fixture supplies synthetic value types directly to the two
within-kind fusion functions. It checks ranking, ties, limits and snippet
precedence. It does not run an embedding model, build an index, query saved
captures, validate global recall, or measure real-world ranking quality.

After a choice, review any ranking change and its tests separately. This
worksheet neither selects an option nor completes the owner decision in
TOOLS-MCP-2.

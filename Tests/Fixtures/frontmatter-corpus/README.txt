# Frontmatter parser corpus

Shared fixture corpus for W3-A (audit 2026-07-08 wave 3): establishing canon
by contract across the three independent frontmatter/transcript parsers:

- `Sources/TranscriptedCore/Storage/TranscriptFrontmatter.swift` — flat
  `key: value` only, intentionally not a general YAML parser.
- `Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureMarkdownParser.swift`
  — the most complete implementation; adds inline (`[a, b]`) and block
  (`- item`) list flattening.
- `Tools/TranscriptedMCP/Sources/TranscriptedMCP/ToolHandlers+Meetings.swift`
  (`frontmatterBlock(of:)`) — raw fence-block extraction only, no value
  parsing.

Each `NN-*.md` file here is a fixture. `expected/NN-*.json` is the golden
output every parser must agree on for that fixture:

```json
{
  "hasFrontmatter": true,
  "body": "... exact text after the closing '\n---\n' fence ...",
  "values": { "key": "value", ... }
}
```

or, when the fixture has no parseable frontmatter fence:

```json
{ "hasFrontmatter": false }
```

## Scope of the equivalence contract

`body` and `hasFrontmatter` are asserted for **every** fixture — fence
detection is the one piece of logic all three implementations must never
silently drift apart on.

`values` only lists keys that are genuinely flat scalars with no list,
comment, or empty-value ambiguity. `TranscriptFrontmatter` is deliberately
a strict subset of `CaptureMarkdownParser` (it does not flatten
`- item` blocks or `[a, b]` inline lists, and it has no `#`-comment
skip), so fixtures that exercise those richer behaviors (07, 08, 09, 12)
intentionally omit the divergent key from `values` — only the unrelated,
unambiguous keys in the same fixture are asserted. See the per-package
parity tests for the divergence assertions themselves:

- `Tests/TranscriptedCoreTests/FrontmatterCorpusParityTests.swift`
- `Tools/TranscriptedCaptureKit/Tests/TranscriptedCaptureKitTests/FrontmatterCorpusParityTests.swift`
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/FrontmatterCorpusParityTests.swift`

If a parser's output for a fixture changes, its parity test fails CI —
silent three-way drift becomes a build break instead of a support ticket.

# CORE-REST-7: decide the recording-stats contract

Status: owner decision pending. No option is selected here.

At audited main `8a38235eef00816a79daa1324387a21ef880204d`, repository searches
find no production calls to the public recording-stat query methods. The three
read requirements on `StatsStore` have database, deferred and test implementations,
but the production pipeline uses `recordSession`. External package consumers are
unknown; repository references do not establish external API safety.

The write side remains live. After a transcript saves,
`TranscriptionPipelineRunner+SideEffects.swift` records metadata through the
injected store or `StatsDatabase.shared`. `StatsDatabase.swift` updates recording
history and daily aggregates in one transaction. Replacement sessions adjust the
previous totals, including moves between days. Removing this work changes stored
behavior. The stats database is app state, separate from saved capture Markdown.

| Option | Result | Decisions needed |
|---|---|---|
| Keep the contract | Keep history, aggregates and public queries | Identify the intended consumer or retain the embedding API explicitly; correct stale dashboard comments |
| Retire aggregates only | Keep recording history and stop daily updates | Query deprecation, old-table handling and replacement/rollback behavior |
| Retire statistics entirely | Stop future writes and retire the query surface | External source compatibility and a separate retention/export/deletion policy for existing history |

Suggested first step: separate API simplification from stored-data retirement.
Unused readers in this checkout do not authorize purging history. Preserving old
tables while stopping writes is also a policy choice, not an automatic migration.

For a selected implementation, use an owned temporary database to cover new
sessions, replacement by ID/path, day changes, reopen behavior and rollback after
an injected aggregate failure. Explicitly retain or deprecate each public query.
Check the standalone package boundary and app build, and isolate the app library
for runtime verification. Never test migrations on the owner's stats database.

This worksheet changes no runtime, API, schema or stored history. No database,
app or hardware behavior was executed. The issue remains unresolved until the
owner selects the contract and its implementation and validation are complete.
Merging this document would only record the open choice.

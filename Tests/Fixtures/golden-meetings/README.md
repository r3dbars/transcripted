# Approved meeting Markdown

These are the approved copies of what Transcripted saves for a few canned
meetings, checked byte for byte by
`Tests/TranscriptedCoreTests/StorageTests/MeetingMarkdownGoldenTests.swift`.
The saved Markdown is the product (people, the MCP server and the CLI read it),
so a format change should show up here as a plain-text diff in review.

Dates and times depend on the machine's time zone and locale, so they are
stored as `{{day}}`, `{{time}}`, `{{display_date}}` and `{{imported_at}}`.

Changed the format on purpose? Regenerate, then read the diff before committing:

```bash
TRANSCRIPTED_UPDATE_GOLDENS=1 swift test --filter MeetingMarkdownGoldenTests
git diff Tests/Fixtures/golden-meetings/
```

The speakers and lines are made up. Keep new fixtures that way: no real names,
titles or transcript text.

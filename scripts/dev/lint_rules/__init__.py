"""Rules for scripts/dev/lint.py, one module per rule.

lint.py imports every module in this folder whose name doesn't start with `_`.
Each module is named after its rule id with `-` turned into `_`
(`main-actor-blocking-io` -> `main_actor_blocking_io.py`) and defines:

    RULE = {
        "id": "main-actor-blocking-io",   # kebab-case, unique
        "summary": "what is forbidden, one line",
        "why": "the past cost, one line, cite commits",
        "fix": "what to do instead; name the file/type/function to use",
        "owner_doc": "Sources/UI/AGENTS.md",
        "level": "lint",
        "paths": ["Sources/**/*.swift"],   # repo-relative globs
        "exclude": [],                      # optional
        "ratchet": True,                    # grandfather per-file counts in .agents/lint-baseline.json
        "proof": ["<bad sha>:<path>"],      # real past mistakes this rule flags
    }

    def check(path: str, text: str) -> list[tuple[int, str]]:
        ...  # (1-based line, message); an iterator of pairs is fine too

Fixtures live in `fixtures/<rule-id>/`: at least one `bad*` file (must flag)
and one `good*` file (must not). Line 1 may say
`// lint-fixture-path: Sources/UI/Foo.swift` (or `#` for non-Swift) to pick the
path the fixture is checked as; otherwise lint.py derives one from `paths`.

Shared helpers (globs, the Swift comment/string blanker, scope and actor
isolation lookups) are in `_base.py`: `from lint_rules._base import swift_file`.
How to add a rule end to end: docs/lint-rules.md.
"""

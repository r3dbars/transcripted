# Turning a correction into a rule

Every contributor to this repo is an agent that sees only the files it opened, copies the nearest example, and takes the shortest path that compiles. So a mistake that happened once will happen again, and one more sentence in `AGENTS.md` mostly doesn't stop it. This doc is how we fix a mistake class so it stays fixed. The process is adapted from pstack's `/correct` skill; the repo skill that walks an agent through it is `.claude/skills/correct/SKILL.md`.

The current rule → enforcer table is `docs/rules.md`. It's generated; don't edit it by hand.

## When something becomes a rule

A class counts once it happened twice. One slip is a slip: fix it and move on. The second time the same kind of mistake shows up (in a review, a red CI run, a revert, or the owner correcting an agent), it's a class, and it gets a rule.

"Same kind" means the same wrong move, not the same file. Two different files that both call disk I/O on the main actor are one class. Before you write anything, find both instances in git history (`git log -S`, `git log --grep`, reverts, review fixes). You need at least one of them as proof anyway.

## Pick the highest level that works

Go down this list and stop at the first level that can actually catch it:

1. **Architecture.** Make one owner and one way to do the thing, and delete the old way. If there's only one function that writes the file, nobody can write it wrong from somewhere else. Best when the mistake is "picked the wrong one of several ways".
2. **Types.** Make the bad state fail to compile: a non-optional field, an enum instead of a string, a type only the owner module can construct (and `check-module-boundaries.py` keeps others from naming it).
3. **Lint or CI check whose error names the fix.** A rule in `scripts/dev/lint.py`, or a `scripts/dev/check-*.py` script. The message must say what to do instead and point at the file, type or function to use, because the agent reading it will do exactly what it says. If the pattern is already common in the tree, ratchet it: fail only when a change adds more.
4. **Behavior test.** When the mistake is about what the code does, not how it's written. Follow "Test rules" in `Tests/README.md`; never read `Sources/` as text.
5. **Docs or agent rules, last.** Only for judgment calls a check can't make. Keep it to a line in the nearest folder `AGENTS.md`.

Often the right answer is two levels: an architecture fix plus a lint that stops the old way coming back.

## Prove it on a real past mistake

A check that has never caught anything is a guess. Every new check has to fail on a real past mistake from git history:

- Find the commit that fixed an instance. Its parent is the bad version. `git show <parent>:<path>` is the file as it was when the mistake was in it.
- For a lint rule, put `"<parent sha>:<path>"` in the rule's `proof` list. `lint.py --self-test` runs the rule on every proof and fails if one stops flagging. A shallow clone that lacks the object prints a warning instead of failing.
- For a registry check, put the sha (or `self-test` when the script's own `--self-test` replays the case) in its `proof` field, and say in your report how you ran it on that commit.
- Add fixtures too (below). Proof says it catches the real thing; fixtures say exactly where the line is.

Then run it on today's tree (`lint.py --all`). Every finding there is either a real instance (grandfather it with the ratchet, or fix it) or a false positive (tighten the rule until it's gone). Report the false-positive rate you saw.

## Ratchet for patterns that already exist

If the tree already has the pattern in many places, don't fix them all in the rule PR and don't let the rule fail on day one. Set `"ratchet": True`. `.agents/lint-baseline.json` holds `{rule_id: {path: count}}`; a file passes while its count is at or under its number. Over it, lint.py prints every finding in that file with "N new; baseline M".

- `python3 scripts/dev/lint.py --write-baseline --rule <rule-id>` records current counts for that rule only (`--rule` is required and repeatable). It refuses, writing nothing, when a rule that already has a baseline would go up; `--allow-raise` overrides that, and growing a count is a reviewed human edit, not something to do to make CI green.
- `python3 scripts/dev/lint.py --shrink` lowers counts that dropped and removes files that are gone. It never raises one. Run it after you clean some up.

## Suppressing one line

When a finding is genuinely fine, put this on the line or the line right above it:

```swift
// lint-allow(main-actor-blocking-io): reads a 40-byte pid file once at launch — expires 2027-01-31, approved r3dbars
```

Use `#` instead of `//` outside Swift; `--` works in place of the dash. Every part is required: the rule id, a reason, an expiry date no more than a year out, and the handle of the human who approved it. An agent can't approve its own suppression. The built-in rule `lint-allow-format` fails on any `lint-allow` that is malformed, names an unknown rule, is missing a part, has expired, or suppresses nothing. When one expires, fix the code or get a fresh approval.

## Adding a lint.py rule, step by step

1. **Name it.** A kebab-case id that says what's forbidden, like `main-actor-blocking-io`.
2. **Write the module.** `scripts/dev/lint_rules/<id with - turned into _>.py`. It defines a `RULE` dict and a `check(path, text)` function that returns `(line, message)` pairs. The fields:
   - `id`, `summary` (what's forbidden), `why` (the past cost, citing commits), `fix` (what to do instead, naming the file/type/function).
   - `owner_doc`: the `AGENTS.md` or doc that owns this area. It must exist.
   - `level`: `"lint"`.
   - `paths` and optional `exclude`: repo-relative globs like `Sources/**/*.swift`.
   - `ratchet`: `True` for patterns already in the tree, else `False`.
   - `proof`: one or more `"<bad sha>:<path>"` entries.

   Use the helpers in `scripts/dev/lint_rules/_base.py` (globs, the Swift comment and string blanker, scope and actor lookups) instead of raw regex over source text, so comments and strings don't trip the rule. Python 3 stdlib only; it runs on Linux CI and macOS.
3. **Add fixtures.** `scripts/dev/lint_rules/fixtures/<rule-id>/` needs at least one `bad*` file (must flag) and one `good*` file (must not). Put the near-misses in `good*`: the comment that mentions the call, the off-main version, a valid suppression. Line 1 may say `// lint-fixture-path: Sources/UI/Foo.swift` to pick the path it's checked as.
4. **Self-test.** `python3 scripts/dev/lint.py --self-test` runs the runner's own cases, every rule's fixtures and every proof.
5. **Run it on the tree.** `python3 scripts/dev/lint.py --all`. Tighten until the only findings are real. `python3 scripts/dev/lint.py --explain <rule-id>` shows what an agent will see.
6. **Baseline if it ratchets.** `python3 scripts/dev/lint.py --write-baseline --rule <rule-id>`, then check the diff in `.agents/lint-baseline.json` is only your rule.
7. **Regenerate the table.** `python3 scripts/dev/check-rule-registry.py --write` rewrites `docs/rules.md`.
8. **Run the gates.** `bash check.sh` (it picks up the lint and registry checks from `.agents/test-matrix.yml`).

## Registering a check that isn't a lint.py rule

Architecture, type, test, hook and doc rules, and every `scripts/dev/check-*.py` script, get an entry in `.agents/rules.json`:

```json
{
  "id": "file-size",
  "enforces": "no new Swift file over 800 lines; baselined ones only shrink",
  "enforcer": "python3 scripts/dev/check-file-size.py",
  "level": "lint",
  "owner_doc": "AGENTS.md",
  "why": "hotspot files kept growing until nobody could review them",
  "runs_in": ["linux-checks", "repo-hygiene CI"],
  "proof": "<sha> or self-test"
}
```

`level` is one of `architecture`, `type`, `lint`, `test`, `hook`, `doc`. lint.py rules are not repeated here; `scripts/dev/check-rule-registry.py` reads them from the modules. A check script that genuinely isn't a rule goes in the `unregistered_ok` map with a reason.

`python3 scripts/dev/check-rule-registry.py` fails when a check script has no entry, an enforcer or owner doc doesn't exist, two rules share an id, or `docs/rules.md` is stale. `--write` regenerates the table (sorted by level, then id). `--self-test` checks the checker.

## Where the checks run

The same commands run everywhere, so a rule that passes locally passes in CI:

- **While an agent edits.** `.claude/settings.json` has a PostToolUse hook on `Edit|Write|MultiEdit` that runs `python3 scripts/dev/lint.py --hook` on the edited file. New findings come back on stderr right away, so the agent fixes them in the same turn. It's well under a second and fails open on any internal error.
- **When an agent stops.** A Stop hook (`.claude/hooks/stop-lint.sh`) runs `lint.py --changed` and sends the agent back if the branch has new findings. It won't loop: when the hook is already active it lets the stop through.
- **Before a push.** `.githooks/pre-push` runs `lint.py --range <remote tip>..<local tip>` for each pushed ref (committed content only, so scratch files and uncommitted edits don't block a push) and `scripts/dev/check-rule-registry.py`. Turn it on once per clone with `bash scripts/dev/install-git-hooks.sh` (sets `core.hooksPath` to `.githooks`).
- **In CI.** `scripts/dev/linux-checks.sh` (and so the repo-hygiene job and `bash check.sh quick`) runs `lint.py --self-test`, `lint.py --all`, `check-rule-registry.py --self-test` and `scripts/dev/check-rule-registry.py`.

## How `docs/rules.md` is made

`python3 scripts/dev/check-rule-registry.py --write` builds it from `.agents/rules.json` plus each lint rule's `RULE` dict, and lists the check scripts still waiting for an entry. The first line says it's generated. CI fails if it doesn't match, so after any rule change run `--write` and commit the result.

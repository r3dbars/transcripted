---
name: correct
description: Turn a repeated mistake into a rule the repo enforces. Use when the owner corrects an agent for a mistake that has happened before ("you did this again", "stop doing X"), when a review or red CI run shows the same kind of mistake a second time, or when the owner says /correct. Mines git history for the class, picks the highest level that can stop it (architecture, types, lint, test, docs last), builds it with lint.py or .agents/rules.json, proves it on a real past commit, and keeps docs/rules.md current.
---

# Correct: fix the class, not the instance

Adapted from pstack's `/correct` skill for Transcripted's tools. The full process doc is `docs/lint-rules.md`; this is the loop.

Why it exists: every agent here sees only the files it opened, copies the nearest example, and takes the shortest path that compiles. Another sentence in `AGENTS.md` doesn't change that. A check that fails with a message naming the fix does.

## 1. Fix the instance first

Do what the owner asked on the code in front of you. Then decide whether it's a class.

## 2. Is it a class?

A class counts once it happened twice. Look for an earlier instance of the same wrong move (not the same file):

- `git log -S '<the bad call or pattern>' --oneline` and `git log -G '<regex>'`
- `git log --grep '<symptom words>' --oneline`, reverts (`git log --grep '^Revert'`), and commits titled fix/repair after a review
- `python3 scripts/dev/agent-context.py --symptom "<short description>"` to find the owner doc and existing checks
- `docs/rules.md` to see if a rule already covers it (then the rule has a hole: tighten it and add the new case as proof)

If it's truly the first time, fix it, say so, and stop. Don't write a rule from one data point.

For each instance, note the fixing commit and its parent (the bad version). You'll need at least one as proof.

## 3. Pick the highest level that works

Stop at the first one that can catch it:

1. **Architecture.** One owner, one way; delete the old way. Moving a type down or making one function the only writer beats any check.
2. **Types.** Make the bad state fail to compile. Module edges are enforced by `scripts/dev/check-module-boundaries.py`, so a type only the owner module can name is a real wall.
3. **Lint whose error names the fix.** A rule in `scripts/dev/lint_rules/`, or a `scripts/dev/check-*.py` script registered in `.agents/rules.json`. If the pattern is already common, ratchet it.
4. **Behavior test.** Per "Test rules" in `Tests/README.md`. Never a test that reads `Sources/` as text.
5. **Docs, last.** One line in the nearest folder `AGENTS.md`, only for a judgment call no check can make. Not the root `AGENTS.md` unless it applies everywhere.

Say which level you picked and why the higher ones don't work. Often it's two: fix the architecture and add a lint so the old way can't come back.

## 4. Build it

**A lint.py rule** (most corrections land here):

1. `scripts/dev/lint_rules/<rule_id_snake>.py` with `RULE` (`id`, `summary`, `why` citing the commits, `fix` naming the file/type/function to use, `owner_doc`, `level: "lint"`, `paths`, `ratchet`, `proof`) and `check(path, text)`. Use the helpers in `scripts/dev/lint_rules/_base.py` so comments and strings don't trip it.
2. `scripts/dev/lint_rules/fixtures/<rule-id>/` with `bad*` files that must flag and `good*` files that must not. Put the near-misses in `good*`.
3. Read the error as a fresh agent would. It should say exactly what to write instead. If it says only what's wrong, rewrite it.

**Anything else** (architecture, type, test, hook, doc, or a new `check-*.py`): build it, then add an entry to `.agents/rules.json` with `id`, `enforces`, `enforcer`, `level`, `owner_doc`, `why`, `runs_in` and `proof`.

## 5. Prove it on the past mistake

- lint.py: put `"<bad sha>:<path>"` in `proof`, then `python3 scripts/dev/lint.py --self-test`. It runs every fixture and every proof; your proof must flag.
- Other checks: run the check against the bad commit (`git show <sha>:<path>` into a temp tree, or the check's own `--self-test` case built from it) and show it fails. Put the sha in `proof`.
- A test: show it fails with the fix reverted, then passes.

No proof, no rule. If you can't make it fail on the real thing, the rule is guessing.

## 6. Run it on today's tree

`python3 scripts/dev/lint.py --all`. Every finding is either real or a false positive.

- False positives: tighten the rule until they're gone.
- Real and few: fix them in this change.
- Real and many: set `ratchet: True` and record counts with `python3 scripts/dev/lint.py --write-baseline --rule <rule-id>`. It touches only that rule and refuses to raise a rule that already has a baseline. Check the `.agents/lint-baseline.json` diff anyway.

If one line is genuinely fine, it gets `// lint-allow(<rule-id>): <reason> — expires YYYY-MM-DD, approved <handle>`. The approver is a human. Never approve your own.

## 7. Keep the table current and run the gates

1. `python3 scripts/dev/check-rule-registry.py --write` regenerates `docs/rules.md`.
2. `python3 scripts/dev/check-rule-registry.py` and `python3 scripts/dev/lint.py --self-test` pass.
3. `bash check.sh`.
4. If you added a doc line in step 3, keep it to one line and point at the check.

## 8. Report

Tell the owner, short:

- the class, and the two (or more) commits that show it happened before
- the level you picked and why not higher
- what enforces it now (rule id or script) and where it runs: edit hook, Stop hook, pre-push, CI
- proof: which past commit it flags
- what `--all` found on today's tree, how many were false positives, and whether you ratcheted
- anything that needs his call (a baseline bump, a suppression approval, a new `mayDependOn` grant)

Keep competitor names and real people's names out of rule text, fixtures, `why` lines and commit messages.

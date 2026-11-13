# BUILD-CI-8: duplicate workflow inventory omission

BUILD-CI-8 and DOCS-18 identify the same missing `risk-triage.yml` entry in
`.github/AGENTS.md`'s workflow table. The inventory correction is proposed in
[PR #2438](https://github.com/r3dbars/transcripted/pull/2438), at commit
`1300ee793fcee58d6bea70b81c0d424698e902aa`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. DOCS-18 remains that PR's primary report ID.

The actual one-line proposal inventories the workflow's declared Swift CI and
Repo Hygiene `workflow_run` triggers, 20-minute schedule and manual trigger.
It records the default-branch checkout, review and gate script calls, and the
separate environment/secret references for `automerge-ai` / `AI_REVIEW_API_KEY`
and `automerge-app` / `AUTOMERGE_APP_PRIVATE_KEY`. These declarations do not
establish that live secrets are configured or that the gate is deployed.

The report lists this omission under both IDs within the pending broad audit
proposal. This dedicated BUILD-CI-8 disposition records the shared scope without
adding a second inventory row or claiming another implementation. #2438 changes
only the guide's table; it does not alter workflows, permissions, runner behavior,
merge policy, secret configuration or the separate Secrets paragraph.

At verification, #2438 is an open, unmerged draft. Accepting this document alone
does not apply that correction or provide Actions, administrator, workflow-script,
app or hardware runtime proof. Review the proposed row and its validation in
#2438. No landed fix or live-key availability is claimed here.

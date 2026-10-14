# Auto-merge: steps only Justin does

Agents never run these. Until A is done, risk-gate only labels and logs; nothing auto-merges.
Order matters: **C1–C3 before merging #2199** (it adds `environment: release` to release-candidate.yml; without the environment and its secrets, release candidates fail). Then A (the App must have posted `risk-gate` once), then B: the bot gets write access only after the ruleset requires `risk-gate` (N1).

## C. Release environment for the 6 Apple/Sparkle secrets (about 20 min) — before merging #2199
Secrets, all repo-wide today: APPLE_APP_PASSWORD, APPLE_ID, APPLE_TEAM_ID, DEVELOPER_ID_CERT, DEVELOPER_ID_PASSWORD, SPARKLE_PRIVATE_KEY.
1. Create `release`, deployable from `main` only, with you as **mandatory** reviewer (S5, S9):
   ```
   ME=$(gh api user -q .id)
   gh api -X PUT repos/r3dbars/transcripted/environments/release --input - <<JSON
   {"reviewers":[{"type":"User","id":$ME}],"prevent_self_review":false,
    "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
   JSON
   gh api -X POST repos/r3dbars/transcripted/environments/release/deployment-branch-policies -f name=main -f type=branch
   ```
   The reviewer gate only means something after B (today every agent can approve as you).
2. For each secret: `gh secret set NAME -R r3dbars/transcripted --env release` with the original value (repo secrets can't be read back; use your source copies).
3. Merge #2199 (high risk, by hand).
4. Dispatch RCs from main (the env policy checks the workflow ref, S6):
   `gh workflow run release-candidate.yml -R r3dbars/transcripted --ref main -f source_ref=<prep branch>`, approve the deployment.
5. Once an RC is green: `gh secret delete NAME -R r3dbars/transcripted` for each of the 6 repo-level copies.

## A. Create the gate App (about 30 min)
1. github.com/settings/apps/new: name `transcripted-gate`, homepage the repo URL, webhook off.
2. Repository permissions: Checks read/write, Pull requests read/write, Contents read/write (needed to arm squash auto-merge), Metadata read. Nothing else. A leaked key = push access, so the key lives only in `automerge-app` (S8).
3. "Only on this account". Create, Generate a private key, install on `r3dbars/transcripted` only.
4. Two main-only environments (custom policy `main`, as in C1 without reviewers):
   - `automerge-ai`: `gh secret set AI_REVIEW_API_KEY -R r3dbars/transcripted --env automerge-ai`
   - `automerge-app`: `gh secret set AUTOMERGE_APP_PRIVATE_KEY -R r3dbars/transcripted --env automerge-app < transcripted-gate.pem`
     and `gh variable set AUTOMERGE_ENABLED -R r3dbars/transcripted --env automerge-app -b signal-only`
   - `gh variable set AUTOMERGE_APP_ID -R r3dbars/transcripted -b <app id>`
5. Delete the downloaded .pem. **Never** put it on an agent box or Mac (S7).
6. Labels: `for l in risk:low risk:medium risk:high automerge:off; do gh label create "$l" -R r3dbars/transcripted; done`
7. Watch a few PRs in `signal-only` until the App has posted `risk-gate` at least once (GitHub only offers it as a pinned source after that, S3). B4 then requires it.
8. **Only after #2201 lands** (Sparkle feed off main, keychain/build-sign split, MCP publish gated), and only when you choose: `gh api -X PATCH repos/r3dbars/transcripted -F allow_auto_merge=true` and `gh variable set AUTOMERGE_ENABLED -R r3dbars/transcripted --env automerge-app -b true`.

## B. No agent merges as you (after A7)
Agents use your `gh` login, so today "only r3dbars can merge" means every agent can.
1. The lane auto-merger (`scripts/ops/auto-merge-gate.py --apply`) isn't scheduled anywhere as of 2026-10-10 (see docs/auto-merge-gate.md). If you schedule it again, run it as the bot login under the App-gated flow, never as r3dbars. It refuses to merge without GATE_TOKEN anyway.
2. Merge rules first (S1, N1, N2): replace classic protection with a ruleset on `main`. All three required checks are **pinned**: `build-and-test` and `repo-hygiene` to GitHub Actions (integration_id 15368, as classic protection pins them today) and `risk-gate` to the gate App. The only bypass is Repository admin, for **pull requests only** (`bypass_mode: pull_request`), so nobody pushes straight to main. Required approvals **0** (S2), conversation resolution on.
   ```
   APP_ID=<transcripted-gate app id>
   gh api -X POST repos/r3dbars/transcripted/rulesets --input - <<JSON
   {"name":"main","target":"branch","enforcement":"active",
    "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
    "bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}],
    "rules":[{"type":"deletion"},{"type":"non_fast_forward"},
     {"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":true,
       "require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":true}},
     {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,
       "required_status_checks":[{"context":"build-and-test","integration_id":15368},
                                 {"context":"repo-hygiene","integration_id":15368},
                                 {"context":"risk-gate","integration_id":$APP_ID}]}}]}
   JSON
   ```
3. Verify the bypass really is the admin role (N3) before deleting classic protection:
   `gh api repos/r3dbars/transcripted/rulesets/<ruleset id> -q '.bypass_actors, .current_user_can_bypass'` should show `actor_id 5, RepositoryRole, pull_request` and `pull_requests_only`. Also open Settings → Rules → main and check the bypass list reads "Repository admin". If not, fix it in the UI (Bypass list → Add bypass → Repository admin → "For pull requests only").
   Then: `gh api -X DELETE repos/r3dbars/transcripted/branches/main/protection`.
   You merge high-risk PRs (risk-gate = failure) with the admin bypass. Do **not** keep classic `enforce_admins` alongside a required failing check: that locks you out.
4. Now create the bot account (e.g. `r3dbars-agents`) and invite it as a collaborator. Personal repos grant every collaborator write; you stay the only admin, so the Repository-admin bypass is effectively you-only (S4).
5. On every box/Mac that runs agents: `gh auth login` as that account; revoke your PATs/tokens there (`gh auth status`, github.com/settings/tokens). Until this is done everywhere, agents are still admin.
6. Why 0 approvals is safe (S2): low/medium trust comes from the App-pinned `risk-gate` plus the identity split; high never auto-merges. Bot self-approval can't happen (GitHub never lets an author approve its own PR, and Actions may not approve: `can_approve_pull_request_reviews=false`, already set). The bot has no bypass.
7. Tags (S7, N4): add a tag ruleset protecting `v*` (no create/update/delete except Repository admin). Note that `publish-mcp-registry.yml` runs on `release` events and `workflow_dispatch`, not tag pushes, so the tag ruleset alone doesn't gate it; gating it (an `environment: release` on the job, or dropping `workflow_dispatch`) is tracked in #2201.

## Follow-ups (not in #2199)
Tracked in #2201: signed/off-main Sparkle feed, release keychain hardening (`-T /usr/bin/codesign` instead of `-A`, shorter lock timeout, split build from sign), gating `publish-mcp-registry.yml`.

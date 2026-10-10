# Auto-merge: steps only Justin does

Agents never run these. Until A is done, risk-gate only labels and logs; nothing auto-merges.

## A. Create the gate App (about 30 min)
1. github.com/settings/apps/new: name `transcripted-gate`, homepage the repo URL, webhook off.
2. Repository permissions: Checks read/write, Contents read/write (arming squash auto-merge), Pull requests read/write, Metadata read. Nothing else.
3. "Only on this account". Create, then Generate a private key (.pem download).
4. Install it on `r3dbars/transcripted` only.
5. Main-only environment holding its key:
   gh api -X PUT repos/r3dbars/transcripted/environments/automerge-app -F 'deployment_branch_policy[protected_branches]=true' -F 'deployment_branch_policy[custom_branch_policies]=false'
   gh secret set AUTOMERGE_APP_PRIVATE_KEY -R r3dbars/transcripted --env automerge-app < transcripted-gate.pem
   gh variable set AUTOMERGE_APP_ID -R r3dbars/transcripted -b <app id>
   gh secret set AI_REVIEW_API_KEY -R r3dbars/transcripted --env automerge-app
   gh variable set AUTOMERGE_ENABLED -R r3dbars/transcripted --env automerge-app -b signal-only
6. Watch a few PRs in `signal-only`. Then, only when you choose: `allow_auto_merge=true`, `AUTOMERGE_ENABLED=true`, and require the `risk-gate` check **pinned to the App** (branch protection "expected source" = transcripted-gate). High risk concludes failure, so you merge those as admin by hand.
7. Delete the downloaded .pem.

## B. No agent merges as you
Agents use your `gh` login, so "only r3dbars can merge" means every agent can.
1. Create a separate account (e.g. `r3dbars-agents`), add as collaborator with **Write** (not Admin/Maintain).
2. On every box/Mac that runs agents: `gh auth login` as that account; revoke your PATs/tokens there (`gh auth status`, github.com/settings/tokens).
3. Branch protection: required approving reviews 1 (kept by dismiss_stale_reviews=true, already on). Agent PRs are then authored by the bot, so your approval counts and the bot can't self-approve. Keep enforce_admins on; you merge high risk by toggling or via a ruleset whose only bypass actor is you.
4. The lane auto-merger (scripts/ops/auto-merge-gate.py --apply) isn't scheduled anywhere as of 2026-10-10 (see docs/auto-merge-gate.md). If you schedule it again, run it as the bot login under the App-gated flow, never as r3dbars. It refuses to merge without GATE_TOKEN anyway.

## C. Move the 6 Apple/Sparkle secrets into a main-only `release` environment (about 20 min)
Secrets: APPLE_APP_PASSWORD, APPLE_ID, APPLE_TEAM_ID, DEVELOPER_ID_CERT, DEVELOPER_ID_PASSWORD, SPARKLE_PRIVATE_KEY (all repo-wide today).
1. gh api -X PUT repos/r3dbars/transcripted/environments/release -F 'deployment_branch_policy[protected_branches]=true' -F 'deployment_branch_policy[custom_branch_policies]=false'
   (optionally add yourself as required reviewer on the environment).
2. For each secret: `gh secret set NAME -R r3dbars/transcripted --env release` with the original value (repo secrets can't be read back; use your source copies).
3. Merge a PR adding `environment: release` to the signing/notarize/appcast jobs in release-candidate.yml (high risk, you merge).
4. Run a release candidate; once green, `gh secret delete NAME -R r3dbars/transcripted` for each of the 6 repo-level copies.

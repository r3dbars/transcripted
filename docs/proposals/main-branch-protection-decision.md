# Main branch protection: owner decision

Status: unselected proposal for REVIEW.md item DOCS-15. No repository setting,
credential, protection rule, merge permission, or agent workflow is changed.

## The conflicting instructions

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

The root `AGENTS.md` records an owner decision dated 2026-10-17 to let work for
Justin land directly on main through the owner's admin account, after fetching,
rebasing, checks, and independent review for meaningful code. It keeps outside
contributors on pull requests and requires releases to use a green Swift CI
commit. The current audit has a separate explicit owner request for individual
PRs; this worksheet does not change that request or authorize direct pushes.

In contrast, `docs/automerge-justin-setup.md` section B2 proposes a main ruleset
whose admin bypass is limited to pull requests and says nobody pushes straight
to main. Section B3's verification repeats that choice, then proposes deleting
classic branch protection. Those instructions would conflict with the root's
direct-push workflow if followed as written.

That setup document also proposes moving agents to a separate bot identity.
Using the owner's credentials does not distinguish the human owner from an
agent using that account. Any design that relies on that distinction needs an
actual credential and actor separation plan.

These are checked-in instructions. No live repository ruleset, effective bypass
permission, credential, secret, release environment, or account configuration
was inspected or changed for this proposal. Do not infer that either documented
configuration is currently installed.

## Choose the intended access policy

All options are unselected; the owner may revise them.

- [ ] A. Keep the recorded owner direct-push exception. Specify the intended
      actor and credentials, preserve contributor and bot restrictions, and
      revise B2 and B3 together only after validating a compatible ruleset.
      Do not replace the pull-request-only bypass with a broad exception on
      the assumption that it identifies only the human owner.
- [ ] B. Require pull requests for the owner as well. Explicitly supersede the
      root's earlier decision, update the agent workflow and setup instructions
      together, and specify emergency recovery and high-risk review behavior.
- [ ] C. Defer a protection migration pending an audit of effective settings
      and identities. Mark the conflicting setup recipe as awaiting a decision
      and document how work proceeds under the existing configuration.

Before applying any selected design, review the exact rule changes, required
check sources, allowed actors, credential separation, recovery route, and rollback
plan. Verify the intended owner, bot, and contributor behavior without assuming
that a role name proves who is using its credentials. Preserve protection against
branch deletion and force pushes and keep release approval a separate boundary.

Do not delete classic protection until the replacement is reviewed and its
effective behavior is verified. Editing a setup document is not evidence that
GitHub settings changed or that a bypass works.

This worksheet does not resolve DOCS-15 or select an access policy. Owner choice
and migration conditions: pending.

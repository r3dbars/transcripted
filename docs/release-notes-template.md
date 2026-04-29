# Release Notes Template

Use this when drafting the next Transcripted release note from `main` after the
latest shipped tag.

Keep it short. Focus on what a user would notice or care about.

## Candidate summary

- One sentence on what this candidate is trying to improve.
- Call out the version gap plainly if `Info.plist` and GitHub Releases still match.

## User-visible changes

- New UI surfaces or workflow changes.
- Better update/install behavior users may notice.
- Search or agent-connect improvements people can actually use.

## Reliability and ops changes

- Crash, freeze, audio, or data-safety fixes.
- Privacy or logging hardening that protects real usage.
- Keep this in normal language, not Sentry shorthand.

## Known caveats

- Things that still need manual QA.
- Things that are better but not fully proven yet.
- Anything that is still docs-only and should not be oversold.

## Good reason to ship or wait

- Ship when the user-facing value is clear and the reliability fixes match live pain.
- Wait when the branch is mostly internal cleanup, docs sync, or automation work.

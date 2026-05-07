# Release Notes Template

Use this when drafting the next Transcripted release note from `main` after the
latest shipped tag.

Keep it short. Focus on what a user would notice or care about.

## Candidate summary

- One sentence on what this candidate is trying to improve.
- If `Info.plist`, GitHub Releases, Sparkle, and Homebrew already match and there is no meaningful merged work after that release, say plainly that there is no new candidate tonight.
- If `HEAD` is ahead of the latest shipped tag but `Info.plist` and GitHub Releases still match, say plainly that this is post-release `main` work and not a versioned candidate yet.
- Say whether Sparkle and Homebrew already point at this version, or still lag.

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
- Say plainly if this is not a real release candidate yet and is only release metadata or install-path follow-up.

## Good reason to ship or wait

- Ship when the user-facing value is clear and the reliability fixes match live pain.
- Wait when the branch is mostly internal cleanup, docs sync, or automation work.
- Wait when the latest version already shipped and there is nothing new for users yet.

Commit and push to GitHub using the r3dbars account.

Steps:
1. On Justin's Mac, run `gh auth switch --user r3dbars` to make sure the active GitHub account is r3dbars. Skip this in cloud sessions, where `gh` isn't used and pushes already go out as the connected account.
2. Run `git status` to see what's changed
3. Run `git diff` to review the changes
4. Run `git log --oneline -3` to see recent commit message style
5. Stage the relevant changed files (NOT untracked files unless they're clearly part of the work)
6. Write a clear, concise commit message summarizing the changes
7. Follow the owner's commit-credit rule in `AGENTS.md`: verify the commit author and committer are `r3dbars <r3dbars@users.noreply.github.com>`, and do not add an AI `Co-authored-by` trailer. If the cloud platform forces bot authorship, report that before committing.
8. Push to origin

Git config for this repo is already set:
- user.name: r3dbars
- user.email: r3dbars@users.noreply.github.com

On the Mac, confirm the auth switch succeeded before pushing.

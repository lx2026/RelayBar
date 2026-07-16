# Repository instructions

## Git workflow

- Work on the currently checked-out branch.
- Do not create or switch branches unless the user explicitly requests it.
- Do not open pull requests unless the user explicitly requests one.
- When asked to commit and push, commit directly to the current branch.
- If the current branch is protected or cannot be pushed, stop and report the blocker.
- Before editing, verify that the local branch is synchronized with its remote.
- After a pull request is merged, switch to `main` and update it with `git pull --ff-only`.
- Never force-push `main`.

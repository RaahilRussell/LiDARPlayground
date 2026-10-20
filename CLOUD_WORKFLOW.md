# Claude Cloud and Xcode workflow

Repository: https://github.com/RaahilRussell/LiDARPlayground (private).
Local project: `/Users/raahil/Desktop/test/test.xcodeproj`.

## Start a task

Save files in Xcode first. Review local changes, commit only intended files,
and push the branch before asking the cloud to work on it:

```sh
cd /Users/raahil/Desktop/test
git status --short
git diff
# If needed: git add <specific-files> && git commit -m "Describe your changes"
git push
claude --cloud "Implement YOUR TASK on a separate claude/ branch. Read CLAUDE.md. Commit and push the result; report checks run."
```

The command prints a session URL. Open it at https://claude.ai/code to monitor
or steer the task. A cloud session runs on Anthropic infrastructure and can
continue when the Mac is off, subject to usage limits and session availability.
Local Claude sessions and Remote Control need the Mac running.

## Review without disturbing your Xcode checkout

After Claude pushes its branch, fetch and list branches:

```sh
cd /Users/raahil/Desktop/test
git fetch origin
git branch -r
```

Replace `claude/ACTUAL-BRANCH` below with the branch shown by Claude. A separate
worktree lets you inspect the result while keeping your current edits intact:

```sh
git diff main...origin/claude/ACTUAL-BRANCH
git worktree add ../LiDARPlayground-review --track -b review/cloud origin/claude/ACTUAL-BRANCH
open ../LiDARPlayground-review/test.xcodeproj
```

Use a new directory and local branch name for each additional review. Build in
Xcode and test LiDAR/haptics on a supported physical device. Review and merge
through a GitHub pull request. After merge, with local main clean:

```sh
cd /Users/raahil/Desktop/test
git switch main
git pull --ff-only
open test.xcodeproj
```

If Git reports local changes or a conflict, stop and commit your intended work
on its own branch before proceeding. Do not use reset --hard or force-push.

## Resume the conversation locally

From a clean checkout of this repository, signed in to the same Claude account:

```sh
cd /Users/raahil/Desktop/test
claude --teleport SESSION_ID
```

Replace SESSION_ID with the cloud session ID. Teleport fetches/checks out the
pushed cloud branch and loads its conversation. It requires that branch to be
available remotely. Further execution is local and needs your Mac running.
Use the separate-worktree workflow above when preserving an active checkout.

## Setup verification

- GitHub private repository created and main pushed.
- GitHub and Claude CLI were already authenticated; CLI version 2.1.296 supports
  --cloud and --teleport.
- Claude repository status confirms cloud sessions can work in this repository.
- Local unsigned Debug iOS build succeeded during setup.
- Cloud smoke-test session: https://claude.ai/code/session_01Ekg2REMY57Db4kUnd9AbBp
- Cloud session inspected the project and pushed documentation-only commit
  `53355e2` to `claude/cloud-setup-smoke-test`.
- `claude --teleport session_01Ekg2REMY57Db4kUnd9AbBp` successfully fetched and
  checked out that branch and resumed the conversation locally.
- The cloud-created `docs/cloud-smoke-test.md` was opened and verified in Xcode.
- Setup returned the main checkout to main. The smoke-test file remains only on
  the separate test branch. No app source was changed during setup.
- A usage-limit banner appeared during the test, but the task completed anyway.
  Check your plan and credit settings if future tasks pause; setup did not
  enable or change paid extra usage.

Official reference: https://code.claude.com/docs/en/claude-code-on-the-web

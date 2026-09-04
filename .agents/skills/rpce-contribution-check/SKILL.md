---
name: rpce-contribution-check
description: Validate Agentry contributions before committing or pushing. Use whenever an agent is about to create a commit, push the current branch, rewrite history, delete a branch or fork, or change GitHub-visible repository state. Enforces staged-index and outgoing-range secret scanning, repository guardrails, clean push boundaries, and explicit approval for destructive Git or visible live-app operations.
---

# Agentry Contribution Check

Run the repository-local safety preflight before every commit and push. Read `AGENTS.md` first. Lint, tests, and builds are explicit commands — not part of this gate.

## Before committing

1. Review `git status --short` and inspect the intended diff.
2. Stage only intended files. Review `git diff --cached --stat` and `git diff --cached`.
3. Run:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh commit
```

4. Rerun commit preflight after any staging change, including partial-staging updates. Commit mode scans materialized staged index blobs, not merely working-tree copies.
5. Keep secret values redacted in terminal output and summaries.

## Before pushing

1. Ensure the working tree is clean.
2. Run:

```bash
.agents/skills/rpce-contribution-check/scripts/preflight.sh push
```

`pr-ready` is a synonym for `push`.

3. Review the computed current-branch outgoing range printed by the script.
4. Run any focused checks the change actually needs (`make dev-test`, `make dev-lint`, `make xcode-generator-test`). See [references/validation-matrix.md](references/validation-matrix.md).
5. Push only the intended current branch.

Push mode is whitespace, staged-index secrets, guardrails, a clean working tree, the current-branch outgoing range, and outgoing-range secrets. It does not run lint, test, or product-build lanes.

Push mode validates only the current branch against its configured upstream. For a non-`main` topic branch without a configured upstream, it may use `origin/main` as an explicit comparison fallback. It does not validate tags, `--all`, `--mirror`, or arbitrary refspecs.

## Escalate before destructive operations

Obtain explicit user approval immediately before force-push, history rewrite, branch deletion, fork deletion, credential rotation, any other GitHub-visible destructive mutation, visible app launch/relaunch, or stopping a visible app. Do not bundle approval for a future destructive step into an earlier request.

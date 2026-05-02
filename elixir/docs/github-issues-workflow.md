# GitHub Issues Workflow

Use this fork's GitHub Issues workflow when you want Symphony to pick up work from GitHub instead of Linear.

## Create a ready issue

Create the issue with the `codex:ready` label so Symphony treats it as actionable:

```bash
gh issue create \
  --repo OWNER/REPO \
  --title "Short, task-shaped title" \
  --body "What should change and how to verify it." \
  --label codex:ready
```

If the repo does not have the workflow labels yet, create or refresh them first:

```bash
GITHUB_REPOSITORY=OWNER/REPO ./scripts/symphony-github-setup
```

## Watch the dashboard

Run Symphony locally, then watch progress in the dashboard at:

```text
http://127.0.0.1:4040/
```

Keep that page open while the issue moves through the workflow.

## Label meanings

- `codex:ready` - ready for Symphony to start.
- `codex:running` - currently being handled.
- `codex:rework` - blocked or needs follow-up before completion.
- `codex:done` - finished and ready to close.

## Typical flow

1. Create the issue with `codex:ready`.
2. Symphony moves it to `codex:running`.
3. If work is blocked, it moves to `codex:rework`.
4. When validation passes, it moves to `codex:done`.

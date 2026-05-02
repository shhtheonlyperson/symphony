---
tracker:
  kind: github
  repo: $GITHUB_REPOSITORY
  api_key: $GITHUB_TOKEN
  active_states:
    - codex:ready
    - codex:running
    - codex:rework
  terminal_states:
    - codex:done
    - Closed
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    : "${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY=OWNER/REPO}"
    git clone "git@github.com:${GITHUB_REPOSITORY}.git" .
agent:
  max_concurrent_agents: 2
  max_turns: 10
codex:
  command: codex app-server -c model=\"gpt-5.4-mini\" -c model_reasoning_effort=\"medium\"
  approval_policy: never
  thread_sandbox: workspace-write
---

You are working on a GitHub issue tracked by Symphony.

Issue: {{ issue.identifier }}
Title: {{ issue.title }}
Current state label: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. Treat this GitHub issue as the task source of truth.
2. Work only in the provided repository copy.
3. Move the issue from `codex:ready` to `codex:running` before implementation.
4. Create a branch, make focused changes, run validation, and open a PR that links the issue.
5. Comment on the issue with the PR URL and validation evidence.
6. If blocked by missing auth, secrets, or ambiguous acceptance criteria, comment with the exact blocker and move the issue to `codex:rework`.
7. When implementation and validation are complete, move the issue to `codex:done`.

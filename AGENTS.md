# AGENTS.md

## Project

Symphony turns tracker issues into isolated agent implementation runs. Treat this repository as an experimental reference implementation, not a hardened production orchestrator.

The active implementation is under `elixir/`.

## Repo And Remote Safety

- This checkout may track the OpenAI upstream while pushing to a personal fork.
- Check the current branch and remote before publishing.
- Do not land broad changes to upstream by accident.

## Elixir Workflow

Use `mise` for Elixir/Erlang versions:

```bash
cd elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- mix test
mise exec -- mix lint
```

Run the service with:

```bash
cd elixir
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Agent Workflow Notes

- Symphony creates a workspace per issue and launches Codex in App Server mode.
- `WORKFLOW.md` is the project-specific contract; update it deliberately.
- Keep issue state transitions explicit and auditable.
- Do not assume Linear-only behavior; GitHub Issues mode exists too.

# Workspaces — registry

Active workspaces in this hub. The pattern itself is documented in [`CLAUDE.md`](CLAUDE.md).

## Active workspaces

| Slug | What it is | `CLAUDE.md` | Own AgentOS instance |
|------|------------|-------------|----------------------|
| _(none yet)_ | _Add a workspace by following the steps in `CLAUDE.md`_ | — | — |

<!--
Example row once you add one:

| acme   | Acme Inc. SaaS — main product           | [`acme/CLAUDE.md`](acme/CLAUDE.md)   | No                                                                      |
| client | Client engagement (closure-mode)        | [`client/CLAUDE.md`](client/CLAUDE.md) | No                                                                      |
| product | Your product workspace                 | [`product/CLAUDE.md`](product/CLAUDE.md) | Yes — submodule `product/claude` (`<org>/claude`)                  |
-->

## Cross-workspace infrastructure

These services run **once per machine** and are shared by every workspace and every hub-level agent. They are not duplicated per workspace:

- **saga-mcp** (`localhost:3851`) — task tracker. Project `id=1` is the AgentOS project; epics 1-5 cover the canonical task buckets.
- **telegram-mcp** (`localhost:3848`) — Telegram bot bridge (operator receives push from here).
- **claude-peers broker** (`localhost:7899`) — inter-agent messaging on this machine + cross-host bridge.
- **`memory/` at the hub root** — shared memory (people, decisions, schedule).

Port and service detail: [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

## How agents use this registry

1. **Operator** receives a Telegram message → identifies the workspace from the chat or content.
2. Reads `workspaces/<slug>/CLAUDE.md` for context.
3. If code work is needed — `cd workspaces/<slug>/<repo>/` (inside the submodule) and works there.
4. Delegates to a subagent with `cwd` inside the submodule (or a worktree).
5. Updates the workspace's `CLAUDE.md` if needed, then commits + pushes.

## Adding a new workspace

Algorithm in [`CLAUDE.md`](CLAUDE.md). Short version:

1. `mkdir workspaces/<slug>`
2. Create `<slug>/CLAUDE.md`
3. Add a row to this `MAP.md`
4. `git submodule add <ssh-url>` for each code repo, if any
5. Commit + push

## Archived / abandoned

Old experiments, dead forks, one-off scratch dirs — keep them out of `workspaces/`. Either drop them or move to a separate archive folder so the registry stays meaningful.

# Workspaces — pattern

Each folder under `workspaces/<slug>/` is a separate workspace (a business, a product, a client, a personal track). The hub knows about them, but doesn't reach inside without a reason.

## Workspace structure

```
workspaces/<slug>/
├── CLAUDE.md              # context: what this is, which repos, current state, what matters
├── <repo>/                # git submodule pointing at project code
├── <another-repo>/        # another submodule if there are several
├── claude/                # OPTIONAL: submodule pointing at this workspace's own AgentOS instance
│   ├── agents/
│   ├── memory/
│   └── ...
├── notes/                 # OPTIONAL: running notes
├── decisions/             # OPTIONAL: decision log
└── workspaces/            # OPTIONAL: fractal nesting if the workspace itself has sub-projects
```

Minimum is just `CLAUDE.md`. Everything else gets added on demand.

## Workspace `CLAUDE.md`

Documents the workspace for any agent working inside it. It should cover:

1. **What this is** — one-liner naming the project, its status (active / paused / maintenance), and the stakeholders.
2. **Repos** — which submodules are wired up, what each contains, their remote URLs.
3. **Current state** — what matters right now, open tasks, conflicts, deadlines.
4. **Telegram chats** — `chat_id`s of key project chats (if any).
5. **Saga epics** — which `saga-mcp` epics are tied to this workspace.
6. **External links** — Linear, Notion, GitHub org, Slack, Drive.
7. **Working norms** — what not to do, who not to ping, publication rules.

## Adding a submodule

```bash
cd <hub-root>
git submodule add <ssh-url> workspaces/<slug>/<repo-name>
git commit -m "workspaces/<slug>: add <repo-name> submodule"
git push
```

A submodule does not copy the code into the hub repo — it stores a pointer (URL + commit SHA). Local work happens through plain `git` inside the submodule folder.

## Delegating subagents into a submodule

When a hub-level agent delegates work into a specific workspace or submodule, the subagent is started with `cwd` inside the submodule:

```
Agent({
  description: "Implement feature X in <workspace>/<repo>",
  cwd: "<hub-root>/workspaces/<workspace>/<repo>",
  prompt: "..."
})
```

The subagent only sees the submodule (its `CLAUDE.md`, its files, its `.git`) and has no access to the hub level unless `--add-dir` is passed explicitly. This is the isolation rule: a workspace agent does not reach into siblings.

## Worktrees — parallel work

When you need to work on several features in the same repo simultaneously, create a worktree:

```bash
cd <hub-root>/workspaces/<slug>/<repo>
git worktree add ../../../.worktrees/<slug>-<repo>-feature-x -b feature/x
```

Subagents start with `cwd` inside the worktree folder. Several subagents can work in parallel without index conflicts.

Worktree pool: `.worktrees/` at the hub root, naming convention `<slug>-<repo>-<branch>`.

## When a workspace grows into its own AgentOS

If a workspace starts to need its own agents / heartbeat / operator (e.g. the business is large enough, or a client wants their own agent on the team), add a `claude/` submodule:

```bash
git submodule add git@github.com:<org>/claude.git workspaces/<slug>/claude
```

That submodule is a separate repo with its own full AgentOS install (the template can be copied from upstream `try-agent-os/claude-code-template`). It runs autonomously, can be deployed to its own host, and federates with the hub via the `claude-peers` SSH bridge.

The hub keeps knowing about it through the workspace's `CLAUDE.md`, but doesn't manage it directly.

## Adding a new workspace

1. `mkdir workspaces/<slug>`
2. Create `workspaces/<slug>/CLAUDE.md` (use existing workspaces as a template).
3. Add an entry to `workspaces/MAP.md` (one line linking to the `CLAUDE.md` plus a short description).
4. If there's code, run `git submodule add` for each repo.
5. Commit + push.

## What not to do

- **Don't duplicate submodule contents into the hub.** The hub holds pointers + context; the code lives in the submodule.
- **Don't reach from a workspace agent into the hub** without an explicit task. Workspace agents are isolated.
- **Don't mix workspaces.** If work spans two projects, delegate from the hub level once per workspace, sequentially.
- **Don't create a workspace for one-off notes.** Use `memory/` or a `research/` folder instead.

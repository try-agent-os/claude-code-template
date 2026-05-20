---
name: tmux-session-management
description: Manage long-lived tmux sessions (usually with `claude` CLI inside) — spawn, send commands, read output, kill. Use when the user asks to start/inspect/talk-to/kill a named session. Implementation: `scripts/tmux-session/*.sh`.
---

# tmux session management

The user typically controls AgentOS through Telegram (often by voice) and never opens a terminal. This skill is the bridge between user intent and the `scripts/tmux-session/*.sh` scripts: spawn a long-running `claude` session in a workspace, send it work, read its output, kill it when done.

## When to invoke

| User intent | Action |
|-------------|--------|
| "start a worker on `<slug>`" / "spin up claude in `<slug>`" | `create.sh worker-<slug> --workspace <slug>` |
| "open an empty session `<name>`" (no claude) | `create.sh <name> --cwd <path>` |
| "what's going on in `<name>`" / "show output of `<name>`" | `read.sh <name>` |
| "send `<message>` to `<name>`" / "`<slug>`, look at `<X>`" | `exec.sh worker-<slug> "<message>"` then (after 5-15s) `read.sh worker-<slug>` |
| "what workers are running" / "show sessions" | `list.sh --filter worker-` |
| "kill `<name>`" / "stop `<slug>`" | `kill.sh <name>` (or `--force` if hung) |

If the user addresses a slug directly ("`<slug>`, check X") — that's an implicit address to the existing `worker-<slug>` session. Run `list.sh --filter worker-` first to confirm it exists; if not, ask whether to spawn it. Don't invent a session.

## Naming conventions

- **Worker for a workspace**: `worker-<slug>` (e.g. `worker-acme`, `worker-novostudio`).
- **Ad-hoc sessions**: whatever the user said, sanitized to `[A-Za-z0-9._-]+`.
- **Reserved (create/kill refuse)**: `operator`, `sysadmin`, `dispatcher`, `claude-login`. Those are systemd/launchd-managed; never touch them with this skill.

## Intent → script mapping

All scripts are called with absolute paths via the Bash tool. No `cd`.

### Spawn a worker on a workspace

```bash
/opt/agent-os/claude/scripts/tmux-session/create.sh worker-acme --workspace acme
```

What happens:
- A session `worker-acme` is created with `cwd = workspaces/acme/claude/` if that exists, else `workspaces/acme/`.
- `claude --dangerously-skip-permissions --model 'claude-opus-4-7[1m]'` is launched inside (1M-context Opus 4.7 by default; without an explicit `--model` the CLI silently defaults to a smaller Sonnet model).
- A primer message is sent automatically: *"Context: you are a worker session for workspace 'acme'. Cwd: ... Read CLAUDE.md before acting. Awaiting task."* The worker reads `CLAUDE.md` and is then ready for work.
- **First-time trust dialog**: when claude starts in a new cwd it asks "Is this a project you trust? Yes/No". That prompt does NOT submit via `C-m` — it expects a bare `Enter`. After spawning, wait ~10s, call `read.sh`, and if you see "Yes, I trust this folder" send a raw `tmux send-keys -t <session> Enter` (not C-m).

### Spawn an empty session (no claude)

```bash
/opt/agent-os/claude/scripts/tmux-session/create.sh deploy-runner --cwd /opt/agent-os/claude
```

Opens a plain login shell in the given directory. Use for one-off long-running commands (`pnpm dev`, `tail -f`, etc.).

### Send a message

```bash
/opt/agent-os/claude/scripts/tmux-session/exec.sh worker-acme "Read src/auth/AuthGuard.ts and summarise the key invariants."
```

What happens:
- Text is sent via `tmux send-keys -l` (literal — no key-binding interpretation).
- Submit is `C-m`. (Inside the claude TUI a bare `Enter` only prints the text; only `C-m` actually submits.)
- Returns immediately without waiting for a response.

### Read the output

```bash
/opt/agent-os/claude/scripts/tmux-session/read.sh worker-acme --lines 60
```

Returns the last N lines of the pane (default 100). For a claude TUI it usually makes sense to sleep 5-30s after `exec.sh` (depending on the prompt's complexity) before reading.

**Standard exec → read pattern:**
```bash
exec.sh worker-acme "What's in README.md?"
sleep 10
read.sh worker-acme --lines 50
```

If you still see a working indicator (`Cooked for Xs`, `⏺`) — wait longer and re-read. Don't poll in a tight loop.

### List sessions

```bash
/opt/agent-os/claude/scripts/tmux-session/list.sh --filter worker-
```

Returns one JSON object per line: `{name, created (unix), last_activity (unix), attached, pid, running_command}`. Without `--filter` it lists everything including `operator`/`sysadmin` — usually you want the `worker-` prefix only.

### Kill a session

```bash
/opt/agent-os/claude/scripts/tmux-session/kill.sh worker-acme
```

Default: two `C-c` interrupts, wait 2s, then `kill-session`. For hung sessions: `--force` (skip interrupts).

## Safety rules

1. **Never kill `operator` / `sysadmin` / `dispatcher` / `claude-login`.** `kill.sh` refuses, but don't go around it with raw `tmux kill-session` either — these are systemd/launchd-managed.
2. **Don't spawn claude inside claude.** If you yourself are already running inside a claude TUI (as operator) — do NOT call `create.sh ... --claude` with `--cwd` equal to your own cwd. That nests claude sessions, scrambles OAuth state, and burns tokens. Workers always live in a separate workspace directory.
3. **Concurrent worker cap = 5.** Before `create.sh`, run `list.sh --filter worker-` and count. If already at 5+, ask the user which one to kill before spawning a new one.
4. **Don't forward raw pane output to Telegram.** `read.sh` can return 100+ lines of ANSI/TUI noise. Parse what's relevant (`grep ●` for claude reply markers, or take the block after the last `❯`), and send a short summary plus "full output in `worker-<slug>`".
5. **Activity logging is automatic.** Every `create`/`exec`/`kill` writes to `memory/worker-activity.log` via `log_activity` in `_common.sh`. Don't duplicate the log lines by hand.
6. **Long message guard.** `exec.sh` refuses messages over 50000 chars. For a large payload, save it to a file and pass the path instead of the content.

## Gotchas (caught during smoke test)

- **Claude trust dialog needs `Enter`, not `C-m`.** First run of claude in a fresh cwd shows "Is this a project you trust? Yes/No". Submit is a raw `Enter`. After spawning, sleep ~12s, `read.sh`, and if you see the trust prompt: `tmux send-keys -t <session> Enter`. About 5s later you'll see the main prompt and the session is ready for `exec.sh`.
- **PATH propagation.** `_common.sh` exports `~/.local/bin:~/.bun/bin:$PATH` before `tmux new-session`. Without that the `claude` symlink (from `claude migrate-installer`) isn't found and the inner shell exits 127.
- **TMUX_TMPDIR.** All scripts use `TMUX_TMPDIR=$HOME/.tmux` (the shared socket the operator unit also uses). Don't override it — `tmux ls` from any context will then see all sessions, including workers.
- **OAuth sharing.** A claude session in a new tmux pane inherits `~/.claude/.credentials.json` (the same file the operator uses). Worker sessions share the same Claude Max subscription and quota as the operator and sysadmin — warn the user before mass-dispatching workers if quota is tight.
- **Unix epoch in `list.sh`.** `created` and `last_activity` are unix epochs. Convert with `date -d @<epoch>` before showing them to a human.
- **`-l` matters in `send-keys`.** Without `-l`, tmux tries to interpret the string as a key sequence (`C-c`, `M-x`, …). With `-l`, it's sent as literal text. All scripts here use `-l` already.

## Multi-step examples

### "spin up a worker on acme and ask it about AuthGuard"

```
1. list.sh --filter worker-                   # confirm worker-acme is absent and count < 5
2. create.sh worker-acme --workspace acme     # spawn
3. sleep 12 + read.sh worker-acme             # check state (trust dialog? welcome?)
4. if trust dialog: tmux send-keys -t worker-acme Enter; sleep 5
5. exec.sh worker-acme "Read src/auth/AuthGuard.ts and summarise."
6. reply to user: "Spawned worker-acme, asked about AuthGuard. Will check in ~30s."
7. sleep 30 → read.sh worker-acme --lines 80 → parse claude reply → forward to user
```

### "acme, what's in the README?"

(user is addressing an existing session)

```
1. list.sh --filter worker-acme               # if missing, ask whether to spawn
2. exec.sh worker-acme "What's in the README?"
3. sleep 8 → read.sh worker-acme --lines 40
4. forward a short summary to the user
```

### "what's running"

```
1. list.sh --filter worker-
2. For each session: read.sh <name> --lines 5  # just the last few lines
3. Build a one-line-per-session summary: "worker-acme: idle | worker-novostudio: working (Cooked 12s) | ..."
```

## Related files

- `scripts/tmux-session/_common.sh` — env, helpers, `log_activity`
- `scripts/tmux-session/{create,list,exec,read,kill}.sh`
- `memory/worker-activity.log` — audit log of all invocations
- `systemd/agent-os-operator.service` — production operator unit (source of the `TMUX_TMPDIR` convention)

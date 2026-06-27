---
name: tmux-host-namespace
description: Canonical socket + attach convention for tmux sessions on an AgentOS host, so the human owner can reach them with a plain `tmux attach`. Use whenever the operator spawns ANY interactive/long-lived tmux session (claude REPL, OAuth flow, long-running command), or needs to hand the owner an attach command. Pairs with the tmux-session-management skill.
type: procedure
---

# tmux on an AgentOS host — canonical socket + attach

A long-lived tmux session is only useful if (a) every AgentOS component sees the *same* tmux server and (b) the human owner can attach to it from a plain ssh login. Both come down to one rule plus a per-deployment namespace consideration.

## Rule: one canonical socket — `TMUX_TMPDIR=$HOME/.tmux`

NEVER `unset TMUX_TMPDIR` and never rely on the default `/tmp/tmux-<uid>`. The whole stack (operator unit, `spawn-worker.sh` / dispatch scripts, watchdogs, `scripts/tmux-session/_common.sh`) keeps ONE shared tmux server at `$HOME/.tmux/tmux-<uid>/default`. `$HOME` is the one path shared between a systemd operator unit (which is usually `PrivateTmp=yes`, so `/tmp` is isolated), worker sandboxes, and a plain ssh login. A session created on `/tmp` will NOT show up in the owner's `tmux ls` and will die in isolation.

Make the socket export system-global (e.g. `/etc/profile.d/agentos.sh` + the shell's global env file) rather than per-user dotfiles, so it survives home recreation / re-provisioning.

`scripts/tmux-session/_common.sh` already does `export TMUX_TMPDIR="${TMUX_TMPDIR:-$HOME/.tmux}"`, so the create/exec/read/list/kill helpers land on the right socket automatically.

## Namespace: two deployment shapes

**Shape A — operator runs directly as the session user** (e.g. an isolated per-tenant instance where `operator-<user>.service` runs `User=<user>` and the operator's shell is inside that unit's tmux server). The operator is already in the right mount namespace and is already the right user, so plain `tmux` (with `TMUX_TMPDIR=$HOME/.tmux`) just works — NO `nsenter`, NO `sudo`.

```bash
TMUX_TMPDIR=$HOME/.tmux tmux new-session -d -s <name> -c <cwd> "<cmd>"
TMUX_TMPDIR=$HOME/.tmux tmux ls
TMUX_TMPDIR=$HOME/.tmux tmux send-keys -t <name> -l "<text>"; TMUX_TMPDIR=$HOME/.tmux tmux send-keys -t <name> C-m
TMUX_TMPDIR=$HOME/.tmux tmux capture-pane -t <name> -p
```

**Shape B — operator runs inside a sandboxed mount namespace** (e.g. a hub operator whose Bash tool is sandboxed away from PID-1). To reach the shared socket in the host (PID-1) mount namespace it must `nsenter` into PID-1 and drop to the owner user. Substitute `<user>` (the host owner, e.g. the install user) and `$HOME` accordingly:

```bash
sudo -n nsenter --mount=/proc/1/ns/mnt -- runuser -u <user> -- \
  env TMUX_TMPDIR=/home/<user>/.tmux tmux new-session -d -s <name> -c <cwd> "<cmd>"
sudo -n nsenter --mount=/proc/1/ns/mnt -- runuser -u <user> -- \
  env TMUX_TMPDIR=/home/<user>/.tmux tmux ls
```

If you skip the host namespace in Shape B, the session is invisible to the owner and dies when the agent process exits.

## Owner attach

A plain ssh login as the owner (whose login already exports `TMUX_TMPDIR`) attaches with:

```bash
tmux attach -t <name>
```

If the session lives under a *different* unix user than the person attaching (Shape A instances), attach via `sudo -u`:

```bash
sudo -u <user> env TMUX_TMPDIR=/home/<user>/.tmux tmux attach -t <name>
```

After starting an interactive flow, send the owner the exact attach command.

## Anti-patterns

- `tmux new-session …` straight from a sandboxed agent shell (Shape B) — invisible to the owner, dies with the agent.
- `unset TMUX_TMPDIR` / relying on `/tmp/tmux-<uid>` — the socket drifts from the operator/workers and attach can't find the session. Always `$HOME/.tmux`.
- Using `nsenter` from a Shape-A operator — unnecessary and usually not permitted (no root); you are already in the right namespace.

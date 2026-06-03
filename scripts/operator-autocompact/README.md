# operator-autocompact — restart-on-silence

Restart the operator's Claude Code session after a period of Telegram inactivity
from the user, **without losing conversation continuity**.

Instead of firing the in-TUI `/compact` command (which still leaves a
summarization overhead in the context window) and relying on a fragile tmux
`send-keys` + marker-file restore protocol, this does a **full systemctl
restart** of `agent-os-operator.service` plus a **SessionStart hook** that
injects the recent Telegram thread on the fresh session. No tmux send-keys, no
marker file, no restore protocol in the operator's prompt — context arrives as
additionalContext from the hook.

## Mechanism

```
                    ┌─ messages.db (user IN, direction='in', chat_id=$OPERATOR_CHAT_ID)
                    │
detect-and-restart  │  reads epoch file (preferred) or falls back to messages.db
        ▼           │  decides: should we restart?
   ┌───────────────────────────────────────────────────────────────┐
   │ if silence > THRESHOLD_MIN                                     │
   │  AND not quiet hours                                           │
   │  AND dedup flag absent                                         │
   │  AND cooldown elapsed                                          │
   │  AND operator NOT busy (busy-guard, see below):               │
   │     - set dedup flag (chown agent user)                       │
   │     - write last-restart epoch                                │
   │     - systemctl restart agent-os-operator.service             │
   └───────────────────────────────────────────────────────────────┘
                    │
                    ▼
            ┌── fresh claude session boots in tmux
            │
            │   SessionStart hook fires (startup|resume):
            │     reads last 20 TG msgs + unanswered IN
            │     emits text as additionalContext
            │
            │   operator sits idle until next message
            │
            └── next user IN → channel push from telegram-mcp
                     │
                     ▼
                UserPromptSubmit hook (update-msg-epoch.sh):
                  - polls messages.db: was the last IN < 60s ago?
                  - YES → write epoch, delete dedup flag
                  - NO  → noop (peer message, sysadmin ping, etc.)
```

## Files

| File | Role |
|------|------|
| `detect-and-restart.sh` | Main detector. Called by timer every 2 min. Decides restart vs noop. |
| `smoke-test.sh` | End-to-end test of all invariants. Safe to re-run (dry-run sentinel). |
| `../../agents/operator/.claude/hooks/session-start.sh` | SessionStart hook — TG context on boot. |
| `../../agents/operator/.claude/hooks/update-msg-epoch.sh` | UserPromptSubmit hook — write epoch + clear dedup flag. |
| `../../systemd/agent-os-operator-autocompact.{service,timer}` | systemd timer running the detector every 2 min. |

## Busy-guard — never restart in-flight work

Silence past the threshold is **necessary but not sufficient**. Right before a
restart (after threshold + cooldown, before the dry-run/real branch) the
detector checks whether the operator is actively doing work. If it is, the tick
is skipped with a `BUSY: <reason> — skip` log line and the **dedup flag and
cooldown file are left untouched** — the next idle tick restarts normally.

Two independent, directly-observed signals (either one ⇒ busy):

| Signal | How it's detected | Why it counts |
|--------|-------------------|---------------|
| **(a) live sub-agent** | A `claude` process that is a descendant of the operator's session process (pane PID of the `operator` tmux session). The Agent/Task tool forks a child claude (`CLAUDE_CODE_FORK_SUBAGENT=1`); the operator's own MCP children are node/bun, so any descendant whose `comm` is `claude` is a running sub-agent. | A silence-restart that kills a session while a sub-agent is writing its result loses that work. |
| **(b) worker tmux session** | A tmux session matching `$AUTOCOMPACT_WORKER_GLOB` (default `worker-*`) on the agent user's tmux server. | Spawned workers route their summary back through the operator; restarting mid-flight can drop that delivery. |

Both are queried from `/proc` + `tmux`, not scraped from the pane, so the signal
is robust to spinner throttling and the dev-channels dialog. The check runs as
root and queries the agent user's tmux server via `sudo -u <agent user> env TMUX_TMPDIR=…`.

Testing knobs (used by `smoke-test.sh`, normally unset):

| Var | Meaning |
|-----|---------|
| `AUTOCOMPACT_WORKER_GLOB` | Glob for worker sessions (default `worker-*`). |
| `AUTOCOMPACT_OPERATOR_PANE_PID` | Force the operator session PID instead of querying tmux. |
| `OPERATOR_TMUX_TMPDIR` | tmux socket dir for the queries (default `$AGENT_HOME/.tmux`). |

## Tunables (`{ENV_FILE}`, e.g. `/etc/agent-os/agent-os.env`)

| Var | Default | Meaning |
|-----|---------|---------|
| `OPERATOR_CHAT_ID` | *(required)* | Telegram chat id whose IN messages count as user activity. |
| `AUTOCOMPACT_THRESHOLD_MIN` | 10 | Min minutes of user silence before restart. |
| `AUTOCOMPACT_COOLDOWN_MIN` | 15 | Min minutes between restarts (belt-and-suspenders backup if flag never gets set). |
| `AUTOCOMPACT_QUIET_START` | 23 | Hour-of-day (24h) when quiet window begins. |
| `AUTOCOMPACT_QUIET_END` | 7 | Hour-of-day when quiet window ends (exclusive). |
| `AUTOCOMPACT_QUIET_TZ` | `UTC` | TZ for the quiet hour boundaries. |
| `OPERATOR_AGENT_USER` | `agent-os` | OS user that owns the operator tmux session + dedup flag. |
| `OPERATOR_USER_FRESH_SEC` | 60 | Window (seconds) for the hook to count a messages.db IN as "currently arriving". |

## State files

- `/var/lib/agent-os/operator-last-user-msg-epoch` — epoch of last user IN (written by hook).
- `/var/lib/agent-os/operator-restarted-since-last-msg.flag` — dedup flag. Set by detect immediately before restart, cleared by hook on next user IN.
- `/var/lib/agent-os/operator-autocompact.last-compact` — epoch of last restart (cooldown source).
- `/var/lib/agent-os/operator-autocompact.dry-run` — sentinel. While present, detect logs `DRY-RUN: would restart` without invoking systemctl.
- `/var/log/agent-os/operator-autocompact.log` — every decision logged here.

## Smoke test

```bash
sudo OPERATOR_CHAT_ID=<your chat id> \
  /opt/agent-os/claude/scripts/operator-autocompact/smoke-test.sh
```

Runs 7 scenarios:
1. Idle 20 min, no flag, not busy → DRY-RUN: would restart logged.
2. Idle + flag present → DEDUP skip logged.
3. Hook on user IN → flag cleared, epoch written.
4. Fresh epoch → ok: silence=X logged.
5. Idle again, not busy → DRY-RUN: would restart logged.
6. Idle + **busy** (fake `worker-smoke-*` tmux session) → BUSY skip logged, dedup flag + cooldown file untouched.
7. Idle + **not busy** → DRY-RUN: would restart (busy-guard passes through).

The test forces the dry-run sentinel ON for its duration and **restores the
prior posture on exit** (via an EXIT trap): if the detector was live before the
run, it is live again after. Exits 1 on any failed assertion.

## Going live after dry-run soak

```bash
sudo rm /var/lib/agent-os/operator-autocompact.dry-run
# Next timer tick (within 2 min) will restart agent-os-operator.service for real
# when conditions are met.
```

Roll back instantly:

```bash
sudo touch /var/lib/agent-os/operator-autocompact.dry-run
# or:
sudo systemctl disable --now agent-os-operator-autocompact.timer
```

## Failure modes worth knowing

- **Restart fires while operator is mid-conversation:** mitigated by the silence threshold + 60s fresh-window in the hook. If a worker reports right after a user reply, the hook updates the epoch from messages.db (which already has the user IN), pushing the silence clock forward. A restart can only fire if the user has been quiet for ≥ THRESHOLD_MIN.
- **Restart fires while a sub-agent / worker is mid-flight:** mitigated by the busy-guard. Even if the user has been silent past the threshold, a live sub-agent (descendant `claude`) or a `worker-*` tmux session makes the detector log `BUSY: … — skip` and leave the dedup flag + cooldown untouched. The restart is deferred to the next idle tick.
- **Busy-guard never clears (operator stuck busy forever):** by design the guard only defers, it never sets the dedup flag. If a sub-agent or worker genuinely hangs, the operator session is never restarted by *this* path — but a hung sub-agent is its own bug, and a worker watchdog/timeout eventually tears workers down, after which the next idle tick restarts normally.
- **SessionStart hook fails to read messages.db:** hook exits 0 silently, no context injected. Operator falls back to its existing boot protocol. Graceful degradation.
- **systemctl restart hangs:** the service is `Type=oneshot`; systemd's default timeout applies. If restart hangs, the detect script's flag is cleared via `rm` in the error path so the next tick can retry.
- **Hook deletes dedup flag when it shouldn't:** the hook only deletes the flag when messages.db shows a user IN within the last `OPERATOR_USER_FRESH_SEC` (default 60s). Worker / peer / sysadmin prompts leave the flag alone.

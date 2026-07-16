# AgentOS hook scripts

Project-level lifecycle hooks wired in `.claude/settings.json`. Each hook reads stdin (Claude Code passes hook payload as JSON), parses what it needs via `jq`, and exits 0 (proceed) or 2 (block — `PreToolUse` only). Shared helpers live in `_common.sh`.

## Hooks

| Script | Event | Matcher | Async | Always-on |
|--------|-------|---------|-------|-----------|
| `boot.sh` | `SessionStart` | `startup`, `compact` | no | yes |
| `precompact-snapshot.sh` | `PreCompact` | `*` | no | yes |
| `enrich-prompt.sh` | `UserPromptSubmit` | — | no | yes |
| `guard-bash.sh` | `PreToolUse` | `Bash` | no | **always (security gate)** |
| `guard-edit.sh` | `PreToolUse` | `Edit\|Write\|MultiEdit` | no | **always (file protection)** |
| `log-action.sh` | `PostToolUse` | `Edit\|Write\|MultiEdit` | yes | no-op if no formatter |
| `log-subagent.sh` | `SubagentStop` | — | yes | yes (audit) |
| `notify-stop.sh` | `Stop` | — | yes | only if `OPERATOR_PEER_ID` set |
| `session-end.sh` | `SessionEnd` | — | yes | yes |

`_common.sh` is **not** a hook — it's a shared library sourced by every hook script:

```bash
. "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
read_input          # reads stdin into $INPUT once
log "msg"           # append to /tmp/agentos-hooks/<hook>.log
json '.field'       # jq-based field extraction from $INPUT
tool_input_field f  # shorthand for json '.tool_input.f'
block "reason"      # exit 2 with feedback (PreToolUse only effective)
allow_with_context  # emit additionalContext (SessionStart, UserPromptSubmit)
is_stop_loop        # true if stop_hook_active — bail in Stop/SubagentStop
```

## Behavior contract

- **Exit 0** → proceed; stdout JSON parsed for decisions or `additionalContext`
- **Exit 2** → block tool call (`PreToolUse` only — `SessionStart` can't block boot, exit 2 just shows stderr)
- **Other exits** → non-blocking error; logged to `/tmp/agentos-hooks/<hook>.log`
- **Async hooks** (`log-action`, `log-subagent`, `notify-stop`, `session-end`): fire-and-forget; exit code ignored

## Loop guards (Stop / SubagentStop)

Both `Stop` and `SubagentStop` can re-fire if a hook returned feedback. Each script calls `is_stop_loop` first and exits 0 if true. Without this, you get an infinite loop.

## Required env vars (set by install.sh in `/etc/agent-os/agent-os.env`)

| Var | Used by | Default | Purpose |
|-----|---------|---------|---------|
| `OPERATOR_PEER_ID` | `notify-stop`, `session-end` | (none — silent skip) | Target operator peer for notification |
| `CLAUDE_PEERS_API_URL` | `notify-stop`, `session-end` | `http://127.0.0.1:7899/send-message` | claude-peers broker REST API |
| `CLAUDE_PEERS_HEALTH_URL` | `boot` | `http://127.0.0.1:7899/health` | Health-check endpoint |
| `SAGA_MCP_HEALTH_URL` | `boot` | `http://localhost:3851/health` | Health-check endpoint |
| `TELEGRAM_MCP_HEALTH_URL` | `boot` | (unset — skipped) | Optional |
| `AGENTOS_HOOKS_LOG_DIR` | all | `/tmp/agentos-hooks` | Per-hook log directory |
| `PRECOMPACT_MSG_COUNT` | `precompact-snapshot` | `30` | Transcript tail length, in messages |
| `PRECOMPACT_SNAPSHOT_DIR` | `precompact-snapshot` | `$AGENTOS_HOOKS_LOG_DIR` | Where snapshots are written |
| `AGENTOS_AUDIT_LOG` | `log-action`, `log-subagent` | `${CLAUDE_PROJECT_DIR}/.claude/audit.log` | Audit append-log |

systemd units inherit these via `EnvironmentFile=/etc/agent-os/agent-os.env`.

## Customizing

- **Disable a hook**: remove its block from `.claude/settings.json` `hooks` key.
- **Replace block patterns**: edit `guard-bash.sh` / `guard-edit.sh` `case` statements.
- **Override formatter precedence**: edit `log-action.sh` `format()` function.
- **Add new event handler**: drop a new `<event>.sh`, make executable, register in `settings.json`. No central dispatcher to update.

## --minimal profile

For `--minimal` template installations, ship only:
- `_common.sh`
- `guard-bash.sh`
- `guard-edit.sh`

Settings.json registers only `PreToolUse` hooks. No MCP brokers, no health-check, no operator notify. Pure safety net.

## Production tuning

- Set `AGENTOS_HOOKS_LOG_DIR=/var/log/agentos-hooks` in systemd `Environment=` for persistent logs.
- For `OPERATOR_PEER_ID`: derive at install.sh time and write to `/etc/agent-os/agent-os.env`.
- Audit log rotation: combine with logrotate config in `/etc/logrotate.d/agent-os`.

## Testing locally

```bash
# Smoke-test guard-bash.sh
echo '{"tool_input":{"command":"rm -rf /"}}' | \
  CLAUDE_PROJECT_DIR=$PWD ./guard-bash.sh
# → exit 2, stderr: "Refused destructive root/home delete..."

echo '{"tool_input":{"command":"ls -la"}}' | \
  CLAUDE_PROJECT_DIR=$PWD ./guard-bash.sh
# → exit 0, no output
```

(Full test suite TBD — fixtures will live in `tests/hooks/`.)

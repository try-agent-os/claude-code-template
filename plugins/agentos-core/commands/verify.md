---
description: Run the full AgentOS verification dashboard (15-check verify.sh)
allowed-tools: Bash(scripts/verify.sh*) Bash(/opt/agent-os/*) Bash(systemctl*) Bash(curl localhost:*) Bash(test:*) Bash(ls:*)
---

# AgentOS Verify

!`if [ -x /opt/agent-os/claude/scripts/verify.sh ]; then bash /opt/agent-os/claude/scripts/verify.sh 2>&1 | head -80; else echo "verify.sh not found at /opt/agent-os/claude/scripts/verify.sh — falling back to inline checks"; echo "── systemd ──"; systemctl is-active agent-os-saga agent-os-operator agent-os-dagu 2>&1; echo "── claude-peers (:7899) ──"; curl -fsS http://127.0.0.1:7899/health 2>&1 | head -c 200 || echo "FAIL"; echo "── saga-mcp (:3851) ──"; curl -fsS http://localhost:3851/health 2>&1 | head -c 200 || echo "FAIL"; fi`

## Task

Parse the verify.sh output above. Summarize:
- N of M checks passed
- Any failures with the suggested fix from verify.sh output
- Confirm operator peer is registered (most-load-bearing single check)

If verify.sh wasn't found, the inline fallback ran 3 minimal checks instead — report those and tell the user `scripts/verify.sh` is missing from `/opt/agent-os/claude/scripts/`.

If any check failed, suggest concrete next step: re-run /agentos:restart <unit> for the failing component, or `journalctl -u <unit> -n 100` for deeper inspection.

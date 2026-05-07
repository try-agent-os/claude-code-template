---
description: List currently registered AgentOS peers (instances connected to claude-peers broker)
allowed-tools: Bash(curl localhost:*) Bash(curl 127.0.0.1:*) Bash(jq:*)
---

# AgentOS Peers

!`curl -sf http://127.0.0.1:7899/list-peers -H 'Content-Type: application/json' -d '{"scope":"machine","cwd":"/","git_root":null}' 2>&1 | jq '.' 2>&1 | head -80`

## Task

Display peers above as a table: `ID | CWD | Summary | Last seen`. Highlight stale peers (last_seen > 5 min ago) — these are likely dead sessions whose Claude Code process exited without unregistering.

If broker is unreachable (curl fails), suggest `/agentos:status` to inspect agent-os-operator (claude-peers runs as stdio MCP under the operator session).

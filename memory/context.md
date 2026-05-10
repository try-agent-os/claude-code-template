# AgentOS Context

heartbeat_count: 0

## System state

- saga-mcp: not_initialized
- epics: not_created
- operator: unknown
- workers: none active

## Notes

Fresh install. Run `agents/heartbeat/init-epics.sh` (or wait for the first
dispatcher cycle) to bootstrap saga-mcp project + default epics. The dispatcher
updates this file on each cycle.

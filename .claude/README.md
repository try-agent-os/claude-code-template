# `.claude/` directory

Project-scope Claude Code configuration. Loaded automatically when `cwd` is at or under this repo's root.

## Layout

```
.claude/
├── settings.json     # project settings — permissions, hook wiring, additionalDirectories
├── hooks/            # lifecycle scripts (see hooks/README.md)
│   ├── _common.sh    # shared bash helpers (sourced by each hook)
│   ├── boot.sh, enrich-prompt.sh, guard-{bash,edit}.sh, log-{action,subagent}.sh,
│   ├── notify-stop.sh, session-end.sh
│   └── README.md
└── README.md         # this file
```

## Settings layering

Three scopes, highest precedence first:

1. **Managed** (`/etc/claude-code/managed-settings.json`, root-owned by install.sh) — hard org/security policy. Sandbox config, `channelsEnabled`, `allowedChannelPlugins`, `minimumVersion`, catastrophic deny rules. Cannot be overridden.
2. **Project** (`.claude/settings.json` — this directory, committed) — team-shared rules: project-specific deny/ask/allow patterns, hook wiring, additionalDirectories, attribution.
3. **User** (`~/.claude/settings.json`, written by install.sh per user) — personal defaults: model preference, plugin enablement, cleanupPeriodDays, env injections.

Arrays merge across scopes (so project deny + managed deny both apply). Scalars take the most-specific value.

## Hook env vars

Set by install.sh in `/etc/agent-os/agent-os.env` (loaded by systemd units' `EnvironmentFile=`). See `hooks/README.md` for full list.

## --minimal profile

For minimal installations: ship only `_common.sh`, `guard-bash.sh`, `guard-edit.sh`. Settings.json registers only PreToolUse hooks. No operator integration, no MCP broker dependencies — pure safety net.

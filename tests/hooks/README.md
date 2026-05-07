# Hook tests

Smoke-test fixtures for `.claude/hooks/*.sh`. Each fixture is a JSON file containing:

- The hook payload (what Claude Code would send via stdin)
- A `_test` block describing expected behavior

Runner: `tests/hooks/run.sh`.

## Layout

```
tests/hooks/
├── README.md
├── run.sh                  # test runner
└── fixtures/
    ├── guard-bash-block-rm-rf-root.json
    ├── guard-bash-block-rm-rf-home.json
    ├── guard-bash-block-curl-pipe-sh.json
    ├── guard-bash-block-fork-bomb.json
    ├── guard-bash-block-force-push-main.json
    ├── guard-bash-block-reset-hard-origin.json
    ├── guard-bash-allow-ls.json
    ├── guard-bash-allow-git-status.json
    ├── guard-edit-block-env.json
    ├── guard-edit-block-git-dir.json
    ├── guard-edit-block-lockfile.json
    ├── guard-edit-block-ssh-key.json
    ├── guard-edit-allow-readme.json
    ├── notify-stop-loop-guard.json
    ├── log-subagent-loop-guard.json
    ├── boot-startup.json
    └── boot-compact.json
```

## Fixture format

```json
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "rm -rf /" },
  "session_id": "test-session-001",
  "_test": {
    "hook": "guard-bash",
    "expected_exit": 2,
    "expected_stderr_contains": "destructive root/home",
    "args": [],
    "comment": "optional human note"
  }
}
```

`_test` is stripped before piping the rest of the JSON to the hook script.

| Field | Required | Default | Notes |
|-------|----------|---------|-------|
| `_test.hook` | yes | — | hook script base name (no `.sh`) |
| `_test.expected_exit` | no | `0` | Numeric exit code |
| `_test.expected_stderr_contains` | no | (none) | Substring check on stderr |
| `_test.args` | no | `[]` | CLI args passed to the hook script |
| `_test.comment` | no | — | Free-form note for humans |

## Running

```bash
# All fixtures
./tests/hooks/run.sh

# Single fixture
./tests/hooks/run.sh tests/hooks/fixtures/guard-bash-allow-ls.json

# Verbose (show stdout/stderr per test)
./tests/hooks/run.sh -v
```

Exit 0 if all pass, 1 if any fail.

## CI integration

Add to your CI pipeline:

```yaml
- name: Hook smoke tests
  run: ./tests/hooks/run.sh
```

Requires `jq`. macOS bash 3.2 compatible.

## What's covered

| Hook | Tests |
|------|-------|
| `guard-bash` | 8 (5 block, 2 allow, 1 boundary) |
| `guard-edit` | 5 (4 block: .env, .git/, lockfile, ssh; 1 allow: README) |
| `notify-stop` | 1 (loop guard) |
| `log-subagent` | 1 (loop guard) |
| `boot` | 2 (startup, compact) |

What's NOT covered (yet):
- `enrich-prompt.sh` — depends on memory/today.md / active-task.md presence (need fixture filesystem setup)
- `log-action.sh` — async, formatter integration (need test files)
- `session-end.sh` — appends to memory/sessions.log (need fixture filesystem setup)

These can be added in a follow-up by setting up `tests/hooks/fixtures-fs/` with a sample project tree.

## Adding a new fixture

1. Create `tests/hooks/fixtures/<descriptive-name>.json`
2. Include canonical Claude Code hook payload + `_test` block
3. Run `./tests/hooks/run.sh tests/hooks/fixtures/<name>.json` to verify
4. Run all tests to make sure nothing else regressed

## Limitations

- No mocking of MCP brokers — `boot.sh` health checks will report DOWN in tests, that's expected (test asserts exit 0 regardless)
- No mocking of peers REST API — `notify-stop.sh` will fail to POST silently (`curl -m 2` timeout), test asserts exit 0
- Tests don't verify side effects (audit log writes, formatter calls) — only exit code + stderr substring. Side-effect verification needs richer fixtures.

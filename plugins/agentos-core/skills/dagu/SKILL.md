---
description: Manage AgentOS routines via the Dagu CLI — start/stop/restart/retry DAG runs, view status and history, validate YAML before deploy, enqueue manual runs. Use when the user says "run dagu", "restart routine", "dagu status", "dagu history", "dagu dry", "dagu retry", "dagu logs DAG", "why didn't the DAG fire", "validate routine yaml", "clean up DAG history", "check the heartbeat/workers schedule".
allowed-tools: Bash Read
---

# dagu — full CLI control over the AgentOS routines engine

Dagu runs every cron-driven workflow (`routines/*.yaml`). The web UI listens on
`127.0.0.1:8080`; the CLI does everything the UI can't (cleanup, history
filters, dry-run, retry a single step). Managed by `agent-os-dagu.service` (see
`systemd/agent-os-dagu.service` and `docs/decisions/0001-scheduling-layer-dagu.md`).

## AgentOS-specific invocation

All DAGs live in `${INSTALL_ROOT}/claude/routines/` (default
`/opt/agent-os/claude/routines`). Dagu reads the `DAGU_DAGS_DIR` env var. Run
**as the agent user** (owner of state in `/var/lib/agent-os/dagu/`):

```bash
sudo -u agent-os DAGU_DAGS_DIR=/opt/agent-os/claude/routines dagu <subcommand>
```

Or, from a shell that already exports `DAGU_DAGS_DIR`, just `dagu <subcommand>`.

## Daily commands

| Command | Use |
|---|---|
| `dagu status <dag>` | Last run's state + duration |
| `dagu history <dag>` | Last 50 runs (use `--limit N`); failure investigation starts here |
| `dagu start <dag>` | Manual one-off trigger (bypasses schedule) — or `scripts/dagu-run.sh <dag>` |
| `dagu stop <dag>` | Kill currently running execution |
| `dagu restart <dag>` | Stop + start with a fresh run-id |
| `dagu retry <dag> <run-id>` | Re-execute a failed run from where it stopped |
| `dagu dry <dag>` | **Validate YAML without running** — required after every edit to `routines/*.yaml` |
| `dagu validate <dag>` | Structural check (cheaper than dry) |
| `dagu cleanup <dag>` | Trim old history records for one DAG |
| `dagu enqueue <dag>` | Queue a run (when scheduler is paused) / `dequeue` to remove |

## Server / scheduler

| Command | When |
|---|---|
| `systemctl status agent-os-dagu` | Health check (production path) |
| `dagu start-all` | Manual all-in-one (scheduler + web UI + coordinator) — what `agent-os-dagu.service` does |
| `dagu server` | Web UI only |
| `dagu scheduler` | Scheduler daemon only |

## Validation loop (mandatory after editing routines/)

Dagu does NOT block save on a broken YAML — it silently stops firing the
schedule until you notice. `dagu dry` is the only thing that surfaces the parse
error. Always run this after touching `routines/*.yaml`:

```bash
for dag in /opt/agent-os/claude/routines/*.yaml; do
  name=$(basename "$dag" .yaml)
  sudo -u agent-os DAGU_DAGS_DIR=/opt/agent-os/claude/routines dagu dry "$name" 2>&1 \
    | grep -qE "Error|failed" && echo "BROKEN: $name" || true
done
```

## Finding genuine failures

`dagu status` reports the last recorded run with no recency filter, so a DAG
that failed once long ago and never re-ran shows "Failed" forever. Use
`scripts/dagu-recent-failures.sh` to list ONLY active (recent, latest-run)
failures and separate them from stale ones:

```bash
scripts/dagu-recent-failures.sh            # last 72h, human output
scripts/dagu-recent-failures.sh --json     # machine-readable, CI-friendly (exit 1 on active failure)
```

## Installing dagu (if missing)

`install.sh` installs the dagu binary automatically. For a fresh box or a
version bump, install manually — Linux x86_64 / arm64:

```bash
DAGU_VERSION="2.7.3"
ARCH="$(uname -m)" ; [ "$ARCH" = "x86_64" ] && ARCH=amd64 ; [ "$ARCH" = "aarch64" ] && ARCH=arm64
curl -fsSL "https://github.com/dagu-org/dagu/releases/download/v${DAGU_VERSION}/dagu_${DAGU_VERSION}_linux_${ARCH}.tar.gz" \
  | sudo tar -xz -C /tmp dagu
sudo install -m 0755 /tmp/dagu /usr/local/bin/dagu
dagu version
```

macOS: `brew install dagu-org/brew/dagu`.

## Common patterns

- **Why didn't a DAG fire?** → `systemctl status agent-os-dagu` (scheduler alive?) → `dagu history <dag>` (last attempts) → `dagu dry <dag>` (parse error?) → `journalctl -u agent-os-dagu --since "1h ago"`.
- **DAG hung** → `dagu stop <dag>` → `dagu retry <dag> <run-id>` if state is salvageable, else `dagu start <dag>`.
- **Schedule changed** → edit `routines/<name>.yaml` → `dagu dry <name>` → no restart needed, Dagu re-reads on the next tick.
- **Spammy DAG** → `dagu cleanup <dag>` trims its run history.

## Gotchas

- A `command:` value containing `: ` (colon-space) must be **single-quoted** or Dagu's parser splits it as a key-value pair.
- `dagu history` lists newest first. `dagu retry` needs the run-id (column 1 in history output), not just the dag name.
- Production state dir: `/var/lib/agent-os/dagu/{data,logs}/`. Never `rm -rf` without care — it destroys the run history other workflows depend on.

## Web UI

`http://127.0.0.1:8080` — bound to localhost only by default (no auth). If you
expose it, enable basic auth via `DAGU_AUTH_MODE=basic` +
`DAGU_AUTH_BASIC_USERNAME` / `DAGU_AUTH_BASIC_PASSWORD` in the env file.

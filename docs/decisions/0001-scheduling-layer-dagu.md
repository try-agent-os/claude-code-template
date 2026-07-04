# ADR-0001 — Scheduling layer: Dagu

**Status:** Accepted
**Date:** 2026-05-11

## Context

AgentOS needs to run periodic and scheduled work on the primary host (a CPU-only droplet ~4 vCPU / 8 GB): a heartbeat dispatcher every ~45 min, token refreshers every ~10 min, time-windowed event reminders, watchdogs, and a growing set of skill-driven routines (morning briefs, weekly reviews, anomaly mirrors). Until 2026-05-11 these lived as individual `systemd` timer units rendered by `install.sh`.

That arrangement worked but had four pain points that started to compound:

1. **Adding a routine = three files + `daemon-reload`.** A new `.service` + `.timer` + a wrapper script, then `systemctl daemon-reload` and `enable --now`. Friction high enough that we kept inlining things into the dispatcher instead of giving them their own schedule.
2. **No central observability.** "When did this last run, did it succeed, what did stdout say" required `journalctl -u <unit>` per timer. No history view, no retry button.
3. **No DAG / dependencies on the platform.** Multi-step routines (`fetch → analyze → format → send-tg`) had to glue steps inside a single shell script, losing per-step retry/timeout.
4. **No overlap policy.** Two cron timers could double-fire if a previous run was still going (we hit this on the dispatcher); the only fix was a hand-rolled `flock` per script.

The trigger was a user request: *"хотим более универсальную систему с таймерами, дашбордом, логами — что-то ближе к [Claude Code Routines](https://claude.com/blog/introducing-routines-in-claude-code), только локально."*

Claude Code Routines itself is cloud-only (Anthropic-managed), so it was the target shape but not a deployable option.

### Decision drivers (in priority order)

1. **Footprint on a busy single host.** The droplet already runs `telegram-mcp`, `saga-mcp`, `whisper-server` (model resident in RAM), `operator` (Claude in tmux), ephemeral `dispatcher` (Claude per-tick), `claude-peers` broker, `content-hub`. Anything new needs to be measured in single-digit MB at idle, not GB.
2. **Air-gapped friendly.** AgentOS works in environments without outbound internet for long stretches. No phone-home, no required cloud control plane.
3. **YAML routines as files in the hub repo.** Routines should be `git`-versioned, code-reviewable, and added via PR — not stored in an opaque database.
4. **Built-in UI** with real-time runs, per-step stdout/stderr, manual trigger, retry button. The user explicitly asked for this.
5. **DAG / dependencies + retry + timeout + overlap policy** as platform features, not shell-glue.
6. **Catchup window** for missed runs (the dev laptop is the secondary host and routinely sleeps).
7. **Triggers**: at minimum cron + webhook + manual; ideally also API and GitHub events.

## Decision

Adopt [**Dagu**](https://github.com/dagu-org/dagu) as the scheduling layer for AgentOS. Routines live in `routines/*.yaml` in the hub repo, picked up from disk by a `dagu` daemon running as `agent-os-dagu.service` (systemd unit). Existing `.timer` units migrate one-for-one to Dagu YAML. New routines are added as a single yaml file + PR — no `daemon-reload` dance.

Dagu won on every decision driver above without a runner-up close enough to be worth a hybrid: it's a single statically-linked Go binary (~20 MB), file-based storage by default, declarative YAML, web UI on `:8080`, DAG with per-step retry/timeout, `overlap_policy: skip|latest|all`, `catchup_window`, and a trigger surface that covers cron + webhook + manual + API + GitHub events.

> **Update (worker-orchestration migration):** the LLM heartbeat dispatcher referenced in the Context above has since been removed. Worker orchestration now also runs on Dagu, token-free: `routines/workers.yaml` (launcher, every 5 min) → `scripts/worker-launcher-tick.sh`, `routines/worker-supervisor.yaml` (supervision, every 1 min) → `scripts/worker-supervisor.sh`, and `routines/strategist.yaml` (daily). No `claude -p` per-tick dispatcher remains; the "one scheduler" outcome of this ADR now covers worker spawn/supervision as well.

## Alternatives considered

The research pass that preceded this decision covered four categories of tools. The full per-tool footprint and tradeoffs:

### Workflow engines (declarative, DAG, UI, retries)

| Criterion | **Dagu** ✅ | Kestra | Airflow | Windmill | n8n |
|---|---|---|---|---|---|
| Language / runtime | Go static binary | JVM 21+ (Java) | Python 3 | Rust server + Node UI | Node.js |
| Single process / minimum | One binary | JAR + JVM | scheduler + webserver + worker + triggerer | server + worker + Postgres + reverse-proxy | Node app + DB |
| Storage default | Files on disk | H2 (dev) / **Postgres required for prod** | SQLite (dev) / **Postgres or MySQL for prod** | **Postgres required** | SQLite (Postgres recommended) |
| Idle footprint | ~20 MB binary, single-digit MB RAM | 200-400 MB JAR + ~1-2 GB JVM heap | 4 processes, ~1-2 GB combined | ~1 vCPU + 1-2 GB per worker + server + Postgres | ~150-300 MB Node |
| Air-gapped friendly | Yes | Yes, but JVM updates / Postgres maintenance add surface | Possible but heavy | Possible but multi-service | Possible |
| Routines as git-versioned files | Yes — yaml files in repo, hot-reloaded from disk | Yes — yaml, but native flow is push-to-API; git-sync is opt-in via cron | Yes — Python DAG files | Scripts in built-in repo, git-sync available | Workflows stored as JSON in DB; export is manual |
| DAG / dependencies | Yes | Yes | Yes — primary feature | Yes (flows) | Yes (visual nodes) |
| Retry / timeout / overlap policy | All native (`retry`, `timeout_sec`, `overlap_policy`) | All native | All native + SLAs | All native + suspend / approval | Per-node retry / wait |
| UI | Minimal: runs, logs, retry, manual trigger, suspend | Rich: flow editor, namespaces, secrets vault, KV-store, blueprints catalog | Sophisticated DAG view, very technical | Slick modern UI, code + visual | **Visual flow editor**, drag-and-drop |
| Triggers | cron + webhook + manual + API + GitHub events | cron + webhook + API + 600+ plugin tasks | cron + sensors + dataset triggers | cron + webhook + Slack/email events | 400+ trigger nodes |
| Where it shines | Cron-like shell jobs with retries and a UI, minimal infra | Data-engineering ETL with rich plugin ecosystem and namespaces | Heavy ETL/ELT pipelines, large data teams | Internal tooling, scripts-as-a-service with forms | Multi-step automations between SaaS APIs (closer to Zapier) |
| Where it hurts | Heavy data pipelines → lots of shell glue | JVM heap + Postgres on a small host is a real cost | Overkill for <50 schedules, 4-process baseline | No Postgres = no life; multi-service deploy | Workflow-JSON in DB, not PR-friendly; visual builder is the wrong shape for shell jobs |

**Why Dagu over the workflow engines:**

- **Kestra:** UI is genuinely impressive (and was tempting), but production needs JVM 21 + Postgres, which is a real cost on a host already running multiple stateful services. Most of the rich UI (namespaces, multi-tenancy, plugin marketplace) solves problems we don't have. Revisit if data-engineering pipelines appear.
- **Airflow:** four-process baseline (scheduler, webserver, worker, triggerer) for what is currently a half-dozen routines is the wrong end of the trade-off curve. Designed for a data team, not a single operator.
- **Windmill:** Postgres-mandatory, multi-service. Strongest fit would be "internal tooling with forms for a team", not single-host scheduling.
- **n8n:** spiritual sibling of Zapier — strongest at no-code integrations between SaaS APIs. Our work is shell scripts and `claude -p` invocations, where the visual flow editor adds friction rather than removing it. Workflow JSON lives in a database, so PR-review and git-versioning are second-class.

### Cron-style schedulers with UI (no DAG)

| Tool | Language / binary | Storage | Distributed | Notes |
|---|---|---|---|---|
| [Cronicle](https://github.com/jhuckaby/Cronicle) | Node.js app | File-based internal | Yes — primary / backup / worker, auto-discovery | Richer per-job observability than Dagu (CPU/RAM per job, historical graphs), but **no DAG** |
| [Dkron](https://dkron.io/) | Go single binary | BoltDB + Raft replication | Yes — cluster with leader election | Solid HA cron across nodes; no DAG; we have one host so HA is unused |
| Cronmaster | Niche self-host project | n/a | n/a | Low activity, not production-ready |

All three were eliminated by the same criterion: **no DAG / dependencies**. The moment we want "step A → if success → step B → retry step C twice on failure" as a platform feature, we'd be re-implementing it in shell. We already plan multi-step skill routines (e.g. `whoop-fetch → analyze → format → send-tg`), so DAG isn't aspirational.

Cronicle was the closest call — its observability (CPU/RAM tracking per job, performance history) is genuinely richer than Dagu's. If we had no inter-step dependencies *and* needed HA across multiple hosts, Cronicle would be the choice.

### Monitoring-only over existing cron/systemd

| Tool | What it is |
|---|---|
| [Healthchecks](https://github.com/healthchecks/healthchecks) | Python 3.12 + Django + Postgres/MySQL. **Not a scheduler** — every job ends with `curl https://hc.../ping/<uuid>`; the service tracks ping cadence and alerts on misses. 25+ alerting channels (Telegram, Slack, PagerDuty, Signal, email, webhook). |

This was the hybrid Plan B: keep `systemd` timers as-is, add Healthchecks as a ping-monitor for a dashboard + alerts. We'd have gained "what ran when, what missed, alert me on miss" without changing schedule definitions.

We'd have **not** gained: declarative routine spec, DAG, platform-level retry/timeout/overlap, manual-trigger button, git-versioned schedule.

Rejected because (a) the Dagu pilot took ~10 min to stand up and migrating 5 timers cost ~30 min, so the "Dagu is too expensive to migrate" premise of Plan B didn't hold; (b) Healthchecks adds a Postgres dependency for monitoring-only value, which is the worst footprint trade. Healthchecks remains a reasonable monitoring layer *on top of* a scheduler if we ever want richer alert routing than Dagu's built-in webhook hooks.

### DIY: custom `yaml → systemd` generator

A 100-line script could read `routines/*.yaml` and emit `agent-os-<name>.{service,timer}` + run `daemon-reload`. Zero new dependencies.

| Pro | Con |
|---|---|
| No new runtime | No central UI |
| Native to the OS | No platform retry / overlap / catchup |
| Easy debugging via `journalctl` | No DAG |
| Trivially auditable | No manual-trigger button |
| Tiny footprint | Have to write all of the above ourselves → reinventing Dagu |

Rejected because the build-vs-buy math is unambiguous: Dagu *is* the version of this we'd build, except already written, tested, and maintained.

## Consequences

### Positive

- **Adding a routine = one yaml file + PR.** No `systemctl daemon-reload`, no separate wrapper script unless the command itself is non-trivial.
- **Central UI on `:8080`** with run history, per-step stdout/stderr, retry, manual trigger, suspend. SSH tunnel or reverse proxy gives operator-grade access.
- **`overlap_policy: skip`** kills a whole class of race conditions we used to hand-roll with `flock`.
- **`catchup_window`** lets routines on the secondary (laptop) host gracefully recover after sleep.
- **DAG is platform-level**, so multi-step skill routines stop being monolithic shell scripts.
- One Go binary, one systemd unit, one yaml directory — the operational surface fits in one paragraph.

### Negative / accepted trade-offs

- **One more daemon to keep alive.** Mitigated by `Restart=always` in the systemd unit; falls out of the standard monitoring path.
- **Less mature than Airflow/Kestra/n8n.** Smaller community, fewer third-party tutorials. Acceptable because our use case (shell jobs + `claude -p` invocations) is dead center of Dagu's strengths and doesn't push into niche features.
- **No native integration plugins.** Dagu runs shell commands; integrations are bring-your-own (curl, gcloud CLI, `claude -p`, etc.). This is a feature for us — we already have those — but would be a real cost if we needed BigQuery/Snowflake/dbt connectors.

### Neutral

- `agent-os-operator-watchdog.timer` remains as a systemd timer rather than a Dagu routine — it watches the operator process and is below the Dagu daemon in the dependency stack. Watchdogging the watchdog is out of scope.

## When to revisit

Re-open this decision if any of these become true:

- **A real data pipeline appears** (regular ETL from Timing / WHOOP / Telegram into an analytics warehouse, dbt models, parametrized backfills). Then Kestra's plugin ecosystem or Airflow's DAG primitives become genuinely valuable.
- **Multi-host scheduling** — more than one production host running coordinated routines. Then Dkron's Raft cluster or Cronicle's primary/backup model become relevant; Dagu has a distributed mode but isn't as mature.
- **A team needs RBAC / namespaces / secrets vault** for routine management — Kestra's strongest hand.
- **Dagu development stalls** — single-vendor risk. Watch the upstream cadence.

If only the *UI* gets shinier elsewhere, that alone is not a reason to migrate. A migration is yaml-rewrites + retesting; the bar for "worth it" should be a missing capability, not a prettier dashboard.

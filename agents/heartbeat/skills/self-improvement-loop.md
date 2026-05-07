---
name: self-improvement-loop
description: Full improvement cycle for AgentOS and business processes following Scan → Evaluate → Spike → Integrate → Measure. Includes a spike (test-and-prove) before integrating. Runs as a strategist-worker (Opus, ~30 min).
type: procedure
read_when: Runs as a strategist-worker for the full Scan → Evaluate → Spike → Integrate cycle; "self-improvement", "system upgrade", "spike", "autoresearch", "process optimization", "bottleneck".
---

# Skill: Self-Improvement Loop

A closed-loop improvement cycle for AgentOS and business processes, following the autoresearch model:
**Scan → Evaluate → Spike → Integrate → Measure**

Runs as a **strategist-worker** (Opus, ~30 min). Difference from `self-upgrade-scan`:
- `self-upgrade-scan` — finds infrastructure tools, no testing
- `self-improvement-loop` — full cycle, including business processes, with a spike-prove step before integration

---

## Step 1: SCAN

### Search areas (extended)

**A. AgentOS infrastructure** (from self-upgrade-scan)
- Agent memory: graph DB, hybrid retrieval, temporal KG
- Agent architecture: orchestration, tool use, multi-agent patterns
- MCP ecosystem: new servers, integrations
- LLM efficiency: prompt caching, model routing, context compression

**B. Business processes**
- Outreach automation: new approaches to cold email, LinkedIn automation, reply tracking
- CRM & pipeline: stage automation, scoring models
- Proposal generation: tools for fast drafting, open-tracking
- Domain-specific intelligence: tools relevant to your business domain

**C. User productivity**
- Automation: zapier/make alternatives, n8n workflow patterns
- Research tools: web scraping, market intelligence, competitive monitoring
- Meeting productivity: summary tools, action item extraction
- Calendar/scheduling: booking automation, time blocking

**D. Internal analytics**
- Read `memory/learnings.md` → find tasks done manually over and over
- Read `memory/patterns.md` → find high-confidence patterns that aren't yet automated
- Read `logs/workers/` → which workers often end in `blocked`? Candidates for improvement.
- Read `memory/schedule.md` → which checks aren't running on schedule? Need help?

### Sources

```
Web search:
  - "AI business automation 2026"
  - "sales outreach tools alternatives"
  - "n8n workflow ai agents"
  - "<your domain> intelligence tools"
  GitHub trending: topics = ai-agents, automation, productivity, sales-automation
  HN: "Ask HN: what's your team automating in 2026"
  r/productivity, r/SaaS, r/MachineLearning
```

### Scan output

A list of candidates with brief descriptions:

```
- **[name]** — [what it does]. Area: [A/B/C/D]. Source: [link or "internal"]
```

---

## Step 2: EVALUATE

### Score each candidate

| Criterion | Points | Description |
|-----------|--------|-------------|
| **Fit** | 0-3 | 0=no link, 1=weak, 2=good, 3=ideal |
| **Impact** | 0-3 | 0=cosmetic, 1=convenience, 2=saves 1h/week, 3=unblocks a bottleneck |
| **Effort** | 1-3 | 1=hours, 2=days, 3=weeks |
| **No-Docker** | pass/fail | Fail if it requires Docker without a self-hosted alternative |
| **No-GPU** | pass/fail | Fail if it requires a GPU (we use Apple Silicon/CPU) |

**Formula:** `score = (fit + impact) / effort`

**Filters (fail → skip):**
- Docker-only without an alternative → skip
- GPU-only → skip
- SaaS-only without self-hosted or API → skip
- Requires a full refactor (>1 week effort) → skip (only create a research task)
- Already in the current stack → skip

**Threshold for Spike:** `score >= 2.5` AND both filters pass

If no candidates pass the threshold — record in history and finish with `status: no-candidates`.

---

## Step 3: SPIKE

### For each candidate (score >= 2.5)

**Principle:** prove the hypothesis in ≤ 30 min without risk to the production system.

**Isolation:**
- Tool/script: test in `/tmp/spike-{tool}-{date}/`
- Code: git worktree (if repo changes are needed)
- Do NOT touch production files during the spike

**Spike steps:**

1. **State the hypothesis** (1-2 sentences of what you want to prove):

   ```
   "If we use X, then Y improves from A to B"
   ```

2. **State success criteria** (binary, before running):

   ```
   - [ ] Works without Docker
   - [ ] Install < 10 min
   - [ ] Basic function works
   - [ ] API/CLI exists
   ```

3. **Run the spike:**

   ```bash
   cd /tmp/spike-{tool}-$(date +%Y%m%d)
   # install, configure, test
   ```

4. **Record the result:**

   ```
   Hypothesis: [what we tested]
   Result: PASS | FAIL
   Evidence: [what we did and what we got]
   Time spent: [min]
   ```

**If the spike runs >30 min** — stop, record `TIMEOUT`, create a separate task in your tracker.

**Max spikes per run:** 2 (so the strategist-worker fits in ~30 min).

---

## Step 4: INTEGRATE

**On PASS:**

1. Create a task in the tracker:

   ```
   mcp__saga-mcp__task_create(
     epic_id: <Infra epic id>,  // resolve via memory/epic-map.json
     title: "Integrate [tool]: [one-line of what it adds]",
     description: "Spike PASSED [date]. Evidence: [link to history]. Scope: [what to do]",
     priority: "medium"
   )
   ```

2. Update `memory/context.md` if this changes system status

3. Add to staging (if it confirms a pattern):

   ```
   memory/patterns-staging.md → new entry
   ```

**On FAIL:**

1. Record in improvement history (Step 5) with a reason
2. Do NOT create a task
3. Mark candidate as `rejected: [reason]` in the history file

**On TIMEOUT:**

1. Create a `priority: low` task — investigate further
2. Record as `deferred` in history

---

## Step 5: MEASURE + HISTORY

### Improvement-history entry

File: `research/self-improvement-history/{YYYY-MM}.md`
(one file per month, candidates appended)

```markdown
## [YYYY-MM-DD] — [candidate name]

**Area:** A/B/C/D
**Source:** [where the idea came from]
**Score:** [fit+impact/effort = X]
**Spike result:** PASS | FAIL | TIMEOUT | SKIPPED
**Hypothesis:** [what we tested]
**Evidence:** [what we got]
**Outcome:** integrate | reject | defer
**Tracker task:** #[id] | none
**Time spent:** [min]

**Baseline metric (before):** [what we measured, if applicable]
**Target metric (after):** [expected improvement]
**Actual metric:** [fill in on the next run]
```

### Check previous integrations

On every run — read history for the last month:
- Are there tasks with `Outcome: integrate` and an empty `Actual metric`?
- If the task is already done → fill in `Actual metric`
- Compare baseline vs actual → delta

---

## Run algorithm

```
1. Read memory/learnings.md + memory/patterns.md (error context)
2. SCAN: collect candidates (infra + business + productivity + internal analytics)
3. EVALUATE: filter, score top-2 → Spike
4. SPIKE: test in /tmp, max 30 min, binary result
5. INTEGRATE: create tracker task on PASS
6. MEASURE: update history, fill in actual metrics for prior integrations
7. Record in research/self-improvement-history/{YYYY-MM}.md
8. Update check-log.md self-improvement-loop row
```

---

## "Don't waste time" filter

Same constraints as self-upgrade-scan, plus:
- Tools enterprise-only ($500+/mo) → skip
- Requires stack swap (replace launchd with Kubernetes) → skip
- Duplicates something already in the repo (glob-check before spike)
- Marketing tools without API/CLI → skip

---

## Output

Brief report at `logs/workers/self-improv-agent/result.md`:

```
## Self-Improvement Loop — {date}

### Candidates after Evaluate
- **[tool]** — score: X, verdict: spike/skip

### Spike results
- **[tool]** — PASS/FAIL. Evidence: [1-2 lines]

### Integrations
- Tracker task #[id]: [title]

### Measure
- [tool from a past run] — baseline: X, actual: Y, delta: Z%

### Summary
[1-2 sentences: did we find anything worthwhile or not]
```

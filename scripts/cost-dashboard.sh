#!/bin/bash
# AgentOS Cost Dashboard
# Usage: bash scripts/cost-dashboard.sh [days]
# Shows total spend and breakdown across workers + dispatcher cycles.

DAYS="${1:-7}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$REPO_ROOT" || exit 1

python3 << PYEOF
import json, glob, os, time
from collections import defaultdict
from datetime import datetime, timedelta

DAYS = $DAYS
cutoff = time.time() - DAYS * 86400

# --- Worker category map ---
# Customize these patterns for YOUR worker slugs. The dispatcher names workers
# by task slug (saga task title fragment), so categorize by substring match.
# Default categories below cover the common AgentOS-shipped patterns; add your
# own domain categories ("outreach", "research", "scraping", etc.) by editing
# the if/elif chain in classify_slug().
def classify_slug(slug):
    if "ci-status" in slug:    return "ci-status"
    if "morning" in slug:      return "morning-brief"
    if "pr-review" in slug:    return "pr-review"
    if "telegram" in slug:     return "telegram"
    if "strateg" in slug:      return "strategist"
    if "insights" in slug:     return "insights"
    if "upgrade-scan" in slug: return "upgrade-scan"
    if any(x in slug for x in ["dispatch", "workers-max", "night-mode"]):
        return "agentos-infra"
    return "other"

# Workers
wtotal = 0
by_type = defaultdict(lambda: {"count": 0, "cost": 0})
worker_items = []

for f in glob.glob("logs/workers/*/iter-*-cost.json"):
    try:
        mtime = os.path.getmtime(f)
        if mtime < cutoff:
            continue
        with open(f) as fh:
            d = json.load(fh)
        cost = d.get("total_cost_usd", 0)
        wtotal += cost
        slug = f.split("/")[2]
        worker_items.append((cost, slug, d.get("duration_ms", 0)/1000))
        cat = classify_slug(slug)
        by_type[cat]["count"] += 1
        by_type[cat]["cost"] += cost
    except: pass

# Dispatcher
dtotal = 0
dcount = 0
for f in glob.glob("logs/dispatcher/*/*.jsonl"):
    try:
        if os.path.getmtime(f) < cutoff:
            continue
        with open(f) as fh:
            for line in fh:
                try:
                    m = json.loads(line)
                    if m.get("type") == "result":
                        dtotal += m.get("total_cost_usd", 0)
                        dcount += 1
                        break
                except: pass
    except: pass

total = wtotal + dtotal
daily = total / DAYS if DAYS else 0

print(f"=== AgentOS Cost Dashboard — last {DAYS}d ===")
print(f"TOTAL:      \${total:>7.2f}  (avg \${daily:.2f}/day, projected \${daily*30:.0f}/mo)")
print(f"Dispatcher: \${dtotal:>7.2f}  ({dcount} cycles, avg \${dtotal/dcount if dcount else 0:.3f}/cycle)")
print(f"Workers:    \${wtotal:>7.2f}  ({sum(d['count'] for d in by_type.values())} iterations)")
print()
print("By category:")
print(f"  {'Category':<22} {'Count':>6} {'Cost \$':>10} {'Avg \$':>8}")
for cat, d in sorted(by_type.items(), key=lambda x: -x[1]["cost"]):
    avg = d["cost"] / d["count"] if d["count"] else 0
    print(f"  {cat:<22} {d['count']:>6} {d['cost']:>10.2f} {avg:>8.3f}")
print()
print("Top 10 expensive workers:")
worker_items.sort(reverse=True)
for cost, slug, dur in worker_items[:10]:
    print(f"  \${cost:>6.2f} | {dur:>5.0f}s | {slug}")
PYEOF

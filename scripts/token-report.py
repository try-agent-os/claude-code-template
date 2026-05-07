#!/usr/bin/env python3
"""
token-report.py — AgentOS cost report generator

Parses dispatcher JSONL and worker cost JSON files to produce a cost summary.

Usage:
  python3 scripts/token-report.py             # today's report
  python3 scripts/token-report.py --all       # all days
  python3 scripts/token-report.py --day 2026-04-07  # specific day
"""

import sys
import os
import json
import glob
import argparse
from collections import defaultdict
from datetime import datetime, date

# --- Pricing (claude-sonnet-4-6) ---
PRICE_INPUT_PER_MTok   = 3.00    # $/MTok direct input
PRICE_CACHE_READ_PER_MTok = 0.30 # $/MTok cache read (1h ephemeral)
PRICE_CACHE_WRITE_PER_MTok = 3.75 # $/MTok cache write (1h ephemeral)
PRICE_OUTPUT_PER_MTok  = 15.00   # $/MTok output

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def calc_cost(input_tok, cache_read_tok, cache_write_tok, output_tok):
    """Recalculate cost from token counts (verification / estimation)."""
    return (
        input_tok      * PRICE_INPUT_PER_MTok   / 1_000_000 +
        cache_read_tok * PRICE_CACHE_READ_PER_MTok / 1_000_000 +
        cache_write_tok * PRICE_CACHE_WRITE_PER_MTok / 1_000_000 +
        output_tok     * PRICE_OUTPUT_PER_MTok   / 1_000_000
    )


def parse_dispatcher_day(day_dir):
    """Parse all JSONL files in a dispatcher day directory. Returns list of session dicts."""
    sessions = []
    for f in sorted(glob.glob(os.path.join(day_dir, "*.jsonl"))):
        session = None
        for line in open(f, errors="replace"):
            try:
                obj = json.loads(line)
                if obj.get("type") == "result" and session is None:
                    u = obj.get("usage", {})
                    session = {
                        "file": os.path.basename(f),
                        "cost_usd": obj.get("total_cost_usd", 0),
                        "turns": obj.get("num_turns", 0),
                        "duration_s": obj.get("duration_ms", 0) / 1000,
                        "input_tokens": u.get("input_tokens", 0),
                        "cache_read_tokens": u.get("cache_read_input_tokens", 0),
                        "cache_write_tokens": u.get("cache_creation_input_tokens", 0),
                        "output_tokens": u.get("output_tokens", 0),
                        "subtype": obj.get("subtype", ""),
                        "is_error": obj.get("is_error", False),
                    }
            except Exception:
                pass
        if session:
            sessions.append(session)
    return sessions


def parse_worker_costs(workers_dir):
    """Parse worker cost JSON files. Returns list of worker cost dicts."""
    workers = []
    for task_dir in sorted(os.listdir(workers_dir)):
        task_path = os.path.join(workers_dir, task_dir)
        if not os.path.isdir(task_path):
            continue
        # Look for iter-N-cost.json files
        for cost_file in sorted(glob.glob(os.path.join(task_path, "iter-*-cost.json"))):
            try:
                data = json.load(open(cost_file))
                workers.append({
                    "task_id": task_dir,
                    "iter_file": os.path.basename(cost_file),
                    "cost_usd": data.get("total_cost_usd", 0),
                    "input_tokens": data.get("usage", {}).get("input_tokens", 0),
                    "cache_read_tokens": data.get("usage", {}).get("cache_read_input_tokens", 0),
                    "cache_write_tokens": data.get("usage", {}).get("cache_creation_input_tokens", 0),
                    "output_tokens": data.get("usage", {}).get("output_tokens", 0),
                    "turns": data.get("num_turns", 0),
                })
            except Exception:
                pass
    return workers


def summarize_sessions(sessions):
    if not sessions:
        return None
    total_cost = sum(s["cost_usd"] for s in sessions)
    total_out = sum(s["output_tokens"] for s in sessions)
    total_cache_read = sum(s["cache_read_tokens"] for s in sessions)
    total_cache_write = sum(s["cache_write_tokens"] for s in sessions)
    avg_cost = total_cost / len(sessions)
    avg_turns = sum(s["turns"] for s in sessions) / len(sessions)
    errors = sum(1 for s in sessions if s["is_error"])
    return {
        "count": len(sessions),
        "total_cost_usd": total_cost,
        "avg_cost_usd": avg_cost,
        "avg_turns": avg_turns,
        "total_output_tokens": total_out,
        "total_cache_read_tokens": total_cache_read,
        "total_cache_write_tokens": total_cache_write,
        "errors": errors,
    }


def print_day_report(day, dispatcher_sessions, worker_sessions):
    d_sum = summarize_sessions(dispatcher_sessions)
    w_sum = summarize_sessions(worker_sessions) if worker_sessions else None

    print(f"\n{'='*60}")
    print(f"  DATE: {day}")
    print(f"{'='*60}")

    if d_sum:
        print(f"\n  DISPATCHER ({d_sum['count']} cycles)")
        print(f"    Total cost:       ${d_sum['total_cost_usd']:.4f}")
        print(f"    Avg cost/cycle:   ${d_sum['avg_cost_usd']:.4f}")
        print(f"    Avg turns/cycle:  {d_sum['avg_turns']:.1f}")
        print(f"    Cache read total: {d_sum['total_cache_read_tokens']:,} tok")
        print(f"    Cache write total:{d_sum['total_cache_write_tokens']:,} tok")
        print(f"    Output total:     {d_sum['total_output_tokens']:,} tok")
        print(f"    Errors:           {d_sum['errors']}")
        # Cost breakdown for avg cycle
        avg = d_sum['total_cost_usd'] / d_sum['count']
        avg_cr = d_sum['total_cache_read_tokens'] / d_sum['count']
        avg_cw = d_sum['total_cache_write_tokens'] / d_sum['count']
        avg_out = d_sum['total_output_tokens'] / d_sum['count']
        print(f"\n  Cost breakdown (per avg cycle):")
        print(f"    Cache read (~{avg_cr/1000:.0f}K tok): ${avg_cr * PRICE_CACHE_READ_PER_MTok / 1e6:.4f}")
        print(f"    Cache write (~{avg_cw/1000:.0f}K tok): ${avg_cw * PRICE_CACHE_WRITE_PER_MTok / 1e6:.4f}")
        print(f"    Output (~{avg_out/1000:.0f}K tok):     ${avg_out * PRICE_OUTPUT_PER_MTok / 1e6:.4f}")

    if w_sum:
        print(f"\n  WORKERS ({w_sum['count']} iterations)")
        print(f"    Total cost:       ${w_sum['total_cost_usd']:.4f}")
        print(f"    Avg cost/iter:    ${w_sum['avg_cost_usd']:.4f}")
    else:
        print(f"\n  WORKERS: no cost data (not yet instrumented)")

    total_day = (d_sum["total_cost_usd"] if d_sum else 0) + (w_sum["total_cost_usd"] if w_sum else 0)
    print(f"\n  TOTAL DAY: ${total_day:.4f}")
    print(f"  PROJECTED 24h (at current rate): ${total_day:.2f} actual")


def main():
    parser = argparse.ArgumentParser(description="AgentOS token cost report")
    parser.add_argument("--all", action="store_true", help="Report all days")
    parser.add_argument("--day", default=None, help="Specific day YYYY-MM-DD")
    args = parser.parse_args()

    dispatcher_log_dir = os.path.join(REPO, "logs", "dispatcher")
    workers_dir = os.path.join(REPO, "logs", "workers")

    if not os.path.isdir(dispatcher_log_dir):
        print(f"ERROR: dispatcher log dir not found: {dispatcher_log_dir}")
        sys.exit(1)

    today = date.today().strftime("%Y-%m-%d")

    if args.day:
        days_to_report = [args.day]
    elif args.all:
        days_to_report = sorted(os.listdir(dispatcher_log_dir))
    else:
        days_to_report = [today]

    all_totals = []

    for day in days_to_report:
        day_dir = os.path.join(dispatcher_log_dir, day)
        if not os.path.isdir(day_dir):
            print(f"\nNo data for {day}")
            continue
        d_sessions = parse_dispatcher_day(day_dir)
        w_sessions = parse_worker_costs(workers_dir)  # No day filter (workers don't have day subdirs)
        print_day_report(day, d_sessions, w_sessions)
        total = sum(s["cost_usd"] for s in d_sessions)
        all_totals.append((day, total))

    if len(all_totals) > 1:
        print(f"\n{'='*60}")
        print(f"  SUMMARY ({len(all_totals)} days)")
        grand_total = sum(t for _, t in all_totals)
        for day, total in all_totals:
            print(f"    {day}: ${total:.2f}")
        print(f"  GRAND TOTAL: ${grand_total:.2f}")
        print(f"  AVG/DAY:     ${grand_total/len(all_totals):.2f}")
        print(f"  EST/MONTH:   ${grand_total/len(all_totals)*30:.2f}")


if __name__ == "__main__":
    main()

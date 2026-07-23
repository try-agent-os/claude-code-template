#!/usr/bin/env python3
"""undelivered-work-sweep — did the fleet's work actually LAND on origin/main?

Failure class ("green /done, empty main"): a worker does real work, commits,
pushes its branch, comments `outcome: done | score: 5/5` on its task, kills its
tmux session — and the commits never reach origin/main. The task goes to
in_review, the DAG is green, the watchdog reports crash_rate=0, and the artifact
simply does not exist. Nothing in the fleet is looking at the one place where
the truth lives: the diff between what workers pushed and what main holds.

One known mechanism: a launcher that reuses a shared worktree path
/opt/agent-os/.worktrees/<slug> cuts the new branch from origin/main on top of
the previous tick's unmerged work — the reflog shows a single
`reset: moving to HEAD` and the previous commits become unreachable. But that is
one mechanism, found in one contour. This sweep deliberately does not model the
mechanism: it measures the OUTCOME fleet-wide, so a NEW way of losing work is
caught by the same probe.

Measured on a live install (window 7 days) the first time it ran: 44 of 140
pushed worker branches carried commits absent from main, and **30 files created
by workers never reached origin/main at all** — among them four meeting
debriefs, five proposals (which is why the strategist's own review queue looked
nearly empty), a research report, and — with some irony — the whole liveness
guard whose job was to detect a silently frozen queue. Not one monitor went red:
health-watchdog OK, drain-doctor OK, unit-supervision clean, and
skill-reference-check reported dangling=0 precisely BECAUSE the doc half of each
lost change vanished together with the code half.

What it reports, in order of how much you can trust it:

  lost_files    — files ADDED on an unmerged worker branch that do not exist on
                  origin/main at any path. Unambiguous: a squash-merge cannot
                  hide a file. This is what the exit code gates on.
  orphan_commits— commits with no patch-id equivalent in main. Informational
                  only: squashing a multi-commit branch legitimately changes the
                  patch-id, so this number over-counts and must never gate.

Anti-flood: the operator is alerted only when the lost-file SET GROWS versus the
previous run's manifest (same discipline as unit-supervision-check.sh). A
standing backlog is recorded, not re-shouted every morning.

Exit codes: 0 = nothing lost, 1 = lost files present, 2 = git plumbing failure.

Configuration:
  REPO_ROOT             repo to sweep      (default /opt/agent-os/claude)
  UNDELIVERED_MANIFEST  state file         (default
                        /var/lib/agent-os/undelivered-work.json)
  UNDELIVERED_GRACE_HOURS
                        a branch younger than this belongs to a LIVE worker and
                        is not yet a finding (default 3)

Usage:
  scripts/undelivered-work-sweep.py                 # human summary
  scripts/undelivered-work-sweep.py --json          # machine-readable
  scripts/undelivered-work-sweep.py --days 14       # widen the window
  scripts/undelivered-work-sweep.py --no-notify     # never touch the operator
  scripts/undelivered-work-sweep.py --recover-cmds  # print recovery commands
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

REPO = os.environ.get("REPO_ROOT", "/opt/agent-os/claude")
MANIFEST = os.environ.get(
    "UNDELIVERED_MANIFEST", "/var/lib/agent-os/undelivered-work.json"
)
NOTIFY = f"{REPO}/scripts/notify-operator.sh"

# A branch pushed minutes ago by a LIVE worker has not merged yet and is not a
# finding. Only branches older than this are judged.
GRACE_HOURS = float(os.environ.get("UNDELIVERED_GRACE_HOURS", "3"))


def git(*args: str, check: bool = True) -> str:
    r = subprocess.run(
        ["git", *args], cwd=REPO, capture_output=True, text=True
    )
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout


def git_ok(*args: str) -> bool:
    return subprocess.run(
        ["git", *args], cwd=REPO, capture_output=True
    ).returncode == 0


def worker_branches(days: float) -> list[tuple[str, int, str]]:
    """(refname, committer_epoch, sha) for origin/worker/* inside the window."""
    out = git(
        "for-each-ref",
        "--sort=-committerdate",
        "--format=%(refname:short)|%(committerdate:unix)|%(objectname)",
        "refs/remotes/origin/",
    )
    now = time.time()
    rows = []
    for line in out.strip().splitlines():
        if not line:
            continue
        name, ts, sha = line.split("|")
        ts = int(ts)
        if not name.startswith("origin/worker/"):
            continue
        age_h = (now - ts) / 3600.0
        if age_h > days * 24 or age_h < GRACE_HOURS:
            continue
        rows.append((name, ts, sha))
    return rows


def sweep(days: float) -> dict:
    findings = []
    scanned = 0
    unmerged = 0
    for name, ts, sha in worker_branches(days):
        scanned += 1
        if git_ok("merge-base", "--is-ancestor", sha, "origin/main"):
            continue
        unmerged += 1

        # (1) file-adds absent from main — the hard signal
        added = [
            f
            for f in git(
                "diff", "--diff-filter=A", "--name-only", f"origin/main...{name}"
            ).split()
            if f
        ]
        lost = [f for f in added if not git_ok("cat-file", "-e", f"origin/main:{f}")]

        # (2) patch-id orphans — soft signal, squash-merges inflate it
        cherry = git("cherry", "origin/main", name, check=False).strip().splitlines()
        orphan = [c.split()[1] for c in cherry if c.startswith("+")]

        if not lost and not orphan:
            continue
        findings.append(
            {
                "branch": name,
                "pushed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts)),
                "age_days": round((time.time() - ts) / 86400.0, 1),
                "lost_files": sorted(lost),
                "orphan_commits": orphan,
                "subjects": [
                    git("log", "-1", "--format=%s", c).strip() for c in orphan
                ],
            }
        )

    all_lost = sorted({f for fi in findings for f in fi["lost_files"]})
    return {
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "window_days": days,
        "branches_scanned": scanned,
        "branches_unmerged": unmerged,
        "lost_file_count": len(all_lost),
        "lost_files": all_lost,
        "orphan_commit_count": sum(len(f["orphan_commits"]) for f in findings),
        "findings": findings,
    }


def recovery_commands(report: dict) -> list[str]:
    """Per lost file, the exact one-liner that puts it back on the branch."""
    cmds = []
    for f in report["findings"]:
        for path in f["lost_files"]:
            cmds.append(f"git checkout {f['branch']} -- {path}")
    return cmds


def notify(report: dict, new_files: list[str]) -> None:
    head = ", ".join(new_files[:4]) + (" …" if len(new_files) > 4 else "")
    msg = (
        f"{len(new_files)} new worker file(s) never reached origin/main "
        f"(total in a {report['window_days']:.0f}d window: "
        f"{report['lost_file_count']}).\n"
        f"New: {head}\n"
        f"Branches unmerged: {report['branches_unmerged']}/"
        f"{report['branches_scanned']}.\n"
        f"Manifest: {MANIFEST} · recover: "
        f"scripts/undelivered-work-sweep.py --recover-cmds"
    )
    # notify-operator.sh takes FLAGS, not a positional message: a bare argv[1]
    # is swallowed by its `*) shift` arm and the run exits 0 with an empty $MSG,
    # i.e. a silent non-alert. Keep the flags.
    subprocess.run(
        [
            NOTIFY,
            "--source",
            "undelivered-work-sweep",
            "--severity",
            "warn",
            "--msg",
            msg,
        ],
        capture_output=True,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=float, default=7.0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-notify", action="store_true")
    ap.add_argument("--recover-cmds", action="store_true")
    ap.add_argument("--no-fetch", action="store_true")
    a = ap.parse_args()

    if not a.no_fetch:
        subprocess.run(
            ["git", "fetch", "origin", "--prune", "--quiet"],
            cwd=REPO,
            capture_output=True,
        )

    try:
        report = sweep(a.days)
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    prev: dict = {}
    try:
        with open(MANIFEST) as fh:
            prev = json.load(fh)
    except (OSError, ValueError):
        pass
    new_files = [f for f in report["lost_files"] if f not in set(prev.get("lost_files", []))]
    report["new_since_last_run"] = new_files

    try:
        os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
        with open(MANIFEST, "w") as fh:
            json.dump(report, fh, indent=2)
    except OSError as e:
        print(f"WARN: manifest not written: {e}", file=sys.stderr)

    if a.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    elif a.recover_cmds:
        for c in recovery_commands(report):
            print(c)
    else:
        print(
            f"=== undelivered-work-sweep === window={report['window_days']:.0f}d "
            f"branches={report['branches_scanned']} unmerged={report['branches_unmerged']} "
            f"lost_files={report['lost_file_count']} "
            f"orphan_commits={report['orphan_commit_count']} (soft)"
        )
        for f in report["findings"]:
            if not f["lost_files"]:
                continue
            print(f"\n  {f['pushed_at']}  {f['branch']}  ({f['age_days']}d)")
            for s in f["subjects"]:
                print(f"      · {s[:90]}")
            for p in f["lost_files"]:
                print(f"      LOST {p}")
        if not report["lost_file_count"]:
            print("  OK — every worker branch in the window landed on main")
        elif new_files:
            print(f"\n  NEW since last run: {len(new_files)}")

    if new_files and not a.no_notify:
        notify(report, new_files)

    return 1 if report["lost_file_count"] else 0


if __name__ == "__main__":
    sys.exit(main())

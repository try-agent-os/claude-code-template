#!/bin/bash
# inode-monitor.sh — guard against inode / disk exhaustion on the root FS.
#
# Why: an incident where the root FS hit 100% INODES (0 free) while plenty of
# bytes were still free — orphaned per-workspace git worktrees (.worktrees/*,
# each with its own node_modules) had accumulated over time. ENOSPC on *any*
# file create deadlocked the whole install (Bash harness, CLI tooling, all
# worker pipelines). df -h looked healthy the entire time — only df -i showed it.
#
# This monitor closes the blind spot: it alerts on BOTH low free inodes and low
# free bytes, via an optional notify hook (AGENT_OS_NOTIFY_HOOK; unset => log-only).
#
# Thresholds (env-overridable):
#   INODE_MIN_FREE   default 3000000  (~10% of a ~30M-inode FS) -> warn below
#   INODE_CRIT_FREE  default 1000000  -> error below
#   BYTES_MIN_PCT    default 90       (used% >= this -> warn on bytes)
# Exit 0 always (a monitor must never flap upstream). Silent when healthy.

set -uo pipefail

REPO_ROOT="${AGENT_OS_HUB:-/opt/agent-os/claude}"
# Optional alert hook. Set AGENT_OS_NOTIFY_HOOK to an executable accepting
# `--source <name> --severity <info|warn|error> --msg <text>`; unset => log-only.
NOTIFY="${AGENT_OS_NOTIFY_HOOK:-}"
LOG="/var/log/agent-os/inode-monitor.log"
MOUNT="/"

INODE_MIN_FREE="${INODE_MIN_FREE:-3000000}"
INODE_CRIT_FREE="${INODE_CRIT_FREE:-1000000}"
BYTES_MIN_PCT="${BYTES_MIN_PCT:-90}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# NOTE: GNU df refuses `-i` combined with `--output` ("mutually exclusive");
# the inode columns are selected by the --output field names themselves
# (itotal/iused/iavail/ipcent). A failed df leaves the read vars UNSET (bash
# read clears them on EOF), so every use below must be `${var:-...}`-guarded
# or the set -u shell dies mid-script.
# --- inodes ---
read -r _fs itot iused ifree ipcent _mnt < <(df --output=source,itotal,iused,iavail,ipcent,target "$MOUNT" 2>/dev/null | tail -1) || true
# --- bytes (1K blocks) ---
read -r _bfs btot bused bfree bpcent _bmnt < <(df --output=source,size,used,avail,pcent,target "$MOUNT" 2>/dev/null | tail -1) || true

bpcent_num="${bpcent:-}"; bpcent_num="${bpcent_num%\%}"
ts="$(date -u +%FT%TZ)"

is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

sev=""
msg=""

if ! is_num "${ifree:-}"; then
  # The monitor itself is blind — that's alert-worthy (this exact failure mode
  # shipped once: `df -i --output=...` errors out and ifree stays unset).
  sev="warn"
  msg="inode-monitor cannot parse df inode output on $MOUNT (ifree='${ifree:-}'). The inode guard is BLIND — check df/coreutils on the host."
elif [ "$ifree" -lt "$INODE_CRIT_FREE" ]; then
  sev="error"
  msg="INODE CRITICAL on $MOUNT (${_fs:-?}): free=$ifree (${ipcent:-?} used). Only $ifree inodes left of ${itot:-?} — file creates will start failing ENOSPC. Run worktree-janitor / du --inodes -x / to find the hog."
elif [ "$ifree" -lt "$INODE_MIN_FREE" ]; then
  sev="warn"
  msg="INODE low on $MOUNT (${_fs:-?}): free=$ifree (${ipcent:-?} used) of ${itot:-?}. Below ${INODE_MIN_FREE} floor. Likely orphaned worktrees/node_modules — worktree-janitor should reap them."
fi

# Bytes: only escalate if not already alerting on inodes (avoid double-ping).
if [ -z "$sev" ] && is_num "$bpcent_num" && [ "$bpcent_num" -ge "$BYTES_MIN_PCT" ]; then
  avail_gib="?"
  is_num "${bfree:-}" && avail_gib="$(( bfree / 1048576 ))"
  sev="warn"
  msg="DISK bytes high on $MOUNT (${_bfs:-?}): ${bpcent:-?} used, avail=${avail_gib}GiB. Above ${BYTES_MIN_PCT}% floor."
fi

if [ -n "$sev" ]; then
  echo "[$ts] $sev: $msg" >> "$LOG"
  [ -n "$NOTIFY" ] && [ -x "$NOTIFY" ] && "$NOTIFY" --source inode-monitor --severity "$sev" --msg "$msg" 2>>"$LOG" || true
else
  echo "[$ts] ok: inodes free=${ifree:-?} (${ipcent:-?}) bytes used=${bpcent:-?}" >> "$LOG"
fi

exit 0

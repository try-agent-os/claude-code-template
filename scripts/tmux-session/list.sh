#!/bin/bash
# list.sh — list tmux sessions on the shared socket.
#
# Usage:
#   list.sh [--filter <prefix>]
#
# Output: one JSON object per line (jsonlines), keys:
#   name, created, pid, running_command, last_activity, attached
#
# `created` is the session creation time (unix epoch from tmux).
# `pid` is the pid of the foreground process in the first pane.
# `running_command` is that process's `comm` (e.g. "claude", "bash").
# `last_activity` is tmux's session_activity (unix epoch) — updates on output.
# `attached` is 0/1.

source "$(dirname "$0")/_common.sh"

FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter) FILTER="${2:?--filter needs a prefix}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# tmux list-panes with custom format. Note: tmux does NOT expand `\t` in
# format strings — use a unique literal separator (`||`) instead and split
# manually with bash.
FMT='#{session_name}||#{session_created}||#{session_activity}||#{session_attached}||#{pane_pid}||#{pane_current_command}'

# `list-sessions` doesn't expose pane fields, so we use `list-panes -a` and
# filter to first pane per session (most worker sessions are single-pane).
ROWS=$(tx list-panes -a -F "$FMT" 2>/dev/null || true)

if [[ -z "$ROWS" ]]; then
  exit 0
fi

# Dedup: keep first pane per session_name.
declare -A seen
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  # Split on `||` — replace with $'\1' separator first, then read.
  parsed="${row//||/$'\1'}"
  IFS=$'\1' read -r name created activity attached pid cmd <<< "$parsed"
  [[ -z "$name" ]] && continue
  [[ -n "$FILTER" && "$name" != "$FILTER"* ]] && continue
  [[ -n "${seen[$name]:-}" ]] && continue
  seen[$name]=1

  # Build JSON via jq for proper escaping.
  jq -nc \
    --arg name "$name" \
    --argjson created "${created:-0}" \
    --argjson activity "${activity:-0}" \
    --argjson attached "${attached:-0}" \
    --arg pid "$pid" \
    --arg cmd "$cmd" \
    '{name:$name, created:$created, last_activity:$activity, attached:$attached, pid:($pid|tonumber? // 0), running_command:$cmd}'
done <<< "$ROWS"


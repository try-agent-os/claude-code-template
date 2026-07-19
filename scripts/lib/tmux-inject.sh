#!/usr/bin/env bash
# tmux-inject.sh — reliable native slash-command injection into a LIVE claude TUI.
#
# Sourced by operator-clear-inject.sh / operator-model-inject.sh and any other
# host-side consumer that drives a claude session over tmux. Not executable on its
# own.
#
# ── Why this exists ──────────────────────────────────────────────────────────
# Two independent failure modes have bitten native /clear + /model injection:
#
# 1. Paste-burst swallow (CC >= 2.1.212, 2026-07-17). A BURST of characters from
#    a single `tmux send-keys -l "<text>"` is treated as a bracketed PASTE and
#    never engages the slash-command parser. Fix: type ONE char at a time with a
#    small inter-key delay so each registers as a keystroke.
#
# 2. Busy-session queueing (2026-07-18). While claude is MID-TURN, text typed
#    into the composer is QUEUED as the next chat MESSAGE — a slash command typed
#    then is NOT executed; when the turn ends it is submitted as a literal
#    message. The operator received "/clear" as text (padded by the queued-msg
#    "❯ " indent) because /clear was injected while it was working. The old
#    verify (grep for the command text in the composer) could not tell "command
#    ready to execute" from "text queued as a message", so it false-positived,
#    pressed Enter, and delivered garbage.
#    Fix: gate on an IDLE composer BEFORE typing. If busy, interrupt (Esc) — the
#    user's /clear or /model intent supersedes the in-flight FOREGROUND turn
#    (background agents are unaffected) — then poll for idle. After an interrupt
#    the composer is RESTORED with the interrupted message, so always Ctrl-U to
#    wipe it before typing. Finally, verify the command sits at the START of the
#    composer input and that Enter did NOT queue it as a message.
#
# ── Composer anatomy (2.1.214) ───────────────────────────────────────────────
# The prompt renders as `❯` + U+00A0 (NBSP) as a decorative spacer, then the
# input. So the NBSP is part of the PROMPT, not the input — the input buffer for
# a healthy "/clear" is a clean "/clear". A busy session shows a live spinner
# timer "(<N>s · …)" / token counter (and, on some renders only, the legacy
# "esc to interrupt" hint); a queued message shows "Press up to edit queued
# messages".

# tmux_inject_slash <socket> <session> <command-text>
#   0 = typed, verified at start of composer, submitted, and NOT queued (success)
#   2 = typed but could not verify / got queued as a message (NOT a clean command)
#   3 = session stayed busy even after interrupt — did NOT inject (would queue)
#   1 = session not found / tmux error
tmux_inject_slash() {
  local socket="$1" session="$2" cmd="$3"
  local -a TB=(tmux -S "$socket")

  if ! "${TB[@]}" has-session -t "$session" 2>/dev/null; then
    echo "[tmux-inject] ERROR: session '$session' not found on socket '$socket'" >&2
    return 1
  fi

  # ── Idle gate ──────────────────────────────────────────────────────────────
  # A turn is in flight iff the pane shows the spinner's live elapsed-time timer
  # "(<N>s · ", a streaming token counter "<N> tokens", or the legacy
  # "esc to interrupt" hint. Do NOT rely on the legacy string alone: some CC
  # 2.1.x renders (verified live on CC 2.1.214, 2026-07-18) no longer print
  # "esc to interrupt" anywhere during a turn — busy looks like
  # "✢ …(2s · ↓ 119 tokens · thinking)" / "● Running …" — which left a
  # legacy-only gate a silent no-op there. On the hub's own render (same
  # 2.1.214) the shortcut bar DOES still show "esc to interrupt" mid-turn, so
  # here the extended pattern is a strict superset (forward-compat for the next
  # CC update that drops the legacy hint).
  _tmux_busy() { "${TB[@]}" capture-pane -p -t "$session" 2>/dev/null | grep -qiE 'esc to interrupt|\([0-9]+s |[0-9]+ tokens'; }
  if _tmux_busy; then
    echo "[tmux-inject] '$session' is busy — interrupting (Esc) to reach an idle composer" >&2
    "${TB[@]}" send-keys -t "$session" Escape 2>/dev/null || true
    local idle=""
    for _ in $(seq 1 12); do sleep 0.5; if ! _tmux_busy; then idle=1; break; fi; done
    if [ -z "$idle" ]; then
      echo "[tmux-inject] '$session' still busy 6s after interrupt — NOT injecting (would queue as a message)" >&2
      return 3
    fi
  fi

  local attempt delay i ch line
  for attempt in 1 2; do
    # Attempt 1: brisk (45ms). Attempt 2: slower (90ms) for a laggy TUI.
    if [ "$attempt" = 1 ]; then delay=0.045; else delay=0.09; fi

    # Always wipe the composer first: an Esc-interrupt RESTORES the interrupted
    # message into the composer, and a retry may hold swallowed partial text.
    # Ctrl-U clears the input line without disturbing the session (no Escape).
    "${TB[@]}" send-keys -t "$session" C-u 2>/dev/null || true
    sleep 0.2

    # Type one character at a time (defeats paste-burst detection).
    for (( i=0; i<${#cmd}; i++ )); do
      ch="${cmd:$i:1}"
      "${TB[@]}" send-keys -t "$session" -l "$ch" || { echo "[tmux-inject] ERROR: send-keys failed" >&2; return 1; }
      sleep "$delay"
    done
    sleep 0.5

    # Verify the command sits at the START of the composer input line. Take the
    # bottom-most prompt (❯) line, drop everything up to the arrow, convert the
    # NBSP spacer to a space, strip leading blanks — the remainder must BEGIN
    # with the command (a plain grep -F is too weak: it also matches restored
    # text like "…tea./clear" and the autocomplete description row).
    line="$("${TB[@]}" capture-pane -p -t "$session" 2>/dev/null | grep -a '❯' | tail -1 \
            | sed -E 's/.*❯//; s/\xc2\xa0/ /g; s/^ +//')"
    case "$line" in
      "$cmd"*)
        "${TB[@]}" send-keys -t "$session" Enter || { echo "[tmux-inject] ERROR: Enter failed" >&2; return 1; }
        sleep 0.4
        # Post-check: a busy session would QUEUE it instead of executing.
        if "${TB[@]}" capture-pane -p -t "$session" 2>/dev/null | grep -qiF "Press up to edit queued messages"; then
          echo "[tmux-inject] '$cmd' was QUEUED as a message (session went busy) — dequeuing, not confirmed" >&2
          "${TB[@]}" send-keys -t "$session" Up 2>/dev/null || true; sleep 0.2
          "${TB[@]}" send-keys -t "$session" C-u 2>/dev/null || true
          return 2
        fi
        echo "[tmux-inject] injected & verified '$cmd' into '$session' (attempt $attempt)" >&2
        return 0 ;;
    esac
    echo "[tmux-inject] attempt $attempt: '$cmd' not cleanly at composer start — retrying" >&2
  done

  # Neither attempt registered cleanly. Wipe the composer so no partial garbage
  # is submitted, and report unverified (do NOT submit).
  "${TB[@]}" send-keys -t "$session" C-u 2>/dev/null || true
  echo "[tmux-inject] FAILED to inject '$cmd' into '$session' after 2 attempts" >&2
  return 2
}

# tmux_confirm_switch_model <socket> <session>
#   After a /model inject, a mid-session switch pops a "Switch model?" cache-
#   invalidation dialog (preselected "Yes"). Confirm it ONLY if actually on
#   screen — a blind Enter could submit stray input. Poll ~3s.
tmux_confirm_switch_model() {
  local socket="$1" session="$2"
  local -a TB=(tmux -S "$socket")
  local _
  for _ in 1 2 3 4 5 6; do
    sleep 0.5
    if "${TB[@]}" capture-pane -p -t "$session" 2>/dev/null | grep -q "Switch model?"; then
      "${TB[@]}" send-keys -t "$session" Enter 2>/dev/null || true
      echo "[tmux-inject] confirmed 'Switch model?' dialog for '$session'" >&2
      return 0
    fi
  done
  return 0
}

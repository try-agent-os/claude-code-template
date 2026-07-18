#!/usr/bin/env bash
# tmux-inject.sh — reliable native slash-command injection into a LIVE claude TUI.
#
# Sourced by operator-clear-inject.sh / operator-model-inject.sh and any other
# host-side consumer that drives a claude session over tmux. Not executable on its
# own.
#
# ── Why this exists (CC 2.1.212 regression, 2026-07-17) ──────────────────────
# Claude Code >= 2.1.212 treats a BURST of characters delivered by a single
# `tmux send-keys -l "<text>"` as a bracketed PASTE: it inserts them as pasted
# content (rendered with a leading NBSP placeholder, U+00A0) instead of live
# keystrokes. A pasted "/clear" never engages the TUI's slash-command parser, so
# the command is swallowed / submitted as a literal message and nothing happens.
# This silently broke /clear and /model injection across every instance the night
# of the 2.1.211 -> 2.1.212 auto-update.
#
# Fix: type ONE character at a time with a small inter-key delay. That stays under
# the paste-burst heuristic, so each char registers as a keystroke and the
# slash-command autocomplete engages — exactly as if a human typed it. Verified
# live on 2.1.212: bulk `-l "/clear"` -> swallowed (composer shows only NBSP);
# char-by-char -> `<command-name>/clear</command-name>` recorded, context cleared.
#
# ── Verification (honest ack) ────────────────────────────────────────────────
# After typing (BEFORE Enter) the command text must be visible in the composer.
# In the swallow failure mode it is NOT (the composer holds only an NBSP), so a
# grep of the composer region cleanly distinguishes success from the paste bug.
# We only press Enter once the command is verified present — otherwise we would
# submit garbage into the session as a stray message. On failure we return 2 so
# the caller can send an honest "not confirmed" ack instead of a false success.

# tmux_inject_slash <socket> <session> <command-text>
#   0 = typed, verified in composer, and submitted (success)
#   2 = typed but NOT verified after retry (paste-swallow suspected) — NOT submitted
#   1 = session not found / tmux error
tmux_inject_slash() {
  local socket="$1" session="$2" cmd="$3"
  local -a TB=(tmux -S "$socket")

  if ! "${TB[@]}" has-session -t "$session" 2>/dev/null; then
    echo "[tmux-inject] ERROR: session '$session' not found on socket '$socket'" >&2
    return 1
  fi

  local attempt delay i ch
  for attempt in 1 2; do
    # Attempt 1: brisk (45ms) — enough to defeat paste-burst detection while
    # staying snappy. Attempt 2 (only if the first didn't register): slower
    # (90ms) for a laggy / heavily-loaded TUI.
    if [ "$attempt" = 1 ]; then delay=0.045; else delay=0.09; fi

    # On a retry the composer may hold a swallowed NBSP + partial text; kill the
    # input line first (Ctrl-U). We do NOT send Escape — that could interrupt an
    # in-flight operation in the target session. Ctrl-U only clears the prompt.
    if [ "$attempt" = 2 ]; then
      "${TB[@]}" send-keys -t "$session" C-u 2>/dev/null || true
      sleep 0.2
    fi

    # Type one character at a time.
    for (( i=0; i<${#cmd}; i++ )); do
      ch="${cmd:$i:1}"
      "${TB[@]}" send-keys -t "$session" -l "$ch" || { echo "[tmux-inject] ERROR: send-keys failed" >&2; return 1; }
      sleep "$delay"
    done
    sleep 0.5

    # Verify the command registered as live input: it must appear in the composer
    # region (bottom of the pane). Swallowed paste leaves only an NBSP there.
    if "${TB[@]}" capture-pane -p -t "$session" 2>/dev/null | tail -8 | grep -qF "$cmd"; then
      "${TB[@]}" send-keys -t "$session" Enter || { echo "[tmux-inject] ERROR: Enter failed" >&2; return 1; }
      echo "[tmux-inject] injected & verified '$cmd' into '$session' (attempt $attempt)" >&2
      return 0
    fi
    echo "[tmux-inject] attempt $attempt: '$cmd' not visible in composer — paste-swallow suspected" >&2
  done

  # Neither attempt registered. Clear whatever partial garbage is in the composer
  # so we don't leave a stuck NBSP, and report unverified (do NOT submit).
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

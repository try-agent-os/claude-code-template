#!/usr/bin/env bash
# consensus.sh — Anonymous Council multi-model consensus orchestrator.
#
# Cross-checks a decision against every CLI model you have logged in, without
# letting any single vendor own both the panel and the synthesis:
#   1. Independent fan-out (no debate by default) to every AVAILABLE CLI model.
#   2. Anonymize answers A/B/C/D, randomize order (kill position/identity bias).
#   3. Aggregator (not from the dominant family) emits a MAP, not a vote:
#        consensus / disagreements (verbatim, no averaging) / lone strong position.
#   4. Telegram-friendly HTML output.
#
# Why a map and not a vote: averaging N models hides exactly the information you
# came for. A lone dissent from one model is often the only real signal in the
# batch, and majority-voting deletes it.
#
# Models gracefully self-detect: each is probed; only those that answer cleanly
# join the council. Minimum is `claude`; codex/gemini/grok join as you sign into
# their CLIs. `claude-fable5` (Anthropic Claude Fable 5, Mythos-class) joins as a
# SEPARATE participant via `claude --model claude-fable-5` when the plan grants
# access; it self-detects like the rest and is skipped silently otherwise.
#
# CAUTION — vendor-family correlation: `claude` (default Opus) and
# `claude-fable5` are BOTH Anthropic → their errors/biases correlate
# (algorithmic monoculture). Two Anthropic voices must not also own the
# synthesis. So the aggregator is biased to a NON-Anthropic family (codex/gemini/
# grok) whenever one is available; Anthropic chairs only if nothing else is online.
#
# Usage:
#   scripts/consensus.sh "<question>" [--debate] [--models claude,claude-fable5,codex,gemini,grok]
#
# Env:
#   CONSENSUS_TIMEOUT=90        seconds per model call
#   CONSENSUS_FABLE5_ID         override the Fable 5 model id
#   CLAUDE_CONFIG_DIR           claude config dir (default: the agent-os server
#                               config if present, else claude's own default)
#
# Exit codes: 0 ok, 2 no models available, 3 bad usage.

set -uo pipefail

# ---- config -----------------------------------------------------------------
PER_MODEL_TIMEOUT="${CONSENSUS_TIMEOUT:-90}"   # seconds per model call
# Agent's claude config (must match the agent-os operator unit). Only exported
# when it actually exists: on a workstation checkout that path is absent, and
# exporting it anyway would point `claude -p` at an empty, unauthenticated
# config instead of letting it fall back to the user's own (~/.claude).
_AGENT_CFG="${CLAUDE_CONFIG_DIR:-/var/lib/agent-os/claude-config/server}"
[[ -d "$_AGENT_CFG" ]] && export CLAUDE_CONFIG_DIR="$_AGENT_CFG"
DEFAULT_MODELS="claude,claude-fable5,codex,gemini,grok"
# Exact model id verified by real call (bogus ids error, this one answers):
#   claude --model claude-fable-5 -p "reply OK"  -> "OK"
FABLE5_MODEL_ID="${CONSENSUS_FABLE5_ID:-claude-fable-5}"

# ---- host-namespace runner for non-claude CLIs --------------------------------
# Agents/workers run under systemd ProtectSystem=strict + ProtectHome=read-only:
# ~/.codex, ~/.gemini, ~/.grok are NOT in ReadWritePaths, so inside the unit's
# mount ns those dirs are ro. codex dies with "Read-only file system" (can't write
# sessions/sqlite state), gemini hangs forever (observed: council silently shrank
# to 2 same-vendor voices). These CLIs need rw state dirs → run them in the host
# (PID-1) mount namespace, same canon as tmux sessions.
# claude is NOT wrapped: its state lives in CLAUDE_CONFIG_DIR which IS writable.
# When the script already runs in host ns (~/.codex writable) HOSTNS stays empty.
declare -a HOSTNS=()
if [[ ! -w "$HOME/.codex" || ! -w "$HOME/.gemini" ]] \
   && sudo -n nsenter --mount=/proc/1/ns/mnt -- true 2>/dev/null; then
  # --wdns (not --wd!): cwd must resolve INSIDE the target ns; with --wd the cwd
  # fd comes from the sandbox ns and codex dies with ENOENT.
  HOSTNS=(sudo -n nsenter --mount=/proc/1/ns/mnt --wdns="$HOME" --
          sudo -u "$(id -un)" env HOME="$HOME"
          PATH="$HOME/.local/bin:$HOME/.grok/bin:/usr/bin:/bin")
fi

WORKDIR="$(mktemp -d /tmp/consensus.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

log() { printf '%s\n' "$*" >&2; }

# ---- arg parse --------------------------------------------------------------
QUESTION=""
DEBATE=0
MODELS_CSV="$DEFAULT_MODELS"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debate) DEBATE=1; shift ;;
    --models) MODELS_CSV="${2:-}"; shift 2 ;;
    --timeout) PER_MODEL_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) if [[ -z "$QUESTION" ]]; then QUESTION="$1"; else QUESTION="$QUESTION $1"; fi; shift ;;
  esac
done

if [[ -z "${QUESTION// /}" ]]; then
  log "ERROR: no question. Usage: consensus.sh \"<question>\" [--debate]"
  exit 3
fi

IFS=',' read -r -a REQ_MODELS <<< "$MODELS_CSV"

# ---- settings-validation before invoking claude ----------------------------
# Prevents a blocking "Settings Warning" dialog that would cause the claude call
# to hang if settings.json contains invalid permission rules (wildcard MCP scope).
if printf '%s\n' "${REQ_MODELS[@]}" | grep -qE '^(claude|claude-fable5)$'; then
  _cfg="${CLAUDE_CONFIG_DIR:-}"
  if [[ -n "$_cfg" ]]; then
    _validate_py="$(cd "$(dirname "$0")" && pwd)/validate-worker-settings.py"
    if [[ -f "$_validate_py" ]] && ! python3 "$_validate_py" "$_cfg" >/dev/null 2>&1; then
      log "ERROR: invalid settings.json in ${_cfg} — claude -p would hang; aborting"
      exit 3
    fi
  fi
fi

# ---- per-model invocation ----------------------------------------------------
# call_model <model> <prompt-file> -> prints answer to stdout, exit 0 on success.
# Each is wrapped in `timeout`. Success is judged by CONTENT, not exit code,
# because some CLIs (codex) exit 0 even on a 401 auth failure.
call_model() {
  local model="$1" pf="$2" out
  case "$model" in
    claude)
      out="$(timeout "$PER_MODEL_TIMEOUT" claude -p "$(cat "$pf")" 2>/dev/null)"
      ;;
    claude-fable5)
      # Anthropic Claude Fable 5 — explicit --model. If the plan lacks access the
      # CLI prints "...may not exist or you may not have access..." which
      # answer_is_valid() catches as the "no access / not found" marker → skipped.
      out="$(timeout "$PER_MODEL_TIMEOUT" claude --model "$FABLE5_MODEL_ID" -p "$(cat "$pf")" 2>/dev/null)"
      ;;
    codex)
      # </dev/null: codex exec reads stdin when it's not a TTY and can block.
      out="$(timeout "$PER_MODEL_TIMEOUT" "${HOSTNS[@]}" codex exec --skip-git-repo-check \
              -c 'sandbox_mode="read-only"' "$(cat "$pf")" </dev/null 2>/dev/null)"
      ;;
    gemini)
      out="$(timeout "$PER_MODEL_TIMEOUT" "${HOSTNS[@]}" gemini -p "$(cat "$pf")" </dev/null 2>/dev/null)"
      ;;
    grok)
      # grok with no auth opens an interactive sign-in and hangs; timeout guards it.
      out="$(timeout "$PER_MODEL_TIMEOUT" "${HOSTNS[@]}" grok -p "$(cat "$pf")" </dev/null 2>/dev/null)"
      ;;
    *) return 1 ;;
  esac
  printf '%s' "$out"
}

# answer_is_valid <text> -> 0 if it looks like a real model answer (not an
# auth/error blurb). Heuristic: non-empty, and not dominated by known error markers.
answer_is_valid() {
  local t="$1"
  [[ -n "${t// /}" ]] || return 1
  local low; low="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
  case "$low" in
    *401\ unauthorized*|*"missing bearer"*|*"reconnecting..."*) return 1 ;;
    *"manual authorization is required"*|*"non-interactive"*) return 1 ;;
    *"open this url to sign in"*|*"signing in with grok"*) return 1 ;;
    *"please run"*"interactive"*) return 1 ;;
    *"command not found"*|*"not found in"*) return 1 ;;
    *"may not exist or you may not have access"*) return 1 ;;  # claude --model on no-access
    *"subscription required"*|*'"http_status"'*) return 1 ;;   # grok 403 (higher tier required)
    *"read-only file system"*) return 1 ;;                     # CLI ran in sandboxed mount ns
    # Quota/limit blurbs: the CLI exits 0 and prints a plain-English notice, so
    # without these markers it is indistinguishable from a real answer and gets
    # seated on the council (observed live: a "reached your limit" notice was
    # synthesised as if it were the chair's verdict).
    *"you've reached your"*"limit"*|*"usage limit"*|*"rate limit"*) return 1 ;;
    *"quota exceeded"*|*"insufficient credit"*|*"out of credit"*) return 1 ;;
  esac
  return 0
}

# ---- STAGE 0/1: probe + independent fan-out ---------------------------------
# We combine probe + real answer in one shot: ask the actual question; if the
# output is a valid answer the model is "available". Cheaper than a separate probe.

PROMPT_FILE="$WORKDIR/prompt.txt"
cat > "$PROMPT_FILE" <<EOF
Answer the question below independently and on the merits. State your position
with brief reasoning (2-6 sentences), no filler. If the question is a values or
strategy call, name the key trade-off. Reply in the language of the question.

QUESTION:
$QUESTION
EOF

log "[consensus] fan-out to: ${REQ_MODELS[*]} (timeout ${PER_MODEL_TIMEOUT}s each)"

declare -a PIDS=()
declare -a PMODELS=()
for m in "${REQ_MODELS[@]}"; do
  m="${m// /}"; [[ -z "$m" ]] && continue
  (
    ans="$(call_model "$m" "$PROMPT_FILE")"
    printf '%s' "$ans" > "$WORKDIR/ans.$m"
  ) &
  PIDS+=("$!"); PMODELS+=("$m")
done
for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null; done

# Collect valid answers.
declare -a OK_MODELS=()
declare -a SKIPPED=()
for m in "${PMODELS[@]}"; do
  f="$WORKDIR/ans.$m"
  ans="$(cat "$f" 2>/dev/null)"
  if answer_is_valid "$ans"; then
    OK_MODELS+=("$m")
    log "[consensus]   $m -> ok (${#ans} chars)"
  else
    SKIPPED+=("$m")
    log "[consensus]   $m -> skip (unavailable / empty / auth)"
  fi
done

N="${#OK_MODELS[@]}"
if [[ "$N" -eq 0 ]]; then
  log "ERROR: no models available."
  echo "❌ No council: not a single model answered (claude/codex/gemini/grok all unavailable)."
  exit 2
fi

# ---- STAGE 2: anonymize + randomize order -----------------------------------
# Shuffle OK_MODELS, assign labels A/B/C/D in shuffled order.
mapfile -t SHUF < <(printf '%s\n' "${OK_MODELS[@]}" | shuf)
LABELS=(A B C D E F)
ANON_FILE="$WORKDIR/anon.txt"
: > "$ANON_FILE"
i=0
for m in "${SHUF[@]}"; do
  lbl="${LABELS[$i]}"
  {
    printf '### Answer %s\n' "$lbl"
    cat "$WORKDIR/ans.$m"
    printf '\n\n'
  } >> "$ANON_FILE"
  i=$((i+1))
done

# ---- STAGE 2.5 (optional --debate): one anonymous revision round -------------
if [[ "$DEBATE" -eq 1 && "$N" -ge 2 ]]; then
  log "[consensus] debate round (anonymous, 1 pass) — WARNING: conformity risk"
  DEBATE_PROMPT="$WORKDIR/debate.txt"
  cat > "$DEBATE_PROMPT" <<EOF
Question: $QUESTION

Below are several anonymous answers from different experts (A/B/C/...). Read them
and give your REVISED answer: keep what you are confident in, take on board the
strong arguments of others, but do NOT conform to the majority for the sake of
agreement — if you are right in the minority, hold your position and explain why.
2-6 sentences.

$(cat "$ANON_FILE")
EOF
  declare -a DPIDS=()
  for m in "${SHUF[@]}"; do
    ( ans="$(call_model "$m" "$DEBATE_PROMPT")"
      answer_is_valid "$ans" && printf '%s' "$ans" > "$WORKDIR/ans.$m" ) &
    DPIDS+=("$!")
  done
  for pid in "${DPIDS[@]}"; do wait "$pid" 2>/dev/null; done
  # rebuild anon file with revised answers (same labels/order)
  : > "$ANON_FILE"; i=0
  for m in "${SHUF[@]}"; do
    lbl="${LABELS[$i]}"
    { printf '### Answer %s\n' "$lbl"; cat "$WORKDIR/ans.$m"; printf '\n\n'; } >> "$ANON_FILE"
    i=$((i+1))
  done
fi

# ---- STAGE 3: pick aggregator (not from dominant family) --------------------
# Family map: claude & claude-fable5 = anthropic (SAME family!), codex=openai,
# gemini=google, grok=xai. Two Anthropic proposers (default Opus + Fable5)
# correlate (algorithmic monoculture) — they must NOT also chair the synthesis,
# or Anthropic dominates both the panel and the gavel. So we force a NON-Anthropic
# aggregator whenever one is online; Anthropic chairs only as last resort.
family_of() { case "$1" in claude|claude-fable5) echo anthropic;; codex) echo openai;; gemini) echo google;; grok) echo xai;; *) echo other;; esac; }

# Count families among OK models; dominant = most frequent. With both Anthropic
# voices present, anthropic is usually dominant → aggregator picked from elsewhere.
declare -A FAMCOUNT=()
for m in "${OK_MODELS[@]}"; do f="$(family_of "$m")"; FAMCOUNT[$f]=$(( ${FAMCOUNT[$f]:-0} + 1 )); done
DOM_FAM=""; DOM_N=0
for f in "${!FAMCOUNT[@]}"; do (( FAMCOUNT[$f] > DOM_N )) && { DOM_N=${FAMCOUNT[$f]}; DOM_FAM=$f; }; done

# Preference order for chairman: non-Anthropic reasoning models first (gemini, grok,
# codex), so the synthesis is independent of the (correlated) Anthropic proposers.
# Only fall back to an Anthropic chair if no other family is online.
AGG=""
for cand in gemini grok codex; do
  for m in "${OK_MODELS[@]}"; do
    [[ "$m" == "$cand" ]] && { AGG="$cand"; break 2; }
  done
done
# Fallback: nothing non-Anthropic online → chair with an Anthropic model
# (prefer default claude over fable5 for the gavel, arbitrary but stable).
if [[ -z "$AGG" ]]; then
  for cand in claude claude-fable5; do
    for m in "${OK_MODELS[@]}"; do [[ "$m" == "$cand" ]] && { AGG="$cand"; break 2; }; done
  done
fi

log "[consensus] aggregator: $AGG  (dominant family: $DOM_FAM)"

SYNTH_PROMPT="$WORKDIR/synth.txt"
cat > "$SYNTH_PROMPT" <<EOF
You are the chair of a council of experts. You are given a question and SEVERAL
ANONYMOUS answers (A/B/C/...). You do NOT know which model gave which answer —
and you must not guess.

Your job is NOT to vote and NOT to average, but to produce a MAP of agreement and
disagreement. Follow the format below strictly (keep the HTML <b> tags as-is, no
markdown asterisks, no code blocks):

✅ <b>Consensus</b>
— what they actually converged on (>= a majority). Brief, bulleted. The part that
can be relied on. If there is almost no consensus, say so honestly: "little convergence".

⚠️ <b>Disagreements</b>
— every differing position VERBATIM, bulleted, without averaging and without
picking a "correct" one. This is the zone where the human decides. Do not smooth
it over, do not drop the minority.

💡 <b>Lone strong position</b>
— if ONE answer made a valuable argument or took an angle the others missed, call
it out separately. If there is none, write "none".

Rules: do not reveal or guess the authors; do not add your own opinion as a
separate voice; no preamble or conclusion outside the three blocks; reply in the
language of the question.

QUESTION:
$QUESTION

ANONYMOUS ANSWERS:
$(cat "$ANON_FILE")
EOF

SYNTH="$(call_model "$AGG" "$SYNTH_PROMPT")"
if ! answer_is_valid "$SYNTH"; then
  # Aggregator failed — fall back to an Anthropic chair (claude, else fable5),
  # then to raw dump. Last-resort only; non-Anthropic was already preferred above.
  for fb in claude claude-fable5; do
    [[ "$AGG" == "$fb" ]] && continue
    for m in "${OK_MODELS[@]}"; do
      if [[ "$m" == "$fb" ]]; then
        AGG="$fb"; SYNTH="$(call_model "$fb" "$SYNTH_PROMPT")"
        answer_is_valid "$SYNTH" && break 2
      fi
    done
  done
fi

# ---- STAGE 4: output --------------------------------------------------------
PARTICIPANTS="$(IFS=', '; echo "${OK_MODELS[*]}")"
PARTICIPANTS="${PARTICIPANTS//  / }"
# pretty comma-join
PRETTY="$(printf '%s, ' "${OK_MODELS[@]}")"; PRETTY="${PRETTY%, }"

echo "🧠 <b>Council of agents</b>"
echo "<i>question:</i> $QUESTION"
echo ""
if answer_is_valid "$SYNTH"; then
  printf '%s\n' "$SYNTH"
else
  # last-resort: show anonymized raw answers
  echo "(aggregator did not answer — raw answers below)"
  echo ""
  cat "$ANON_FILE"
fi
echo ""
echo "—"
echo "participants: $PRETTY (aggregator: $AGG)"
if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
  sk="$(printf '%s, ' "${SKIPPED[@]}")"; sk="${sk%, }"
  echo "did not join (no login / timeout): $sk"
fi
if [[ "$N" -lt 3 ]]; then
  echo "⚠️ fewer than 3 models — low diversity, treat the map with caution. More models join as you sign into their CLIs (codex / gemini / grok)."
fi
exit 0

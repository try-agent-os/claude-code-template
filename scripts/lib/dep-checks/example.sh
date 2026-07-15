#!/bin/bash
# example.sh — a drop-in dependency check. COPY, DON'T EDIT.
#
# Makes `--require-dep example` work in any routine (see check-fire.sh). To add
# your own dependency:
#
#   cp scripts/lib/dep-checks/example.sh scripts/lib/dep-checks/<dep>.sh
#   chmod +x scripts/lib/dep-checks/<dep>.sh
#   # write the probe; exit 0 = alive, exit 1 = dead (reason on stderr)
#   scripts/lib/dep-reachable.sh <dep>   # test it directly
#
# The contract:
#   exit 0            dependency is usable right now
#   exit 1            it is not; print WHY on stderr — that line is what a human
#                     sees in the scheduler log when a check stops firing
#   fast              this runs on every tick of every gated routine; probe, do
#                     not do work. Respect $DEP_TIMEOUT_SEC on anything network.
#   no side effects   a probe that writes state makes the gate itself a source
#                     of bugs
#
# Provided in the environment by dep-reachable.sh:
#   REPO_ROOT          absolute path to the repo
#   AGENT_OS_ENV_FILE  env file holding tokens
#   DEP_TIMEOUT_SEC    seconds to allow a network probe
#
# Prefer probing the SAME path the real work uses (the CLI, the wrapper script),
# not a hand-rolled equivalent — otherwise the gate can pass while the actual
# call fails, which is worse than having no gate at all.
set -uo pipefail

# Real examples of the shape:
#
#   # A binary must exist:
#   command -v tdl >/dev/null 2>&1 || { echo "dep[tdl]: not installed" >&2; exit 1; }
#
#   # A wrapper script must succeed (best: it IS the path the work takes):
#   "$REPO_ROOT/scripts/calendar-agenda.sh" --today >/dev/null 2>&1 \
#     || { echo "dep[calendar]: agenda read failed" >&2; exit 1; }
#
#   # A token must still be valid — cheapest authenticated endpoint, with timeout:
#   timeout "${DEP_TIMEOUT_SEC:-10}" curl -fsS -o /dev/null \
#     -H "Authorization: $SOME_TOKEN" https://api.example.com/v1/me \
#     || { echo "dep[example]: API unauthorized or unreachable" >&2; exit 1; }

echo "dep[example]: this is the template check — copy it, don't gate on it" >&2
exit 1

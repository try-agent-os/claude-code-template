#!/usr/bin/env bash
# PreToolUse hook for Bash — security gate.
#
# Blocks destructive patterns even under --dangerously-skip-permissions.
# managed-settings.json `permissions.deny` covers most catastrophic patterns
# declaratively (curl|sh, rm -rf /, fork bomb). This hook adds runtime checks
# for patterns that gitignore-style rules can't catch (e.g. compound chains,
# wrapper-stripped commands).
#
# Exit 2 ALWAYS blocks the tool call — including under bypassPermissions mode.

set -uo pipefail

HOOK_NAME="guard-bash"
. "${CLAUDE_PROJECT_DIR}/.claude/hooks/_common.sh"
read_input

CMD="$(tool_input_field 'command')"

if [ -z "$CMD" ]; then
  exit 0
fi

log "$CMD"

# Strip common wrappers Claude Code already strips for permission matching, but
# our blanket case statements may not — be defensive.
STRIPPED="$CMD"
for wrapper in "timeout " "time " "nice " "nohup " "stdbuf "; do
  STRIPPED="${STRIPPED#${wrapper}*}"
done

# ---- Hard-block patterns ----

# Recursive root/home deletes (defense in depth — managed-settings should also deny)
case "$STRIPPED" in
  *"rm -rf /"*|*"rm -rf /*"*|*"rm -rf ~"*|*"rm -rf \$HOME"*|*"rm -rf /etc"*|*"rm -rf /usr"*|*"rm -rf /var"*|*"rm -rf /boot"*)
    block "Refused destructive root/home delete: '$CMD'."
    ;;
esac

# Pipe-to-shell from network
case "$STRIPPED" in
  *"curl "*"| sh"*|*"curl "*"| bash"*|*"curl "*"|sh"*|*"curl "*"|bash"*|*"wget "*"| sh"*|*"wget "*"| bash"*|*"wget "*"|sh"*|*"wget "*"|bash"*)
    block "Refused 'curl|sh' / 'wget|sh' pattern: download, inspect, then run explicitly."
    ;;
esac

# Fork bomb / DoS
case "$STRIPPED" in
  *":(){"*":|:&"*"};:"*)
    block "Refused fork-bomb pattern."
    ;;
esac

# Disk overwrite
case "$STRIPPED" in
  *"dd if=/dev/zero of=/dev/"*|*"dd if=/dev/"*"of=/dev/sd"*|*"mkfs"*"/dev/sd"*|*"mkfs.ext"*"/dev/"*)
    block "Refused raw-device write (dd/mkfs)."
    ;;
esac

# Permission changes on system root
case "$STRIPPED" in
  *"chmod -R 777 /"*|*"chmod 777 -R /"*)
    block "Refused chmod 777 on /."
    ;;
  *"chown -R "*" /"*)
    case "$STRIPPED" in
      *"chown -R "*" /tmp"*|*"chown -R "*" /home"*|*"chown -R "*" /var/lib/agent-os"*) ;;
      *) block "Refused chown -R on system root." ;;
    esac
    ;;
esac

# History manipulation
case "$STRIPPED" in
  *"history -c"*|*">  ~/.bash_history"*|*"> ~/.bash_history"*)
    block "Refused shell history manipulation."
    ;;
esac

# Git destructive on protected branches
case "$STRIPPED" in
  *"git push --force "*|*"git push -f "*)
    case "$STRIPPED" in
      *" main"*|*" master"*|*" production"*|*" prod"*|*" release"*)
        block "Refused force-push to protected branch."
        ;;
    esac
    ;;
  *"git reset --hard origin/main"*|*"git reset --hard origin/master"*)
    block "Refused 'git reset --hard origin/{main,master}' — discards local commits silently."
    ;;
esac

# All checks passed
exit 0

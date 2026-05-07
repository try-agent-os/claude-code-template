#!/bin/bash
# UserPromptSubmit hook: injects current time into every operator prompt.
# Timezone read from $OPERATOR_TZ (set by install.sh / EnvironmentFile);
# falls back to UTC.

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

# Skip empty prompts
[ -z "$PROMPT" ] && exit 0

TZ_VAR="${OPERATOR_TZ:-UTC}"
CURRENT_TIME=$(TZ="$TZ_VAR" date '+%Y-%m-%d %H:%M %Z')
CONTEXT="[Current user time: $CURRENT_TIME]"

ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
echo "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":$ESCAPED}}"

exit 0

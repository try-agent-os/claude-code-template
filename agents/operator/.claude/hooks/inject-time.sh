#!/bin/bash
# UserPromptSubmit: инжектирует текущее время в каждый промпт operator'а.
# Поменяй TZ под свою таймзону.

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

# Если промпт пустой — пропускаем
[ -z "$PROMPT" ] && exit 0

# Текущее время (поменяй TZ под себя, например 'Europe/Berlin' или 'America/New_York')
TZ_VALUE="${OPERATOR_TZ:-UTC}"
CURRENT_TIME=$(TZ="$TZ_VALUE" date '+%Y-%m-%d %H:%M %Z')
CONTEXT="[Текущее время пользователя: $CURRENT_TIME]"

ESCAPED=$(echo "$CONTEXT" | jq -Rs .)
echo "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":$ESCAPED}}"

exit 0

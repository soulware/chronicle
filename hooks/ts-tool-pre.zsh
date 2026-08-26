#!/bin/zsh
# PreToolUse: record a start time. Emits nothing, so it costs no context.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}
id=$(print -r -- "$payload" | jq -r '.tool_use_id // "unknown"' 2>/dev/null)
id=${id//[^A-Za-z0-9_-]/_}

dir="${TS_STATE_DIR}/${session}"
mkdir -p "$dir" || exit 0
print -r -- $EPOCHREALTIME > "$dir/tool-$id"
exit 0

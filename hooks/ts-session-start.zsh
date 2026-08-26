#!/bin/zsh
# SessionStart: stamp the opening of a session and carry any pending
# compaction marker, since this is the first event after a compaction that
# accepts context.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}
tp=$(print -r -- "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)
src=$(print -r -- "$payload" | jq -r '.source // "unknown"' 2>/dev/null)
src=${src//[^A-Za-z0-9_-]/}

dir="${TS_STATE_DIR}/${session}"
mkdir -p "$dir" || exit 0

now=$(ts_now_iso)
ctx="<time now=\"$now\" session_source=\"$src\"/>"
msg="$now  ·  session $src"

marker=$(ts_take_compaction "$dir" "$tp") && ctx+="$marker"

ts_emit SessionStart "$ctx" "$msg"
exit 0

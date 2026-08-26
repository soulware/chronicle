#!/bin/zsh
# PostCompact: report the boundary in the scrollback. This event rejects
# hookSpecificOutput, so the marker for the model stays in state and the next
# event that accepts context delivers it.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}

f="${TS_STATE_DIR}/${session}/compaction"
[[ -f "$f" ]] || exit 0
IFS='|' read -r from trigger prompts < "$f"

start=$(ts_iso_to_epoch "$from")
[[ -n "$start" ]] && span=$(ts_fmt_dur $((EPOCHSECONDS - start))) || span="?"

jq -nc --arg m "$(ts_now_iso)  ·  compacted $span of transcript, $prompts prompts" \
  '{systemMessage: $m}'
exit 0

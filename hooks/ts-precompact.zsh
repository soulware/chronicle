#!/bin/zsh
# PreCompact: measure the stretch of transcript about to be summarised away and
# say so in the scrollback. Nothing is written down for the model: the boundary
# lands in the transcript as a compact_boundary record, and the next turn stamp
# reads it from there.
#
# The payload names whether the compaction was manual or automatic. That is not
# reported: it is the one fact here the transcript does not hold, and carrying
# it would mean keeping a state file for a single attribute.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}
tp=$(print -r -- "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)

[[ -r "$tp" ]] || exit 0

# A previous boundary marks where the last summary already covers, so the span
# reported is the stretch this compaction is folding up.
from=$(jq -r 'select(.type=="system" and .subtype=="compact_boundary") | .timestamp' "$tp" 2>/dev/null | tail -1)
[[ -n "$from" ]] || from=$(jq -r 'select(.timestamp) | .timestamp' "$tp" 2>/dev/null | sort | head -1)
[[ -n "$from" ]] || exit 0

prompts=$(jq -r --arg f "$from" '
  select(.type=="user" and (.message.content | type == "string"))
  | select(.timestamp > $f) | .timestamp' "$tp" 2>/dev/null | wc -l | tr -d ' ')

start=$(ts_iso_to_epoch "$from")
[[ -n "$start" ]] && span=$(ts_fmt_dur $((EPOCHSECONDS - start))) || span=unknown
jq -nc --arg m "$(ts_now_iso)  ·  compacting $span of transcript, $prompts prompts" \
  '{systemMessage: $m}'
exit 0

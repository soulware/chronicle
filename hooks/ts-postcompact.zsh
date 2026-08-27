#!/bin/zsh
# PostCompact: report the boundary in the scrollback.
#
# This event rejects hookSpecificOutput, so it says nothing to the model. It no
# longer needs to: the boundary is a compact_boundary record in the transcript,
# and the next turn stamp finds it there and reports it once.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
tp=$(print -r -- "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)
[[ -r "$tp" ]] || exit 0

from=$(jq -r 'select(.type=="system" and .subtype=="compact_boundary") | .timestamp' "$tp" 2>/dev/null | tail -1)
[[ -n "$from" ]] || exit 0

start=$(ts_iso_to_epoch "$from")
[[ -n "$start" ]] && span=$(ts_fmt_dur $((EPOCHSECONDS - start))) || span="?"

jq -nc --arg m "$(ts_now_iso)  ·  compacted $span of transcript" '{systemMessage: $m}'
exit 0

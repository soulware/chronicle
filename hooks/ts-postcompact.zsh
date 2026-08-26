#!/bin/zsh
# PostCompact: report the boundary on the far side of the compaction, where the
# detail the summary dropped is no longer readable. The transcript file keeps
# every record, so this says where to look rather than carrying the detail.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}
tp=$(print -r -- "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)

f="${TS_STATE_DIR}/${session}/compaction"
[[ -f "$f" ]] || exit 0
IFS='|' read -r from trigger prompts < "$f"
rm -f "$f"

now=$(ts_now_iso)
attrs="at=\"$now\" trigger=\"$trigger\" covered_from=\"$from\" prompts=\"$prompts\""

start=$(ts_iso_to_epoch "$from")
if [[ -n "$start" ]]; then
  span=$(ts_fmt_dur $((EPOCHSECONDS - start)))
  attrs+=" span=\"$span\""
fi
[[ -n "$tp" ]] && attrs+=" transcript=\"$tp\""

jq -nc --arg c "<compaction $attrs/>" --arg m "$now  ·  compacted ${span:-?} of transcript, $prompts prompts" \
  '{hookSpecificOutput: {hookEventName: "PostCompact", additionalContext: $c}, systemMessage: $m}'
exit 0

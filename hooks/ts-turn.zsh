#!/bin/zsh
# UserPromptSubmit: stamp the turn with wall-clock time and the gaps either side.
# additionalContext reaches the model; systemMessage reaches the scrollback.
emulate -L zsh
set -o pipefail
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}
tp=$(print -r -- "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)

dir="${TS_STATE_DIR}/${session}"
mkdir -p "$dir" || exit 0

find "$dir" -name 'tool-*' -mmin +1440 -delete 2>/dev/null

now=$EPOCHREALTIME
attrs="now=\"$(ts_now_iso)\""
msg="$(ts_now_iso)"

# session_start rides every stamp, so an elapsed value converts back to a wall
# clock even in an excerpt or on the far side of a compaction.
if [[ -f "$dir/start" ]]; then
  start=$(<"$dir/start")
  elapsed=$(ts_fmt_dur $((now - start)))
  attrs+=" session_start=\"$(ts_epoch_to_iso $start)\" session_elapsed=\"$elapsed\""
  msg+="  ·  $elapsed into session"
else
  print -r -- $now > "$dir/start"
  attrs+=" session_start=\"$(ts_now_iso)\" session_elapsed=\"0s\""
  msg+="  ·  session start"
fi

prev_turn=""
if [[ -f "$dir/turn" ]]; then
  prev_turn=$(<"$dir/turn")
  gap=$(ts_fmt_dur $((now - prev_turn)))
  attrs+=" since_last_turn=\"$gap\""
  msg+="  ·  +$gap since last turn"
fi

# The turn gap holds the model's own work and the user's pause as one number.
# The stop time splits it, so each side is reported separately.
if [[ -f "$dir/stop" ]]; then
  stop=$(<"$dir/stop")
  rm -f "$dir/stop"
  if [[ -n "$stop" ]]; then
    [[ -n "$prev_turn" ]] && attrs+=" last_turn_dur=\"$(ts_fmt_dur $((stop - prev_turn)))\""
    attrs+=" since_last_stop=\"$(ts_fmt_dur $((now - stop)))\""
  fi
fi

if [[ -f "$dir/turnfail" ]]; then
  IFS='|' read -r failed_at failed_kind < "$dir/turnfail"
  rm -f "$dir/turnfail"
  attrs+=" previous_turn_failed=\"$failed_kind\""
  msg+="  ·  previous turn failed ($failed_kind)"
fi

print -r -- $now > "$dir/turn"

ctx="<time $attrs/>"
marker=$(ts_take_compaction "$dir" "$tp") && ctx+="$marker"

ts_emit UserPromptSubmit "$ctx" "$msg"
exit 0

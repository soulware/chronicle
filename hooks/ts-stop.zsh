#!/bin/zsh
# Stop: close the turn in the scrollback with the time and what the turn cost.
# Emits systemMessage alone. A Stop hook that blocks can trap the session in a
# loop, so this one never sets block.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}

dir="${TS_STATE_DIR}/${session}"
now=$EPOCHREALTIME
msg="$(ts_now_iso)"

if [[ -f "$dir/turn" ]]; then
  turn=$(<"$dir/turn")
  [[ -n "$turn" ]] && msg+="  ·  turn took $(ts_fmt_dur $((now - turn)))"
fi

if [[ -f "$dir/start" ]]; then
  start=$(<"$dir/start")
  [[ -n "$start" ]] && msg+="  ·  $(ts_fmt_dur $((now - start))) into session"
fi

# Stop takes additionalContext, but its meaning there is feedback the model is
# expected to act on, which keeps the turn open. The time is left in state for
# the next turn stamp to report instead.
[[ -d "$dir" ]] && print -r -- $now > "$dir/stop"

jq -nc --arg m "$msg" '{systemMessage: $m}'
exit 0

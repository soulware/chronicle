#!/bin/zsh
# UserPromptSubmit: stamp the turn with wall-clock time and the gaps either side.
# additionalContext reaches the model; systemMessage reaches the scrollback.
emulate -L zsh
set -o pipefail
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}

dir="${TS_STATE_DIR}/${session}"
mkdir -p "$dir" || exit 0

find "$dir" -name 'tool-*' -mmin +1440 -delete 2>/dev/null

now=$EPOCHREALTIME
attrs="now=\"$(ts_now_iso)\""
msg="$(ts_now_iso)"

if [[ -f "$dir/start" ]]; then
  start=$(<"$dir/start")
  elapsed=$(ts_fmt_dur $((now - start)))
  attrs+=" session_elapsed=\"$elapsed\""
  msg+="  ·  $elapsed into session"
else
  print -r -- $now > "$dir/start"
  attrs+=" session_elapsed=\"0s\""
  msg+="  ·  session start"
fi

if [[ -f "$dir/turn" ]]; then
  last=$(<"$dir/turn")
  gap=$(ts_fmt_dur $((now - last)))
  attrs+=" since_last_turn=\"$gap\""
  msg+="  ·  +$gap since last turn"
fi

print -r -- $now > "$dir/turn"

ts_emit UserPromptSubmit "<time $attrs/>" "$msg"
exit 0

#!/bin/zsh
# PostToolUse: stamp the tool result with its end time and how long it took.
# dur spans the pre-hook to here, so it covers queuing and permission waits as
# well as execution. The payload's own duration_ms covers execution alone.
# TS_TOOL_MIN sets the seconds a call must reach to appear in the scrollback.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}
id=$(print -r -- "$payload" | jq -r '.tool_use_id // "unknown"' 2>/dev/null)
id=${id//[^A-Za-z0-9_-]/_}

f="${TS_STATE_DIR}/${session}/tool-$id"
attrs="end=\"$(ts_now_clock)\""
msg=""

if [[ -f "$f" ]]; then
  start=$(<"$f")
  rm -f "$f"
  if [[ -n "$start" ]]; then
    typeset -F secs=$((EPOCHREALTIME - start))
    dur=$(ts_fmt_dur $secs)
    attrs+=" dur=\"$dur\""
    (( secs >= ${TS_TOOL_MIN:-0} )) && msg="$(ts_now_iso)  ·  $dur"
  fi
fi

ts_emit PostToolUse "<time $attrs/>" "$msg"
exit 0

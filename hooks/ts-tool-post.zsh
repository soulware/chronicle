#!/bin/zsh
# PostToolUse and PostToolUseFailure: stamp the tool result with its end time
# and how long it took. One script serves both, since the payload names the
# event and the two differ only in outcome.
#
# dur spans the pre-hook to here, so it covers queuing and permission waits as
# well as execution. exec carries the payload's duration_ms, which is execution
# alone, so the difference between the two is the wait.
# TS_TOOL_MIN sets the seconds a call must reach to appear in the scrollback.
# A failure appears whatever its duration.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}
id=$(print -r -- "$payload" | jq -r '.tool_use_id // "unknown"' 2>/dev/null)
id=${id//[^A-Za-z0-9_-]/_}
event=$(print -r -- "$payload" | jq -r '.hook_event_name // "PostToolUse"' 2>/dev/null)
[[ "$event" == "PostToolUseFailure" ]] && failed=1 || failed=0

f="${TS_STATE_DIR}/${session}/tool-$id"
ms=$(print -r -- "$payload" | jq -r '.duration_ms // empty' 2>/dev/null)

attrs="end=\"$(ts_now_iso)\""
(( failed )) && attrs+=" outcome=\"failed\""
msg=""

if [[ -f "$f" ]]; then
  start=$(<"$f")
  rm -f "$f"
  if [[ -n "$start" ]]; then
    typeset -F secs=$((EPOCHREALTIME - start))
    dur=$(ts_fmt_dur $secs)
    attrs+=" dur=\"$dur\""
    # exec is the payload's own execution time. dur minus exec is the wait,
    # which reads as presence rather than as a slow command.
    if [[ "$ms" == <-> ]]; then
      typeset -F e=$((ms / 1000.0))
      attrs+=" exec=\"$(ts_fmt_dur $e)\""
    fi
    show=0
    (( secs >= ${TS_TOOL_MIN:-0} )) && show=1
    (( failed )) && show=1
    if (( show )); then
      msg="$(ts_now_iso)  ·  $dur"
      (( failed )) && msg+="  ·  failed"
    fi
  fi
fi

ts_emit "$event" "<time $attrs/>" "$msg"
exit 0

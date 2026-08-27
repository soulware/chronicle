#!/bin/zsh
# PostToolUse and PostToolUseFailure: stamp the tool result with its end time
# and how long it took. One script serves both, since the payload names the
# event and the two differ only in outcome.
#
# dur spans the pre-hook to here, so it covers queuing and permission waits as
# well as execution. exec carries the payload's duration_ms, which is execution
# alone. wait is the difference: outstanding but not running.
#
# Two gates, because the two readers differ.
#
# TS_TOOL_MIN sets the seconds a call must reach to appear in the scrollback. A
# person is skimming there and a line costs almost nothing, so it defaults to 0
# and every call shows.
#
# TS_TOOL_CTX_MIN sets what reaches the model, and defaults to 5, because the
# model pays differently: a block that appears on every call and says nothing
# almost every time teaches the reader to skip the shape, and the rare
# informative one goes with it. Gated, the presence of a stamp is itself the
# signal.
#
# The model's gate reads exec rather than dur, so a 0.1s command behind a slow
# permission prompt is not filed as slow work. The wait is tested separately
# against the same threshold, so a deliberating guard or a long approval still
# surfaces on its own. Where the payload gives no duration_ms there is nothing
# to separate and the whole span is measured instead.
#
# A failure ignores both gates, on the grounds that a failure is always worth
# seeing, and carries exec and wait so a rejection reads differently from a
# timeout: a rejection is a wait with no execution behind it and must not be
# retried, a timeout is execution that ran out of time and should be.
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
# A failure is exempt from both gates. A call with no matching pre passes
# neither: with no duration there is nothing in the stamp the turn stamp does
# not already say, so it goes unstamped like a tool the hooks skip.
typeset -i show=$failed ctx_show=$failed

if [[ -f "$f" ]]; then
  start=$(<"$f")
  rm -f "$f"
  if [[ -n "$start" ]]; then
    typeset -F secs=$((EPOCHREALTIME - start))
    dur=$(ts_fmt_dur $secs)
    attrs+=" dur=\"$dur\""
    typeset -F own=$secs wait=0
    if [[ "$ms" == <-> ]]; then
      own=$((ms / 1000.0))
      attrs+=" exec=\"$(ts_fmt_dur $own)\""
      wait=$((secs - own))
      (( wait < 0 )) && wait=0
      # Precomputed for the same reason the turn deltas are: a subtraction the
      # model has to do for itself is one it can get wrong. A second of wait is
      # queuing, a minute of it is nobody at the keyboard.
      (( wait >= 1 )) && attrs+=" wait=\"$(ts_fmt_dur $wait)\""
    fi
    (( secs >= ${TS_TOOL_MIN:-0} )) && show=1
    (( own >= ${TS_TOOL_CTX_MIN:-5} || wait >= ${TS_TOOL_CTX_MIN:-5} )) && ctx_show=1
    if (( show )); then
      msg="$(ts_now_iso)  ·  $dur"
      (( failed )) && msg+="  ·  failed"
    fi
  fi
fi

(( ctx_show )) && ctx="<time $attrs/>" || ctx=""
ts_emit "$event" "$ctx" "$msg"
exit 0

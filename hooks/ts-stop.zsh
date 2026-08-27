#!/bin/zsh
# Stop: close the turn in the scrollback. Nothing is left behind for anyone
# else to read: Claude Code writes a turn_duration record at the end of every
# turn, and the next turn stamp reads the stop time and the duration from there.
#
# The duration of the turn is not reported here. Claude Code's own
# showTurnDuration setting defaults to on and already draws a "Cooked for Nm Ns"
# line after every turn, so printing it again would put the same number twice on
# adjacent lines. What is left is what the built-in line does not carry: the
# absolute time, and how far into the session this turn ended.
#
# Emits systemMessage alone. A Stop hook that blocks can trap the session in a
# loop, so this one never sets block.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
tp=$(print -r -- "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)

msg="$(ts_now_iso)"
if [[ -r "$tp" ]]; then
  first=$(jq -r -s 'first(.[] | select(.timestamp) | .timestamp) // empty' "$tp" 2>/dev/null)
  start=$(ts_iso_to_epoch "$first")
  [[ -n "$start" ]] && msg+="  ·  $(ts_fmt_dur $((EPOCHSECONDS - start))) into session"
fi

jq -nc --arg m "$msg" '{systemMessage: $m}'
exit 0

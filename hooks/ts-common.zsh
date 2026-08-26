#!/bin/zsh
# Shared helpers for the transcript timestamp hooks.
zmodload zsh/datetime

: ${TS_STATE_DIR:=${HOME}/.claude/hooks/state}

ts_now_iso() {
  local stamp
  stamp=$(strftime '%Y-%m-%dT%H:%M:%S%z' $EPOCHSECONDS)
  print -r -- "${stamp[1,-3]}:${stamp[-2,-1]}"
}

ts_now_clock() {
  strftime '%H:%M:%S' $EPOCHSECONDS
}

ts_fmt_dur() {
  local -F s=$1
  local -i i=$1
  if (( s < 60 )); then
    printf '%.1fs' $s
  elif (( s < 3600 )); then
    printf '%dm%02ds' $((i / 60)) $((i % 60))
  else
    printf '%dh%02dm' $((i / 3600)) $(((i % 3600) / 60))
  fi
}

ts_emit() {
  local event=$1 ctx=$2 msg=$3
  if [[ -n "$msg" ]]; then
    jq -nc --arg e "$event" --arg c "$ctx" --arg m "$msg" \
      '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}, systemMessage: $m}'
  else
    jq -nc --arg e "$event" --arg c "$ctx" \
      '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
  fi
}

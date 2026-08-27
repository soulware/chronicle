#!/bin/zsh
# Shared helpers for the transcript timestamp hooks.
zmodload zsh/datetime

: ${TS_STATE_DIR:=${HOME}/.claude/hooks/state}

ts_now_iso() {
  local -x TZ=UTC
  strftime '%Y-%m-%dT%H:%M:%SZ' $EPOCHSECONDS
}

# Transcript envelope timestamps look like 2026-08-26T10:17:26.904Z. Seconds are
# enough here, so the fraction and the zone marker come off before parsing.
ts_epoch_to_iso() {
  local -i e=$1
  local -x TZ=UTC
  strftime '%Y-%m-%dT%H:%M:%SZ' $e
}

ts_iso_to_epoch() {
  local s=${1%%.*}
  s=${s%Z}
  local -x TZ=UTC
  strftime -r '%Y-%m-%dT%H:%M:%S' "$s" 2>/dev/null
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

# Either half may be empty, and an empty one is left out rather than sent as an
# empty string: additionalContext:"" still opens a block in the transcript, and
# a stamp that was gated out should leave no trace at all. With nothing to say
# on either side the hook prints nothing, which is a valid thing for a hook to
# do and cheaper than a well-formed announcement of silence.
ts_emit() {
  local event=$1 ctx=$2 msg=$3
  [[ -z "$ctx" && -z "$msg" ]] && return 0
  jq -nc --arg e "$event" --arg c "$ctx" --arg m "$msg" \
    '(if $c != "" then {hookSpecificOutput: {hookEventName: $e, additionalContext: $c}} else {} end)
     + (if $m != "" then {systemMessage: $m} else {} end)'
}

# A compaction leaves a marker for the model, but PostCompact rejects
# hookSpecificOutput, so delivery falls to a later event that accepts it.
# Whichever one gets there first clears the marker.
ts_take_compaction() {
  local f=$1/compaction tp=$2
  [[ -f "$f" ]] || return 1
  local from trigger prompts
  IFS='|' read -r from trigger prompts < "$f"
  rm -f "$f"
  local attrs="covered_from=\"$from\" trigger=\"$trigger\" prompts=\"$prompts\""
  local start=$(ts_iso_to_epoch "$from")
  [[ -n "$start" ]] && attrs+=" span=\"$(ts_fmt_dur $((EPOCHSECONDS - start)))\""
  [[ -n "$tp" ]] && attrs+=" transcript=\"$tp\""
  print -r -- "<compaction $attrs/>"
}

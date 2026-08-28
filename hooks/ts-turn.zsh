#!/bin/zsh
# UserPromptSubmit: stamp the turn with wall-clock time and the gaps either side.
# additionalContext reaches the model; systemMessage reaches the scrollback.
#
# Every number here is read out of the transcript rather than carried forward in
# state. Claude Code writes an ISO-8601 timestamp with milliseconds on every
# record, a turn_duration record at the end of each turn, an isApiErrorMessage
# record when a turn dies, and a compact_boundary record at a seam. All of it is
# written whether this hook runs or not, so keeping a private copy was only ever
# a way of reading it sooner.
#
# One jq pass over the whole file costs about 11ms, which is less than the two
# hooks per tool call this replaces.
emulate -L zsh
set -o pipefail
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
tp=$(print -r -- "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)

now=$EPOCHREALTIME
attrs="now=\"$(ts_now_iso)\""
msg="$(ts_now_iso)"

typeset -A F
if [[ -r "$tp" ]]; then
  while IFS=$'\t' read -r k v; do [[ -n "$k" ]] && F[$k]=$v; done < <(ts_tx_facts "$tp")
fi

# session_start rides every stamp, so an elapsed value converts back to a wall
# clock even in an excerpt or on the far side of a compaction.
start=$(ts_iso_to_epoch "${F[first]:-}")
if [[ -n "$start" ]]; then
  elapsed=$(ts_fmt_dur $((now - start)))
  attrs+=" session_start=\"$(ts_epoch_to_iso $start)\" session_elapsed=\"$elapsed\""
  msg+="  ·  $elapsed into session"
else
  attrs+=" session_start=\"$(ts_now_iso)\" session_elapsed=\"0s\""
  msg+="  ·  session start"
fi

# The previous prompt is the last one that already belongs to a finished turn,
# which is why it is taken from before the last turn_duration rather than simply
# last: by the time this fires the current prompt may already be on disk.
prev=$(ts_iso_to_epoch "${F[last_prompt]:-}")
if [[ -n "$prev" ]]; then
  gap=$(ts_fmt_dur $((now - prev)))
  attrs+=" since_last_turn=\"$gap\""
  msg+="  ·  +$gap since last turn"
fi

# The turn gap holds the model's own work and the user's pause as one number.
# turn_duration splits it: the duration is the model's half, measured by Claude
# Code itself, and the gap since it ended is the user's.
if [[ -n "${F[last_stop]:-}" ]]; then
  stop=$(ts_iso_to_epoch "${F[last_stop]}")
  if [[ -n "$stop" ]]; then
    if (( ${F[last_dur]:-0} )); then
      typeset -F d=$((${F[last_dur]} / 1000.0))
      attrs+=" last_turn_dur=\"$(ts_fmt_dur $d)\""
      # Claude Code's durationMs discounts the time a turn spends blocked on the
      # user, and wall clock from prompt to stop does not. The gap between them
      # is exactly that block — an AskUserQuestion, or a permission prompt left
      # sitting. Reported separately so it is not lost between the two: it falls
      # inside the turn, so since_last_stop does not cover it either.
      if [[ -n "$prev" ]]; then
        typeset -F blocked=$((stop - prev - d))
        (( blocked >= 1 )) && attrs+=" last_turn_blocked=\"$(ts_fmt_dur $blocked)\""
      fi
    fi
    # What is left inside durationMs is the model generating and the machine
    # working, with nothing separating them. This is the machine's half, and it
    # is the one number here the model cannot recover from its own context: a
    # tool result carries no timing at all. Usually it is the small half — a
    # twelve minute turn whose commands took thirty seconds went into
    # generation, not into the build.
    #
    # Silent when the turn ran no tools, since an explicit zero would appear on
    # every conversational turn to say nothing happened.
    if (( ${F[tool_time]:-0} )); then
      attrs+=" last_turn_tool_time=\"$(ts_fmt_dur ${F[tool_time]})\""
    fi
    # Delegated work is named on its own line rather than folded into the one
    # above. An Agent call is another model generating, and it is the only tool
    # here whose cost runs to minutes: counted as machine time it would report a
    # quarter of an hour at the build for a turn that never ran a command, which
    # is the exact conflation this pair exists to undo. Rare enough to stay
    # silent almost always, and large enough to be worth naming when it is not.
    if (( ${F[subagent_time]:-0} )); then
      attrs+=" last_turn_subagent_time=\"$(ts_fmt_dur ${F[subagent_time]})\""
    fi
    attrs+=" since_last_stop=\"$(ts_fmt_dur $((now - stop)))\""
  fi
fi

# An API error after the last completed turn means the previous turn died.
# Reported once: the next turn has a turn_duration after it and it drops out.
if [[ -n "${F[api_error]:-}" ]]; then
  attrs+=" previous_turn_failed=\"${F[api_error]//[^A-Za-z0-9_ -]/}\""
  msg+="  ·  previous turn failed (${F[api_error]//[^A-Za-z0-9_ -]/})"
fi

ctx="<time $attrs/>"

# A boundary newer than the previous prompt means the compaction happened during
# the last turn, so it is reported now and not again: next turn the prompt is
# newer than the boundary.
if [[ -n "${F[boundary]:-}" ]] && [[ -z "${F[last_prompt]:-}" || "${F[boundary]}" > "${F[last_prompt]}" ]]; then
  b=$(ts_iso_to_epoch "${F[boundary]}")
  cattrs="covered_from=\"${F[boundary]}\""
  [[ -n "$b" ]] && cattrs+=" span=\"$(ts_fmt_dur $((EPOCHSECONDS - b)))\""
  [[ -n "${F[since_boundary]:-}" ]] && cattrs+=" prompts=\"${F[since_boundary]}\""
  [[ -n "$tp" ]] && cattrs+=" transcript=\"$tp\""
  ctx+="<compaction $cattrs/>"
fi

ts_emit UserPromptSubmit "$ctx" "$msg"
exit 0

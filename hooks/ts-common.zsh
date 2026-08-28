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

# One pass over the transcript for everything the turn stamp reports. Emitted as
# key/value lines rather than JSON because the caller is shell, and read in one
# go because the cost here is the file read, not the parsing.
#
# last_prompt is deliberately the last prompt at or before the last
# turn_duration: by the time UserPromptSubmit fires the current prompt may
# already be on disk, and counting it would report a gap of zero.
TS_TX_JQ='
  def ts: .timestamp // empty;
  # Envelope timestamps carry milliseconds, which fromdateiso8601 will not
  # parse, so the fraction comes off and is added back.
  def ep: (.[0:19] + "Z" | fromdateiso8601)
        + (if (. | length) > 20 and (.[19:20] == ".")
           then ((.[20:23] | tonumber) / 1000) else 0 end);
  # Overlapping spans are merged rather than summed. Calls issued in one message
  # run at the same time, so adding their durations would report more elapsed
  # time than the turn contains.
  def merge: sort_by(.[0])
           | reduce .[] as $s ([];
               if (length > 0 and .[-1][1] >= $s[0])
               then .[0:-1] + [[ .[-1][0], ([.[-1][1], $s[1]] | max) ]]
               else . + [$s] end)
           | map(.[1] - .[0]) | add // 0;
  def secs: (. * 10 | round / 10 | tostring);
  [ .[] | select(.timestamp) ] as $all
  | ($all | map(select(.subtype == "turn_duration")) | last) as $lastturn
  | (($lastturn | .timestamp) // "") as $stop
  | ($all | map(select(.type == "user"
                       and (.message.content | type) == "string"))) as $prompts
  | (($all | map(select(.subtype == "compact_boundary")) | last | ts) // "") as $bnd
  | (($prompts | map(select($stop == "" or (.timestamp <= $stop))) | last | ts)
     // "") as $prev
  # The last turn is the span from that prompt to the stop, so a tool_use in
  # the window is a call the last turn made. A call with no matching result is
  # one still in flight or one the transcript never saw finish, and is left out
  # rather than guessed at.
  | ($all | map(select((.message.content | type) == "array")
                | .timestamp as $t
                | .message.content[]
                | select(.type == "tool_result")
                | {id: .tool_use_id, end: $t})
          | INDEX(.id)) as $ends
  | [ $all[]
      | select(.type == "assistant" and (.message.content | type) == "array")
      | .timestamp as $t
      | select($stop != "" and $t <= $stop and ($prev == "" or $t > $prev))
      | .message.content[]
      | select(.type == "tool_use")
      | ($ends[.id] // {}) as $e
      | select($e.end != null)
      | { name: .name, span: [ ($t | ep), ($e.end | ep) ] } ] as $calls
  | [ "first",     ($all | first | ts) ],
    [ "last_stop", $stop ],
    [ "last_dur",  (($lastturn.durationMs // 0) | tostring) ],
    [ "last_prompt", $prev ],
    # Split rather than combined, because an Agent call is another model
    # generating and every other call is the machine working. The two are
    # merged within their own class and not against each other, so a turn that
    # ran a command alongside a subagent reports both in full.
    #
    # AskUserQuestion is neither: its span is the user deciding. Counting it
    # would put a two minute pause at the keyboard into a number that claims to
    # be machine time, and would double-report it, since last_turn_blocked
    # already names exactly that time. A permission prompt does the same to
    # whichever call it sits inside, and that one cannot be separated out: the
    # transcript records when a call started and when it returned, with nothing
    # marking the wait for approval in between.
    [ "tool_time",
      ([ $calls[]
         | select(.name != "Agent" and .name != "AskUserQuestion")
         | .span ] | merge | secs) ],
    [ "subagent_time",
      ([ $calls[] | select(.name == "Agent") | .span ] | merge | secs) ],
    [ "api_error",
      (($all | map(select(.isApiErrorMessage == true))
             | map(select($stop == "" or (.timestamp > $stop))) | last | .error) // "") ],
    [ "boundary", $bnd ],
    [ "since_boundary",
      (($prompts | map(select($bnd != "" and .timestamp > $bnd)) | length) | tostring) ]
  | @tsv
'

ts_tx_facts() { jq -r -s "$TS_TX_JQ" "$1" 2>/dev/null }

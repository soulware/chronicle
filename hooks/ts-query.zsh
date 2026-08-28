#!/bin/zsh
# Read-only queries over a Claude Code transcript.
#
# The transcript already records every tool call, its command, its outcome and
# an envelope timestamp with milliseconds, and it does so whether these hooks
# run or not. Nothing here writes, keeps state, or needs a key registry: every
# answer is a pass over a file that someone else maintains, append-only, with
# one writer.
#
# Calls are matched on a command prefix rather than a normalised command. That
# makes coarseness a parameter chosen when the question is asked instead of a
# decision baked in when the record is written, and it turns the dangerous
# error into a visible one: too short over-matches and costs a rerun, too long
# returns nothing at all and says so.
#
#   ts-query intents [words] [--within 1h]    what the work was said to be about
#   ts-query touched <path>                   every read and write of a file
#   ts-query recent <prefix> [--within 30m]   how often, and when
#   ts-query last <prefix>                    outcome and age of the last run
#   ts-query transitions <prefix>             where pass and fail changed places
#   ts-query turns [--within 2h]              each turn, and where its time went
#   ts-query elapsed                          session, last turn, last stop
#
# `touched` is the reliable one and the rest are the approximate ones. Edit,
# Write and Read carry a file_path, which is an absolute path and therefore an
# exact key: no prefix, no normalisation, no coarseness to tune. Bash carries
# one free-form string, which is why everything else here has to guess.
#
# It is also immune to a problem the command queries have. Querying is done by
# running commands, so a query about commands can match earlier queries. It can
# never produce an Edit, so a query about files cannot match itself.
#
# --transcript PATH overrides the file. With no override the newest transcript
# for the current directory's project is used.
#
# Subagents keep their own transcript, one file per agent, under
# <project>/<session-id>/subagents/agent-<id>.jsonl, and every record in it is
# flagged isSidechain. None of it reaches the parent session's file: a subagent
# runs two commands and the parent transcript gains only the prompt and the
# result. So there is nothing to filter out of a main transcript, and filtering
# on the flag would blind this tool to the one file where the flag is set.
# Point --transcript at a subagent file and it reads normally.
#
# Two consequences. A count of "how many times have I run this" excludes work
# done by subagents, which is right, since that work happened in another
# context. And chronicle's hooks do not fire inside a subagent at all, so a
# subagent transcript carries no stamps and its durations can only come from
# envelope timestamps, which is exactly what this reads.
emulate -L zsh
zmodload zsh/datetime
setopt pipefail extendedglob

# For TS_JQ_SPANS. The turn stamp and this tool have to agree about what counts
# as machine time, so the arithmetic is sourced rather than copied.
source "${0:A:h}/ts-common.zsh"

die() { print -r -- "ts-query: $1" >&2; exit 2 }

# Claude Code slugs the project directory by replacing every character outside
# [A-Za-z0-9] with a dash. Deriving it here rather than taking it on faith
# keeps the tool usable without a hook to hand it the path.
default_transcript() {
  local slug=${PWD//[^A-Za-z0-9]/-}
  local dir="${HOME}/.claude/projects/${slug}"
  [[ -d "$dir" ]] || return 1
  local -a f
  f=( "$dir"/*.jsonl(Nom) )
  (( $#f )) || return 1
  print -r -- "$f[1]"
}

# 30m, 2h, 90s, or a bare number of seconds.
to_secs() {
  local v=$1
  case "$v" in
    <->s) print -r -- ${v%s} ;;
    <->m) print -r -- $(( ${v%m} * 60 )) ;;
    <->h) print -r -- $(( ${v%h} * 3600 )) ;;
    <->d) print -r -- $(( ${v%d} * 86400 )) ;;
    <->)  print -r -- $v ;;
    *)    return 1 ;;
  esac
}

# Marks the cut so a clipped value cannot be mistaken for a short one.
clip() {
  local s=$1 n=$2
  (( ${#s} > n )) && print -r -- "${s[1,n-1]}…" || print -r -- "$s"
}

fmt_dur() {
  local -F s=$1
  local -i i=$1
  if   (( s < 60 ));   then printf '%.1fs' $s
  elif (( s < 3600 )); then printf '%dm%02ds' $((i / 60)) $((i % 60))
  else                      printf '%dh%02dm' $((i / 3600)) $(((i % 3600) / 60))
  fi
}

# One TSV row per completed tool call: start, end, seconds, outcome, tool,
# command. A tool_use with no matching tool_result is a call still in flight or
# one the transcript never saw finish, and is left out rather than guessed at.
#
# Envelope timestamps carry milliseconds, which fromdateiso8601 will not parse,
# so the fraction is split off and added back.
JQ_CALLS='
  def ep:
    if . == null then null
    else (.[0:19] + "Z" | fromdateiso8601)
       + (if (. | length) > 20 and (.[19:20] == ".")
          then ((.[20:23] | tonumber) / 1000) else 0 end)
    end;
  def cmd:
    .input.command // .input.file_path // .input.pattern // .input.path
    // .input.prompt // "";
  def desc: .input.description // .input.summary // "";
  (map(select(.type == "assistant" and (.message.content | type) == "array")
       | .timestamp as $ts
       | .message.content[]
       | select(.type == "tool_use")
       | {id: .id, start: $ts, tool: .name, cmd: (. | cmd), desc: (. | desc)})) as $starts
  | (map(select((.message.content | type) == "array")
         | .timestamp as $ts
         | .message.content[]
         | select(.type == "tool_result")
         | {id: .tool_use_id, end: $ts, err: (.is_error // false)})
     | INDEX(.id)) as $ends
  | $starts
  | map(. + ($ends[.id] // {}))
  | map(select(.end != null))
  | map([ .start, .end,
          ((.end | ep) - (.start | ep)),
          (if .err then "failed" else "ok" end),
          .tool,
          (.cmd | gsub("[\t\n]"; " ")),
          (.desc | gsub("[\t\n]"; " "))
        ] | @tsv)[]
'

JQ_FILES='
  def adds($p): [$p[]? | .lines[]? | select(startswith("+"))] | length;
  def dels($p): [$p[]? | .lines[]? | select(startswith("-"))] | length;
  (map(select(.toolUseResult | type == "object")
       | {id: (.message.content[0].tool_use_id // ""),
          patch: (.toolUseResult.structuredPatch // []),
          um: (.toolUseResult.userModified // false)})
   | INDEX(.id)) as $res
  | map(select(.type == "assistant" and (.message.content | type) == "array")
        | .timestamp as $ts
        | .message.content[]
        | select(.type == "tool_use" and (.input.file_path != null))
        | . as $u
        | ($res[$u.id] // {}) as $r
        | [ $ts, $u.name, $u.input.file_path,
            (adds($r.patch)), (dels($r.patch)),
            (if $r.um then "modified by user" else "" end)
          ] | @tsv)[]
'

# One TSV row per completed turn. Turns are delimited by turn_duration records
# rather than by prompts, because a prompt does not reliably start one: a
# message sent while the model is still working lands mid-turn, and counting
# prompts would split one turn into two and report the same durationMs twice.
# Extra prompts inside the window are counted and reported as such.
#
# A turn still in flight has no turn_duration and is left out, on the same
# grounds as a tool call with no result.
JQ_TURNS=$TS_JQ_SPANS'
  [ .[] | select(type == "object" and .timestamp) ] as $all
  | (map(select((.message.content | type) == "array")
         | .timestamp as $t
         | .message.content[]
         | select(.type == "tool_result")
         | {id: .tool_use_id, end: $t})
     | INDEX(.id)) as $ends
  | [ $all[] | select(.subtype == "turn_duration") ] as $turns
  | [ $all[] | select(.type == "user"
                      and (.message.content | type) == "string") ] as $prompts
  | range($turns | length) as $i
  | $turns[$i] as $tu
  # Unbounded below for the first turn rather than anchored to the first record.
  # Anchoring drops the opening prompt whenever the transcript begins with it,
  # since the bound is exclusive and the prompt sits exactly on it.
  | (if $i == 0 then "" else $turns[$i - 1].timestamp end) as $from
  | [ $prompts[]
      | select(($from == "" or .timestamp > $from)
               and .timestamp <= $tu.timestamp) ] as $ps
  | [ $all[]
      | select(.type == "assistant" and (.message.content | type) == "array")
      | .timestamp as $t
      | select(($from == "" or $t > $from) and $t <= $tu.timestamp)
      | .message.content[]
      | select(.type == "tool_use")
      | ($ends[.id] // {}) as $e
      | select($e.end != null)
      | { name: .name, span: [ ($t | ep), ($e.end | ep) ] } ] as $c
  | [ $tu.timestamp,
      ((($tu.durationMs // 0) / 1000) | tostring),
      ([ $c[] | select(is_machine) | .span ] | merge | secs),
      ([ $c[] | select(is_agent)   | .span ] | merge | secs),
      ($c | length | tostring),
      ($ps | length | tostring),
      # A turn with no prompt is a real boundary rather than a gap: a slash
      # command run locally closes a turn without anyone typing at the model.
      # Named for what it was, because a blank caption reads as a broken row.
      (if ($ps | length) > 0
       then (($ps | first | .message.content) | gsub("[\t\n]"; " "))
       else ("(" + (([ $all[]
                       | select(.type == "system"
                                and ($from == "" or .timestamp > $from)
                                and .timestamp <= $tu.timestamp)
                       | .subtype ]
                     | map(select(. != "turn_duration"))
                     | first) // "no prompt") + ")")
       end)
    ] | @tsv
'

transcript=""
typeset -a rest
while (( $# )); do
  case "$1" in
    --transcript) transcript=$2; shift 2 ;;
    --contains)   contains=1; shift ;;
    --include-meta) include_meta=1; shift ;;
    --within)     within=$2; shift 2 ;;
    *)            rest+=("$1"); shift ;;
  esac
done
set -- "${rest[@]}"

cmd=${1:-}
[[ -n "$cmd" ]] || die "usage: ts-query touched|intents|recent|last|transitions|turns|elapsed [arg] [--within 30m] [--contains] [--include-meta] [--transcript PATH]"

if [[ -z "$transcript" ]]; then
  transcript=$(default_transcript) \
    || die "no transcript found for $PWD; pass --transcript PATH"
fi
[[ -r "$transcript" ]] || die "cannot read $transcript"

cutoff=0
if [[ -n "${within:-}" ]]; then
  w=$(to_secs "$within") || die "cannot read --within $within"
  cutoff=$(( EPOCHSECONDS - w ))
fi

# Rows arrive oldest first, which is the order the transcript is written in.
rows=$(jq -r --argjson _ 0 "$JQ_CALLS" -s "$transcript" 2>/dev/null) \
  || die "could not parse $transcript"

iso_ep() { local -x TZ=UTC; strftime -r '%Y-%m-%dT%H:%M:%S' "${1%%.*}" 2>/dev/null }

# Prefix match is on the command for Bash and on the tool name otherwise, so
# `ts-query recent Read` works alongside `ts-query recent 'cargo test'`.
#
# --contains matches anywhere instead. A prefix is the better default because
# it is predictable and cannot half-match, but it misses work buried inside a
# compound command: `python3 build.py && cargo test` does not start with
# `cargo test` and never will. When a prefix finds nothing the caller is told
# whether a substring would have, rather than being left to conclude the call
# never happened.
# A call that invoked this tool is the tool looking at itself, and counting it
# inflates every answer the more the tool is used. Recognised by the script
# name next to one of its own verbs, which is a heuristic: it deliberately does
# not match `cat hooks/ts-query.zsh`, which is work on the file rather than a
# query. --include-meta keeps them, and the count of what was dropped is always
# reported, because a query that silently discards rows is the same failure as
# a stamp that silently stops firing.
typeset -i META=0
is_meta() {
  [[ "$1" =~ 'ts-query(\.zsh)?[^;|]*(touched|recent|last|transitions|elapsed)' ]]
}

matches() {
  local prefix=$1 command=$2 tool=$3
  [[ -z "$prefix" ]] && return 0
  if (( ${contains:-0} )); then
    [[ "$command" == *"$prefix"* || "$tool" == *"$prefix"* ]]
  else
    [[ "$command" == "$prefix"* || "$tool" == "$prefix"* ]]
  fi
}

filter() {
  local prefix=$1
  print -r -- "$rows" | while IFS=$'\t' read -r start end secs outcome tool command desc; do
    [[ -n "$start" ]] || continue
    matches "$prefix" "$command" "$tool" || continue
    if (( ! ${include_meta:-0} )) && is_meta "$command"; then
      (( META++ )); continue
    fi
    if (( cutoff )); then
      local e=$(iso_ep "$start"); [[ -n "$e" ]] && (( e >= cutoff )) || continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$start" "$end" "$secs" "$outcome" "$tool" "$command" "$desc"
  done
}

# Only exclusions the query would otherwise have returned are worth reporting.
# Counting every meta call regardless of the prefix announces a drop that never
# affected the answer, which is noise dressed as disclosure.
meta_note() {
  local prefix=$1
  local n=$(print -r -- "$rows" | while IFS=$'\t' read -r start b c d tool command desc; do
              is_meta "$command" && matches "$prefix" "$command" "$tool" || continue
              if (( cutoff )); then
                local e=$(iso_ep "$start"); [[ -n "$e" ]] && (( e >= cutoff )) || continue
              fi
              print x
            done | wc -l | tr -d " ")
  (( n && ! ${include_meta:-0} )) &&
    print -r -- "($n call$( (( n == 1 )) || print s ) of ts-query itself excluded; --include-meta to keep)"
  return 0
}

case "$cmd" in

intents)
  # Descriptions are a per-call caption of the headline purpose, written by the
  # model at the time. They are not a normalisation key: fifteen calls in one
  # session ran the test suite and no two share a description, because a call
  # that patches a file and runs tests is captioned as the patch. So this reads
  # as an account of what the work was about, not as an index of what was done.
  #
  # It is also a self-report, where the command is a measurement. Both are
  # shown, and where they disagree that is a fact about the session worth
  # seeing rather than an error to correct.
  typeset -a hits
  while IFS=$'\t' read -r start end secs outcome tool command desc; do
    [[ -n "$start" && -n "$desc" ]] || continue
    if (( $# > 1 )); then
      ok=1
      for w in "${@:2}"; do
        [[ "${desc:l}" == *"${w:l}"* ]] || { ok=0; break }
      done
      (( ok )) || continue
    fi
    # A leading `cd` is scaffolding rather than the point of the call, and
    # showing it on every row hides the one thing the command column is for:
    # letting the reader see where the stated purpose and the actual work part
    # company.
    shown=${command##cd [^ ]## (\&\& |; |)}
    hits+=( "$(printf '  %s  %-6s %-46s %s' "${start:11:8}Z" "$tool" "$(clip "$desc" 46)" "$(clip "$shown" 44)")" )
  done < <(filter "")
  if (( ! $#hits )); then
    print -r -- "no described calls matching \"${*:2}\""
    exit 1
  fi
  print -r -- "$#hits described call$( (( $#hits == 1 )) || print s )${within:+ in the last $within}"
  meta_note ""
  print -l -- "${hits[@]: -20}"
  ;;

touched)
  # Neither `path` nor `fpath` may be used as a variable name here: zsh ties
  # both to PATH and to the function search path, so assigning either breaks
  # command lookup for the rest of the script.
  want=${2:-}
  [[ -n "$want" ]] || die "usage: ts-query touched <path>"
  frows=$(jq -r "$JQ_FILES" -s "$transcript" 2>/dev/null) || die "could not parse $transcript"
  matched=$(print -r -- "$frows" | while IFS=$'\t' read -r ts tool f a d um; do
    [[ -n "$ts" ]] || continue
    # An absolute path is an exact key, so a suffix match is the whole of the
    # matching logic: the caller types what they would type in the shell.
    [[ "$f" == "$want" || "$f" == */"$want" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$tool" "$f" "$a" "$d" "$um"
  done)
  if [[ -z "$matched" ]]; then
    print -r -- "no Edit, Write or Read of \"$want\""
    # A file changed by a shell command has no structured record, so silence
    # here would read as "untouched" when it means "not touched through a tool
    # that records it". Say which of the two it is.
    local seen=$(print -r -- "$rows" | cut -f6 | grep -cF -- "${want:t}" || true)
    (( seen )) && print -r -- \
      "but $seen shell command$( (( seen == 1 )) || print s ) mention ${want:t}; a file edited by a script leaves no structured record"
    exit 1
  fi
  n=$(print -r -- "$matched" | wc -l | tr -d " ")
  print -r -- "$n operation$( (( n == 1 )) || print s ) on \"$want\""
  print -r -- "$matched" | tail -15 | while IFS=$'\t' read -r ts tool f a d um; do
    ch=""
    (( a || d )) && ch="+$a -$d"
    printf '  %s  %-6s  %-10s %s\n' "${ts:0:19}Z" "$tool" "$ch" "$um"
  done
  ;;

recent)
  prefix=${2:-}
  matched=$(filter "$prefix")
  n=$( [[ -z "$matched" ]] && print 0 || print -r -- "$matched" | wc -l | tr -d ' ')
  window=${within:+ in the last $within}
  if (( n == 0 )); then
    print -r -- "no calls starting with \"$prefix\"$window"
    if (( ! ${contains:-0} )); then
      local deep=$(contains=1 filter "$prefix" | wc -l | tr -d " ")
      if (( deep )); then
        print -r -- "but $deep contain it, probably inside a compound command; try --contains"
      else
        print -r -- "(nothing contains it either; a prefix that matches nothing is usually too long)"
      fi
    fi
    exit 1
  fi
  print -r -- "$n call$( (( n == 1 )) || print s ) matching \"$prefix\"$window"
  meta_note "$prefix"
  print -r -- "$matched" | tail -10 | while IFS=$'\t' read -r start end secs outcome tool command desc; do
    printf '  %s  %8s  %-6s  %s\n' "${start:11:8}Z" "$(fmt_dur $secs)" "$outcome" "$(clip "$command" 70)"
  done
  ;;

last)
  prefix=${2:-}
  row=$(filter "$prefix" | tail -1)
  [[ -n "$row" ]] || { print -r -- "no call matching \"$prefix\""; exit 1 }
  IFS=$'\t' read -r start end secs outcome tool command desc <<< "$row"
  ago=$(( EPOCHSECONDS - $(iso_ep "$start") ))
  print -r -- "$outcome, $(fmt_dur $secs), $(fmt_dur $ago) ago at $start"
  [[ -n "$desc" ]] && print -r -- "  $desc"
  print -r -- "  ${command//$'\t'/ }"
  ;;

transitions)
  prefix=${2:-}
  prev=""
  typeset -a hits
  while IFS=$'\t' read -r start end secs outcome tool command desc; do
    [[ -n "$start" ]] || continue
    [[ -n "$prev" && "$prev" != "$outcome" ]] &&
      hits+=( "$(printf '  %s  %-14s  %s' "${start:0:19}Z" "$prev -> $outcome" "$(clip "$command" 60)")" )
    prev=$outcome
  done < <(filter "$prefix")
  if (( ! $#hits )); then
    print -r -- "no change of outcome for \"$prefix\""
    exit 1
  fi
  print -r -- "$#hits change$( (( $#hits == 1 )) || print s ) of outcome for \"$prefix\""
  print -l -- "${hits[@]: -10}"
  ;;

turns)
  # The one query whose unit is the turn. Everything else here is a question
  # about calls, which is why this had to re-derive nothing: the window, the
  # merge and the exclusions all come from TS_JQ_SPANS, the same arithmetic the
  # stamp reports one turn at a time.
  trows=$(jq -r "$JQ_TURNS" -s "$transcript" 2>/dev/null) \
    || die "could not parse $transcript"
  matched=$(print -r -- "$trows" | while IFS=$'\t' read -r ts dur tool agent calls nps caption; do
    [[ -n "$ts" ]] || continue
    if (( cutoff )); then
      e=$(iso_ep "$ts"); [[ -n "$e" ]] && (( e >= cutoff )) || continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$dur" "$tool" "$agent" "$calls" "$nps" "$caption"
  done)
  if [[ -z "$matched" ]]; then
    print -r -- "no completed turns${within:+ in the last $within}"
    exit 1
  fi
  n=$(print -r -- "$matched" | wc -l | tr -d ' ')
  print -r -- "$n turn$( (( n == 1 )) || print s )${within:+ in the last $within}"
  # A header, unlike the other queries, because five numeric columns without one
  # are a puzzle rather than a table.
  printf '  %-10s %7s %7s %7s %6s  %s\n' ended turn tools agent calls prompt
  print -r -- "$matched" | tail -20 | while IFS=$'\t' read -r ts dur tool agent calls nps caption; do
    # A zero prints as a dash. The reader is scanning for where the time went,
    # and a column of 0.0s is noise that hides the rows that have an answer.
    a="-"; (( agent )) && a=$(fmt_dur $agent)
    t="-"; (( tool ))  && t=$(fmt_dur $tool)
    extra=""; (( nps > 1 )) && extra=" [+$((nps - 1)) mid-turn]"
    printf '  %s  %7s %7s %7s %6s  %s\n' \
      "${ts:11:8}Z" "$(fmt_dur $dur)" "$t" "$a" "$calls" "$(clip "$caption$extra" 52)"
  done
  ;;

elapsed)
  first=$(jq -r 'first(.[] | select(.timestamp) | .timestamp)' -s "$transcript" 2>/dev/null)
  lastt=$(jq -r 'last(.[]  | select(.timestamp) | .timestamp)' -s "$transcript" 2>/dev/null)
  [[ -n "$first" && "$first" != null ]] || die "no timestamps in $transcript"
  print -r -- "first record $first"
  print -r -- "  elapsed  $(fmt_dur $(( $(iso_ep "$lastt") - $(iso_ep "$first") )))"
  print -r -- "  records  $(wc -l < "$transcript" | tr -d ' ')"
  ;;

*) die "unknown query: $cmd" ;;
esac

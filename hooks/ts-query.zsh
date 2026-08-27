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
#   ts-query recent <prefix> [--within 30m]   how often, and when
#   ts-query last <prefix>                    outcome and age of the last run
#   ts-query transitions <prefix>             where pass and fail changed places
#   ts-query elapsed                          session, last turn, last stop
#
# --transcript PATH overrides the file. With no override the newest transcript
# for the current directory's project is used.
#
# Records flagged isSidechain are excluded. The field is in the envelope schema
# but has never been set in any transcript here, so how a subagent's tool calls
# are recorded is untested: they may share this file or have one of their own.
# Excluding them is right either way. If they share the file, a subagent's work
# does not inflate the main session's counts. If they do not, the filter costs
# nothing. Worth revisiting with a transcript that actually has some.
emulate -L zsh
zmodload zsh/datetime
setopt pipefail

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
  (map(select(.isSidechain != true)
       | select(.type == "assistant" and (.message.content | type) == "array")
       | .timestamp as $ts
       | .message.content[]
       | select(.type == "tool_use")
       | {id: .id, start: $ts, tool: .name, cmd: (. | cmd)})) as $starts
  | (map(select(.isSidechain != true)
         | select((.message.content | type) == "array")
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
          (.cmd | gsub("[\t\n]"; " "))
        ] | @tsv)[]
'

transcript=""
typeset -a rest
while (( $# )); do
  case "$1" in
    --transcript) transcript=$2; shift 2 ;;
    --contains)   contains=1; shift ;;
    --within)     within=$2; shift 2 ;;
    *)            rest+=("$1"); shift ;;
  esac
done
set -- "${rest[@]}"

cmd=${1:-}
[[ -n "$cmd" ]] || die "usage: ts-query recent|last|transitions|elapsed [prefix] [--within 30m]"

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
filter() {
  local prefix=$1
  print -r -- "$rows" | while IFS=$'\t' read -r start end secs outcome tool command; do
    [[ -n "$start" ]] || continue
    if [[ -n "$prefix" ]]; then
      if (( ${contains:-0} )); then
        [[ "$command" == *"$prefix"* || "$tool" == *"$prefix"* ]] || continue
      else
        [[ "$command" == "$prefix"* || "$tool" == "$prefix"* ]] || continue
      fi
    fi
    if (( cutoff )); then
      local e=$(iso_ep "$start"); [[ -n "$e" ]] && (( e >= cutoff )) || continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$start" "$end" "$secs" "$outcome" "$tool" "$command"
  done
}

case "$cmd" in

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
  print -r -- "$matched" | tail -10 | while IFS=$'\t' read -r start end secs outcome tool command; do
    printf '  %s  %8s  %-6s  %s\n' "${start:11:8}Z" "$(fmt_dur $secs)" "$outcome" "${command:0:70}"
  done
  ;;

last)
  prefix=${2:-}
  row=$(filter "$prefix" | tail -1)
  [[ -n "$row" ]] || { print -r -- "no call matching \"$prefix\""; exit 1 }
  IFS=$'\t' read -r start end secs outcome tool command <<< "$row"
  ago=$(( EPOCHSECONDS - $(iso_ep "$start") ))
  print -r -- "$outcome, $(fmt_dur $secs), $(fmt_dur $ago) ago at $start"
  print -r -- "  $command"
  ;;

transitions)
  prefix=${2:-}
  prev=""
  typeset -a hits
  while IFS=$'\t' read -r start end secs outcome tool command; do
    [[ -n "$start" ]] || continue
    [[ -n "$prev" && "$prev" != "$outcome" ]] &&
      hits+=( "$(printf '  %s  %-14s  %s' "${start:0:19}Z" "$prev -> $outcome" "${command:0:60}")" )
    prev=$outcome
  done < <(filter "$prefix")
  if (( ! $#hits )); then
    print -r -- "no change of outcome for \"$prefix\""
    exit 1
  fi
  print -r -- "$#hits change$( (( $#hits == 1 )) || print s ) of outcome for \"$prefix\""
  print -l -- "${hits[@]: -10}"
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

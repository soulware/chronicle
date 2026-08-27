#!/bin/zsh
# SessionStart: stamp the opening of a session, name the commit doing the
# stamping, and say once that the transcript can be queried.
#
# The pointer is here rather than on every turn because it is a standing fact
# about the session, and repeating it would teach the reader to skip it. The
# path is included because deriving it is possible but fails silently in the
# worst direction: a wrong guess finds no file and reads as "there is nothing
# to query" rather than "that was the wrong path".
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
tp=$(print -r -- "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)
src=$(print -r -- "$payload" | jq -r '.source // "unknown"' 2>/dev/null)
src=${src//[^A-Za-z0-9_-]/}

now=$(ts_now_iso)
# The version says which commit is stamping. Hooks installed mid-session leave
# earlier turns unstamped, and this is what tells the two cases apart.
ver=$(git -C "${0:A:h}" rev-parse --short HEAD 2>/dev/null)
ctx="<time now=\"$now\" session_source=\"$src\""
[[ -n "$ver" ]] && ctx+=" chronicle=\"$ver\""
ctx+="/>"

if [[ -n "$tp" ]]; then
  ctx+="<transcript path=\"$tp\" query=\"${0:A:h}/ts-query.zsh\">"
  ctx+="How long a command took, how often it has been run, whether it passed "
  ctx+="last time, and when a file was last changed are all answerable from "
  ctx+="here, including for turns that have since been compacted away."
  ctx+="</transcript>"
fi

msg="$now  ·  session $src"
ts_emit SessionStart "$ctx" "$msg"
exit 0

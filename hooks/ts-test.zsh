#!/bin/zsh
# Assertions over the hook scripts. Exits non-zero on the first failing run, so
# it can gate a release or run against each new Claude Code version.
#
# The two things it exists to catch both fail silently in normal use: an event
# that stops accepting hookSpecificOutput, and a transcript format that drifts
# under the compaction parser. Neither raises an error, both just stop
# producing stamps, so they need a test that looks at the output rather than
# one that watches for a crash.
emulate -L zsh
D="${0:A:h}"
export TS_STATE_DIR="$D/state-test"
rm -rf "$TS_STATE_DIR"
chmod +x "$D"/ts-*.zsh

typeset -i PASS=0 FAIL=0

t_ok()  { print -r -- "  ok    $1"; (( PASS++ )); return 0 }
t_bad() { print -r -- "  FAIL  $1"; print -r -- "        $2"; (( FAIL++ )); return 0 }

t_eq()      { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "got [$2] want [$3]" }
t_match()   { [[ "$2" =~ $3 ]]   && t_ok "$1" || t_bad "$1" "[$2] does not match /$3/" }
t_absent()  { [[ "$2" =~ $3 ]]   && t_bad "$1" "[$2] unexpectedly matches /$3/" || t_ok "$1" }
t_json()    { print -r -- "$2" | jq -e . > /dev/null 2>&1 && t_ok "$1" \
                || t_bad "$1" "not valid json: [$2]" }

# Durations under a minute are printed as %.1fs, so the numeric part compares
# directly. Sleeps overshoot, never undershoot, hence the one-sided tolerance.
t_near() {
  local v=${2%s}
  (( v >= $3 && v <= $4 )) && t_ok "$1" || t_bad "$1" "[$2] outside ${3}s..${4}s"
}

# Attributes are space separated, so the leading space keeps a lookup for dur
# from matching last_turn_dur.
attr() {
  local key=$1 xml=$2
  [[ "$xml" == *" $key=\""* ]] || { print -r -- ""; return 1 }
  local x=${xml#* $key=\"}
  print -r -- ${x%%\"*}
}

ctx_of() { print -r -- "$1" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null }
evt_of() { print -r -- "$1" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null }
msg_of() { print -r -- "$1" | jq -r '.systemMessage // ""' 2>/dev/null }
state()  { ls "$TS_STATE_DIR/test-sess" 2>/dev/null | grep -c "$1" }

TOOL='{"session_id":"test-sess","tool_use_id":"toolu_T1","tool_name":"Bash","tool_input":{"command":"cargo test -p elide-core"}}'
TOOLR='{"session_id":"test-sess","tool_use_id":"toolu_T1","tool_name":"Bash","tool_input":{"command":"cargo test"},"tool_response":{"stdout":"ok"}}'
PROMPT='{"session_id":"test-sess","prompt":"hello"}'

print -r -- "=== duration formatter, every branch ==="
source "$D/ts-common.zsh"
for pair in "30:30.0s" "59:59.0s" "60:1m00s" "520:8m40s" "3599:59m59s" "3600:1h00m" "7300:2h01m"; do
  t_eq "fmt ${pair%%:*}" "$(ts_fmt_dur ${pair%%:*})" "${pair##*:}"
done

print -r -- "=== turn 1, the first of a session ==="
out=$(print -r -- "$PROMPT" | "$D/ts-turn.zsh")
c=$(ctx_of "$out")
t_json   "turn emits valid json"        "$out"
t_eq     "turn names its event"         "$(evt_of "$out")" "UserPromptSubmit"
t_match  "carries now"                  "$c" '<time now="[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z"'
t_match  "carries session_start"        "$c" 'session_start="'
t_eq     "elapsed is zero"              "$(attr session_elapsed "$c")" "0s"
t_absent "no gap on the first turn"     "$c" 'since_last_turn'

print -r -- "=== a tool call: pre, wait, post ==="
print -r -- "$TOOL" | "$D/ts-tool-pre.zsh"
sleep 2.4
out=$(print -r -- "$TOOLR" | "$D/ts-tool-post.zsh")
c=$(ctx_of "$out")
t_json   "post emits valid json"        "$out"
t_eq     "post names its event"         "$(evt_of "$out")" "PostToolUse"
t_match  "carries end"                  "$c" '<time end="[0-9]{4}-'
t_near   "dur spans the pre hook"       "$(attr dur "$c")" 2.4 4.5
t_absent "no exec without duration_ms"  "$c" ' exec='

print -r -- "=== duration_ms becomes exec, and the gap between them is the wait ==="
print -r -- "$TOOL" | "$D/ts-tool-pre.zsh"
sleep 1
out=$(print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_T1","duration_ms":150}' | "$D/ts-tool-post.zsh")
c=$(ctx_of "$out")
t_eq     "exec comes from duration_ms"  "$(attr exec "$c")" "0.1s"
t_near   "dur still spans the wait"     "$(attr dur "$c")" 1.0 3.0

print -r -- "=== post with no matching pre, as when hooks arrive mid-session ==="
out=$(print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_ORPHAN"}' | "$D/ts-tool-post.zsh")
c=$(ctx_of "$out")
t_json   "orphan still valid json"      "$out"
t_match  "orphan still stamps end"      "$c" '<time end="'
t_absent "orphan claims no duration"    "$c" ' dur='
t_eq     "orphan is silent in scrollback" "$(msg_of "$out")" ""

print -r -- "=== two calls in flight at once keep separate clocks ==="
A='{"session_id":"test-sess","tool_use_id":"toolu_CA"}'
B='{"session_id":"test-sess","tool_use_id":"toolu_CB"}'
print -r -- "$A" | "$D/ts-tool-pre.zsh"
sleep 1
print -r -- "$B" | "$D/ts-tool-pre.zsh"
sleep 1
t_near "first call sees both sleeps"  "$(attr dur "$(ctx_of "$(print -r -- "$A" | "$D/ts-tool-post.zsh")")")" 2.0 4.0
t_near "second call sees one"         "$(attr dur "$(ctx_of "$(print -r -- "$B" | "$D/ts-tool-post.zsh")")")" 1.0 3.0
t_eq   "no start files left behind"   "$(state '^tool-')" "0"

print -r -- "=== turn 2, deltas populated ==="
sleep 1
c=$(ctx_of "$(print -r -- "$PROMPT" | "$D/ts-turn.zsh")")
t_match "gap since the last turn"     "$c" 'since_last_turn="'
t_match "elapsed is no longer zero"   "$c" 'session_elapsed="[0-9]'

print -r -- "=== stop closes the turn in the scrollback and nowhere else ==="
out=$(print -r -- '{"session_id":"test-sess","hook_event_name":"Stop","last_assistant_message":"done"}' | "$D/ts-stop.zsh")
t_json   "stop emits valid json"      "$out"
t_match  "stop reports the turn cost" "$(msg_of "$out")" 'turn took'
# Context here would read as feedback to act on, which holds the turn open.
t_eq     "stop sends the model nothing" "$(ctx_of "$out")" ""

print -r -- "=== the next turn splits model time from user time ==="
sleep 1
c=$(ctx_of "$(print -r -- "$PROMPT" | "$D/ts-turn.zsh")")
t_match "last_turn_dur from the stop" "$c" 'last_turn_dur="'
t_near  "since_last_stop is the pause" "$(attr since_last_stop "$c")" 1.0 3.0
t_eq    "stop mark consumed"          "$(state '^stop$')" "0"

print -r -- "=== a failed call is stamped as failed and always shown ==="
print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_FAIL"}' | "$D/ts-tool-pre.zsh"
sleep 1
out=$(print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_FAIL","hook_event_name":"PostToolUseFailure","error_type":"exit_code"}' | "$D/ts-tool-post.zsh")
c=$(ctx_of "$out")
t_eq     "failure names its own event"  "$(evt_of "$out")" "PostToolUseFailure"
t_eq     "outcome is marked"            "$(attr outcome "$c")" "failed"
t_match  "failure reaches the scrollback" "$(msg_of "$out")" 'failed'
t_eq     "failure clears its start file" "$(state '^tool-')" "0"

print -r -- "=== a turn dying on an API error is reported once, then forgotten ==="
print -r -- '{"session_id":"test-sess","hook_event_name":"StopFailure","error_type":"overloaded_error"}' | "$D/ts-stop-fail.zsh"
out=$(print -r -- "$PROMPT" | "$D/ts-turn.zsh")
t_eq     "the next turn names the error" "$(attr previous_turn_failed "$(ctx_of "$out")")" "overloaded_error"
t_match  "and says so in the scrollback" "$(msg_of "$out")" 'previous turn failed'
out=$(print -r -- "$PROMPT" | "$D/ts-turn.zsh")
t_absent "the turn after says nothing"   "$(ctx_of "$out")" 'previous_turn_failed'

print -r -- "=== compaction measured from a transcript ==="
# Everything after the last boundary counts, so the 09:00 prompt is out of
# scope, the two that follow are in it, and the tool result is not a prompt.
#
# The trailing records are record types this parser has never been taught. They
# are the drift guard: the transcript format gains types over time, and a new
# one must not be mistaken for a user prompt. If this count moves, the format
# changed underneath the parser, which is the failure this file exists for.
TR="$TS_STATE_DIR/fake-transcript.jsonl"
{
  print -r -- '{"type":"user","timestamp":"2026-08-26T09:00:00.000Z","message":{"content":"before the boundary"}}'
  print -r -- '{"type":"system","subtype":"compact_boundary","timestamp":"2026-08-26T09:30:00.000Z"}'
  print -r -- '{"type":"user","timestamp":"2026-08-26T09:40:00.000Z","message":{"content":"one"}}'
  print -r -- '{"type":"user","timestamp":"2026-08-26T09:50:00.000Z","message":{"content":"two"}}'
  print -r -- '{"type":"user","timestamp":"2026-08-26T09:55:00.000Z","message":{"content":[{"type":"tool_result"}]}}'
  print -r -- '{"type":"attachment","timestamp":"2026-08-26T09:56:00.000Z","message":{"content":"attached"}}'
  print -r -- '{"type":"atis-latch","timestamp":"2026-08-26T09:56:30.000Z","message":{"content":"latched"}}'
  print -r -- '{"type":"ai-title","timestamp":"2026-08-26T09:57:00.000Z","message":{"content":"a title"}}'
  print -r -- '{"type":"last-prompt","timestamp":"2026-08-26T09:57:30.000Z","message":{"content":"echoed"}}'
  print -r -- '{"type":"system","subtype":"turn_duration","timestamp":"2026-08-26T09:58:00.000Z","durationMs":1200}'
  print -r -- '{"type":"file-history-snapshot","message":{"content":"no timestamp at all"}}'
} > "$TR"
out=$(jq -nc --arg t "$TR" '{session_id:"test-sess",transcript_path:$t,hook_event_name:"PreCompact",trigger_reason:"manual"}' | "$D/ts-precompact.zsh")
t_json  "precompact emits valid json"  "$out"
t_match "precompact reports the span"  "$(msg_of "$out")" 'compacting .* 2 prompts'
t_eq    "boundary, trigger and count"  "$(<"$TS_STATE_DIR/test-sess/compaction")" \
        "2026-08-26T09:30:00.000Z|manual|2"

print -r -- "=== postcompact reports the seam but cannot carry it ==="
out=$(jq -nc --arg t "$TR" '{session_id:"test-sess",transcript_path:$t,hook_event_name:"PostCompact"}' | "$D/ts-postcompact.zsh")
t_json  "postcompact emits valid json" "$out"
t_match "seam reaches the scrollback"  "$(msg_of "$out")" 'compacted .* 2 prompts'
# This event rejects hookSpecificOutput, which is why the marker is left in
# state for a later event to deliver. If it ever starts accepting context, this
# assertion fails and the deferral can be removed.
t_eq    "postcompact sends no context" "$(ctx_of "$out")" ""
t_eq    "marker still pending"         "$(state compaction)" "1"

print -r -- "=== SessionStart delivers the pending marker and clears it ==="
out=$(jq -nc --arg t "$TR" '{session_id:"test-sess",transcript_path:$t,hook_event_name:"SessionStart",source:"compact"}' | "$D/ts-session-start.zsh")
c=$(ctx_of "$out")
t_eq     "session start names its event" "$(evt_of "$out")" "SessionStart"
t_eq     "the source is carried"         "$(attr session_source "$c")" "compact"
t_match  "the marker rides along"        "$c" '<compaction covered_from="2026-08-26T09:30:00.000Z"'
t_match  "with its trigger and count"    "$c" 'trigger="manual" prompts="2"'
t_eq     "marker cleared once delivered" "$(state compaction)" "0"
out=$(jq -nc '{session_id:"test-sess",hook_event_name:"SessionStart",source:"resume"}' | "$D/ts-session-start.zsh")
t_absent "a later start carries nothing" "$(ctx_of "$out")" 'compaction'

print -r -- "=== an undelivered marker rides the next turn stamp instead ==="
jq -nc --arg t "$TR" '{session_id:"test-sess",transcript_path:$t,hook_event_name:"PreCompact",trigger:"auto"}' | "$D/ts-precompact.zsh" > /dev/null
c=$(ctx_of "$(print -r -- "$PROMPT" | "$D/ts-turn.zsh")")
t_match "turn stamp carries the marker" "$c" '<compaction covered_from="'
t_eq    "trigger reads from .trigger"   "$(attr trigger "$c")" "auto"
t_eq    "marker cleared once delivered" "$(state compaction)" "0"

print -r -- "=== the model must never be sent a stamp it cannot parse ==="
# Every attribute is quoted, so a stray quote from a payload would split the
# tag. The event name is the one field taken from stdin and echoed back.
out=$(print -r -- '{"session_id":"te\"st","tool_use_id":"a\"b","hook_event_name":"Post\"Evil"}' | "$D/ts-tool-post.zsh")
t_json   "hostile payload stays json"   "$out"
t_absent "no quote leaks into the tag"  "$(ctx_of "$out")" '=""[^ /]'

print -r -- "=== malformed stdin must not break the turn ==="
out=$(print -r -- 'not json' | "$D/ts-tool-post.zsh"); rc=$?
t_eq   "exits clean"                    "$rc" "0"
t_json "still emits valid json"         "$out"

print -r -- "=== a missing transcript is not an error ==="
out=$(jq -nc '{session_id:"test-sess",transcript_path:"/nope/missing.jsonl",hook_event_name:"PreCompact",trigger:"auto"}' | "$D/ts-precompact.zsh"); rc=$?
t_eq "precompact exits clean"           "$rc" "0"

print -r -- ""
if (( FAIL )); then
  print -r -- "$PASS passed, $FAIL FAILED"
  exit 1
fi
print -r -- "$PASS passed"

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
# Most of what follows asserts on the content of a stamp, which means the stamp
# has to be emitted. TS_TOOL_CTX_MIN gates that, and a test call costs a
# fraction of a second, so the gate is held open here and exercised on its own
# further down with env -u, which is the only place the default is in play.
export TS_TOOL_CTX_MIN=0
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
# A gated stamp prints nothing at all, so for the hooks that can fall silent the
# invariant is that whatever does come out parses, not that something comes out.
t_quiet_or_json() { [[ -z "$2" ]] && t_ok "$1" || t_json "$1" "$2" }

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

print -r -- "=== the manifest is the only list, so it has to match the files ==="
# install.sh and uninstall.sh both derive their work from ts-manifest.zsh.
# Nothing else enumerates the hooks, so the one way this can go wrong now is a
# script arriving without a line in the manifest, or a line outliving its
# script. ts-common, ts-manifest and this file are not entry points.
source "$D/ts-manifest.zsh"
typeset -a on_disk in_manifest
on_disk=( ${(f)"$(cd "$D" && print -l -- ts-*.zsh(:r) | grep -vE '^ts-(common|manifest|test|query)$')"} )
in_manifest=( ${(f)"$(ts_scripts)"} )
typeset -a d_sorted m_sorted
d_sorted=( ${(o)on_disk} ); m_sorted=( ${(o)in_manifest} )
t_eq "every script has a manifest line" "${(j:,:)d_sorted}" "${(j:,:)m_sorted}"
for s in $in_manifest; do
  [[ -f "$D/$s.zsh" ]] && t_ok "$s exists" || t_bad "$s exists" "manifest names a missing script"
done
# The events themselves are pinned here rather than derived. Two events share
# ts-tool-post, so dropping one of them leaves every script still present and
# still named, and nothing above would notice. This is the expectation rather
# than a second copy of the implementation: changing the set of events chronicle
# installs should mean editing this line on purpose.
typeset -a want_events w_sorted e_sorted
want_events=(
  PostCompact PostToolUse PostToolUseFailure PreCompact PreToolUse
  SessionStart Stop StopFailure UserPromptSubmit
)
w_sorted=( ${(o)want_events} )
e_sorted=( ${(o)${(f)"$(ts_events)"}} )
t_eq "the event set is what we expect" "${(j:,:)e_sorted}" "${(j:,:)w_sorted}"

# The regex both scripts use to recognise chronicle's own settings entries.
re=$(ts_strip_re)
for s in $in_manifest; do
  [[ "/home/.claude/hooks/$s.zsh" =~ $re ]] && t_ok "strip matches $s" \
    || t_bad "strip matches $s" "/(...)/$s.zsh not matched by $re"
done
t_absent "strip leaves other hooks alone" "/home/.claude/hooks/somebody-else.zsh" "$re"
t_absent "strip is anchored at .zsh"      "/home/.claude/hooks/ts-turn.zsh.bak"  "$re"

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
t_absent "and no wait to compute from it" "$c" ' wait='

print -r -- "=== duration_ms becomes exec, and the gap between them is the wait ==="
print -r -- "$TOOL" | "$D/ts-tool-pre.zsh"
sleep 1
out=$(print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_T1","duration_ms":150}' | "$D/ts-tool-post.zsh")
c=$(ctx_of "$out")
t_eq     "exec comes from duration_ms"  "$(attr exec "$c")" "0.1s"
t_near   "dur still spans the wait"     "$(attr dur "$c")" 1.0 3.0

print -r -- "=== the model's stamp is gated on cost, the scrollback's is not ==="
# env -u drops the override set at the top of this file, so these four run
# against the shipped default of 5 seconds. duration_ms is asserted rather than
# slept, so a nine-second command costs the suite nothing to test.
print -r -- "$TOOL" | "$D/ts-tool-pre.zsh"
out=$(print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_T1","duration_ms":100}' \
      | env -u TS_TOOL_CTX_MIN "$D/ts-tool-post.zsh")
t_eq    "a cheap call says nothing to the model" "$(ctx_of "$out")" ""
t_match "and still draws its scrollback line"    "$(msg_of "$out")" '·'

print -r -- "$TOOL" | "$D/ts-tool-pre.zsh"
out=$(print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_T1","duration_ms":9000}' \
      | env -u TS_TOOL_CTX_MIN "$D/ts-tool-post.zsh")
t_eq    "a slow command passes on exec"          "$(attr exec "$(ctx_of "$out")")" "9.0s"

# The wait has its own threshold, a minute by default, because a five second
# wait is someone answering a prompt and not worth reporting. Lowered here so
# the suite waits one second rather than sixty for the same branch, and
# TS_TOOL_CTX_MIN is left unset to prove the wait passes on its own.
print -r -- "$TOOL" | "$D/ts-tool-pre.zsh"
sleep 1.2
c=$(ctx_of "$(print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_T1","duration_ms":50}' \
      | env -u TS_TOOL_CTX_MIN TS_TOOL_WAIT_MIN=1 "$D/ts-tool-post.zsh")")
t_match "a slow wait passes on the wait alone"   "$c" '<time end="'
t_near  "and the wait is precomputed, not left"  "$(attr wait "$c")" 1.0 3.0
# Same call, default thresholds: 1.2s of wait is not a minute, so it says
# nothing. The wait gate has to be slack enough that answering a prompt at a
# normal speed is not an event.
print -r -- "$TOOL" | "$D/ts-tool-pre.zsh"
sleep 1.2
t_eq    "a short wait is not an event"           "$(ctx_of "$(print -r -- \
        '{"session_id":"test-sess","tool_use_id":"toolu_T1","duration_ms":50}' \
        | env -u TS_TOOL_CTX_MIN "$D/ts-tool-post.zsh")")" ""

print -r -- "=== post with no matching pre, as when hooks arrive mid-session ==="
out=$(print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_ORPHAN"}' | "$D/ts-tool-post.zsh")
c=$(ctx_of "$out")
t_quiet_or_json "orphan emits nothing broken" "$out"
# An end with no duration behind it is the shape the gate exists to suppress,
# and it is what the SessionStart marker is there to explain: a call unstamped
# because the hooks were not yet installed reads like one the gate let through.
t_eq     "orphan sends the model nothing" "$c" ""
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
t_match  "stop stamps the time"       "$(msg_of "$out")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z'
t_match  "stop reports session elapsed" "$(msg_of "$out")" 'into session'
# showTurnDuration is a Claude Code setting that defaults to on and already
# draws the turn duration after every turn. Printing it again would put the
# same number twice on adjacent lines.
t_absent "the duration is left to the built-in" "$(msg_of "$out")" 'turn took'
# Context here would read as feedback to act on, which holds the turn open.
t_eq     "stop sends the model nothing" "$(ctx_of "$out")" ""
# The message is cosmetic, this is not: the next turn stamp reads this mark to
# tell the model's work from the user's pause.
t_eq     "stop leaves its mark"       "$(state '^stop$')" "1"

print -r -- "=== the next turn splits model time from user time ==="
sleep 1
c=$(ctx_of "$(print -r -- "$PROMPT" | "$D/ts-turn.zsh")")
t_match "last_turn_dur from the stop" "$c" 'last_turn_dur="'
t_near  "since_last_stop is the pause" "$(attr since_last_stop "$c")" 1.0 3.0
t_eq    "stop mark consumed"          "$(state '^stop$')" "0"

print -r -- "=== a failed call is stamped as failed and always shown ==="
print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_FAIL"}' | "$D/ts-tool-pre.zsh"
sleep 1
# env -u again: a one-second failure is well under the default threshold, so
# this only reaches the model if failure is exempt from the gate.
out=$(print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_FAIL","hook_event_name":"PostToolUseFailure","error_type":"exit_code","duration_ms":80}' \
      | env -u TS_TOOL_CTX_MIN "$D/ts-tool-post.zsh")
c=$(ctx_of "$out")
t_eq     "failure names its own event"  "$(evt_of "$out")" "PostToolUseFailure"
t_match  "failure outruns the gate"     "$c" '<time end="'
# A rejection is a wait with nothing running behind it; a timeout is execution
# that ran out. Both attributes are present so the two do not have to be told
# apart by subtraction.
t_eq     "exec separates the two kinds"  "$(attr exec "$c")" "0.1s"
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
# The pre-hook runs first so the call is timed and the gate lets the stamp
# through: an assertion about quoting is worth nothing against an empty stamp.
H='{"session_id":"te\"st","tool_use_id":"a\"b","hook_event_name":"Post\"Evil"}'
print -r -- "$H" | "$D/ts-tool-pre.zsh"
out=$(print -r -- "$H" | "$D/ts-tool-post.zsh")
t_json   "hostile payload stays json"   "$out"
t_match  "and is stamped at all"        "$(ctx_of "$out")" '<time end="'
t_eq     "the event name is echoed back" "$(evt_of "$out")" 'Post"Evil' 
t_absent "no quote leaks into the tag"  "$(ctx_of "$out")" '=""[^ /]'

print -r -- "=== malformed stdin must not break the turn ==="
out=$(print -r -- 'not json' | "$D/ts-tool-post.zsh"); rc=$?
t_eq            "exits clean"           "$rc" "0"
t_quiet_or_json "and says nothing it cannot say well" "$out"

print -r -- "=== a missing transcript is not an error ==="
out=$(jq -nc '{session_id:"test-sess",transcript_path:"/nope/missing.jsonl",hook_event_name:"PreCompact",trigger:"auto"}' | "$D/ts-precompact.zsh"); rc=$?
t_eq "precompact exits clean"           "$rc" "0"

print -r -- "=== queries read the transcript and never write to it ==="
# A synthetic transcript rather than a live one, so the assertions are exact.
# Three calls: two that start with "cargo test", one that only contains it
# because the real work is behind a compound command, and an outcome that
# changes between the first two.
QT="$TS_STATE_DIR/query-transcript.jsonl"
{
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:00:00.000Z","message":{"content":[{"type":"tool_use","id":"c1","name":"Bash","input":{"command":"cargo test -p core"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:00:45.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"c1","is_error":false}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:10:00.000Z","message":{"content":[{"type":"tool_use","id":"c2","name":"Bash","input":{"command":"cargo test -p core --verbose"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:10:04.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"c2","is_error":true}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:20:00.000Z","message":{"content":[{"type":"tool_use","id":"c3","name":"Bash","input":{"command":"python3 build.py && cargo test -p core"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:20:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"c3","is_error":false}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:30:00.000Z","message":{"content":[{"type":"tool_use","id":"c4","name":"Bash","input":{"command":"still running"}}]}}'
} > "$QT"
Q=( "$D/ts-query.zsh" --transcript "$QT" )

out=$("${Q[@]}" recent 'cargo test')
t_match "recent counts prefix matches"    "$out" '^2 calls matching'
t_absent "and excludes the compound one"  "$out" 'python3 build.py'
# The duration comes from the envelope timestamps, not from anything chronicle
# wrote. This is the claim the whole proposal rests on.
t_match "duration read from the envelope" "$out" '45\.0s'
t_match "is_error becomes an outcome"     "$out" 'failed'

out=$("${Q[@]}" recent 'cargo test' --contains)
t_match "contains finds the compound call" "$out" '^3 calls matching'

# A tool_use with no tool_result is a call still in flight, and is left out
# rather than guessed at.
t_absent "an unfinished call is not reported" "$("${Q[@]}" recent 'still' --contains 2>&1)" 'still running'

# The dangerous failure is the silent one, so a prefix that matches nothing
# says whether a substring would have.
out=$("${Q[@]}" recent 'cargo build' 2>&1); rc=$?
t_eq    "a miss exits non-zero"           "$rc" "1"
t_match "and reports the miss"            "$out" 'no calls starting with'
out=$("${Q[@]}" recent 'test -p core --verb' 2>&1)
t_match "a buried match is pointed at"    "$out" 'try --contains'

out=$("${Q[@]}" last 'cargo test')
t_match "last reports the newest outcome" "$out" '^failed, 4\.0s'

out=$("${Q[@]}" transitions 'cargo test')
t_match "transitions finds the change"    "$out" 'ok -> failed'
t_eq    "and only the change"             "$(print -r -- "$out" | head -1)" "1 change of outcome for \"cargo test\""

# Bounded output is the point of wrapping the query at all: an unbounded row is
# how a query tool becomes the cat it was built to prevent.
long=$(print -r -- "$("${Q[@]}" recent '' --contains)" | awk '{ if (length($0) > n) n = length($0) } END { print n }')
(( long <= 120 )) && t_ok "every row stays bounded" \
  || t_bad "every row stays bounded" "longest row was $long chars"

# A subagent's transcript is a normal transcript with isSidechain set on every
# record. Filtering that flag out reads as an empty file, which is how this was
# broken once already.
ST="$TS_STATE_DIR/sidechain-transcript.jsonl"
{
  print -r -- '{"type":"assistant","isSidechain":true,"timestamp":"2026-08-27T09:00:00.000Z","message":{"content":[{"type":"tool_use","id":"s1","name":"Bash","input":{"command":"echo probe"}}]}}'
  print -r -- '{"type":"user","isSidechain":true,"timestamp":"2026-08-27T09:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"s1","is_error":false}]}}'
} > "$ST"
out=$("$D/ts-query.zsh" --transcript "$ST" recent echo 2>&1)
t_match "a subagent transcript reads normally" "$out" '^1 call matching'
t_match "with its duration intact"             "$out" '3\.0s'

print -r -- "=== file queries are exact where command queries have to guess ==="
# Edit, Write and Read carry an absolute file_path, so identity needs no
# normalisation. structuredPatch carries the real diff and userModified records
# the human quietly fixing what the model wrote.
FT="$TS_STATE_DIR/file-transcript.jsonl"
{
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:00:00.000Z","message":{"content":[{"type":"tool_use","id":"f1","name":"Write","input":{"file_path":"/repo/src/main.rs","content":"x"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:00:01.000Z","toolUseResult":{"filePath":"/repo/src/main.rs","structuredPatch":[],"userModified":false},"message":{"content":[{"type":"tool_result","tool_use_id":"f1","is_error":false}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:05:00.000Z","message":{"content":[{"type":"tool_use","id":"f2","name":"Edit","input":{"file_path":"/repo/src/main.rs","old_string":"a","new_string":"b"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:05:01.000Z","toolUseResult":{"filePath":"/repo/src/main.rs","structuredPatch":[{"lines":["-a","+b","+c"]}],"userModified":true},"message":{"content":[{"type":"tool_result","tool_use_id":"f2","is_error":false}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:09:00.000Z","message":{"content":[{"type":"tool_use","id":"f3","name":"Bash","input":{"command":"sed -i s/a/b/ /repo/src/other.rs"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:09:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"f3","is_error":false}]}}'
} > "$FT"
FQ=( "$D/ts-query.zsh" --transcript "$FT" )

out=$("${FQ[@]}" touched src/main.rs)
t_match "a suffix matches the absolute path" "$out" '^2 operations'
t_match "the diff comes from structuredPatch" "$out" '\+2 -1'
# Nothing else in the record exposes the user silently correcting the model.
t_match "userModified is surfaced"           "$out" 'modified by user'

# The dangerous answer is the one that reads as "untouched" when it means "not
# touched through a tool that records it".
out=$("${FQ[@]}" touched other.rs 2>&1); rc=$?
t_eq    "a shell-only change is not a match"  "$rc" "1"
t_match "and is not reported as untouched"    "$out" 'shell command'
out=$("${FQ[@]}" touched never-seen.rs 2>&1)
t_absent "a genuinely absent file says no more" "$out" 'shell command'

# Querying is done by running commands, so a command query can count itself.
MT="$TS_STATE_DIR/meta-transcript.jsonl"
{
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:00:00.000Z","message":{"content":[{"type":"tool_use","id":"m1","name":"Bash","input":{"command":"cargo test"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:00:05.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"m1","is_error":false}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:01:00.000Z","message":{"content":[{"type":"tool_use","id":"m2","name":"Bash","input":{"command":"zsh hooks/ts-query.zsh recent cargo test"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:01:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"m2","is_error":false}]}}'
} > "$MT"
out=$("$D/ts-query.zsh" --transcript "$MT" recent cargo --contains)
t_match "the tool excludes its own calls"   "$out" '^1 call matching'
t_match "and says that it did"              "$out" 'excluded'
out=$("$D/ts-query.zsh" --transcript "$MT" recent cargo --contains --include-meta)
t_match "include-meta keeps them"           "$out" '^2 calls matching'
# Work on the script is not a query of it, so the exclusion has to distinguish
# invoking ts-query from merely naming the file.
print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:02:00.000Z","message":{"content":[{"type":"tool_use","id":"m3","name":"Bash","input":{"command":"cat -n hooks/ts-query.zsh"}}]}}' >> "$MT"
print -r -- '{"type":"user","timestamp":"2026-08-27T09:02:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"m3","is_error":false}]}}' >> "$MT"
out=$("$D/ts-query.zsh" --transcript "$MT" recent cat --contains)
t_match "reading the script is not a query" "$out" '^1 call matching'
t_absent "so nothing is excluded for it"    "$out" 'excluded'

out=$("$D/ts-query.zsh" --transcript /nope/missing.jsonl recent x 2>&1); rc=$?
t_eq "an unreadable transcript exits 2"   "$rc" "2"

print -r -- ""
if (( FAIL )); then
  print -r -- "$PASS passed, $FAIL FAILED"
  exit 1
fi
print -r -- "$PASS passed"

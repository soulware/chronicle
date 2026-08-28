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
# The events themselves are pinned here rather than derived, so that changing
# the set chronicle installs means editing this line on purpose. The list above
# would still pass with an event silently dropped, since scripts and events are
# not one to one in general.
typeset -a want_events w_sorted e_sorted
want_events=(
  PostCompact PreCompact SessionStart Stop UserPromptSubmit
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
# The bug this guards: the pattern used to be derived from the manifest, so an
# entry for a script that had since been deleted matched nothing, survived every
# reinstall, and left Claude Code invoking a path that no longer existed once
# per tool call. Retired names must still be recognised.
for gone in ts-tool-post ts-tool-pre ts-stop-fail; do
  [[ "/home/.claude/hooks/$gone.zsh" =~ $re ]] && t_ok "strip still matches retired $gone" \
    || t_bad "strip still matches retired $gone" "a removed script would be left in settings.json"
done
t_absent "strip leaves other hooks alone" "/home/.claude/hooks/somebody-else.zsh" "$re"
t_absent "strip is anchored at .zsh"      "/home/.claude/hooks/ts-turn.zsh.bak"  "$re"

print -r -- "=== install and uninstall clean up after events we retired ==="
# Both scripts used to visit only the events currently in the manifest, so an
# entry for an event chronicle no longer installs survived every reinstall,
# pointing at a script that had been deleted. Claude Code reports that as a hook
# error on every fire. Run against a throwaway HOME so the real one is untouched.
FH="$TS_STATE_DIR/fakehome"
rm -rf "$FH"; mkdir -p "$FH/.claude"
cat > "$FH/.claude/settings.json" <<'SETTINGS'
{
  "hooks": {
    "PostToolUse": [{"hooks":[{"type":"command","command":"/old/.claude/hooks/ts-tool-post.zsh"}]}],
    "StopFailure": [{"hooks":[{"type":"command","command":"/old/.claude/hooks/ts-stop-fail.zsh"}]}],
    "PreToolUse": [{"hooks":[{"type":"command","command":"/somebody/else/guard.sh"}]}]
  },
  "theme": "dark"
}
SETTINGS
( HOME="$FH" "${D:h}/install.sh" ) > /dev/null 2>&1
inst="$FH/.claude/settings.json"
ours() { jq -r --arg e "$1" '.hooks[$e][]?.hooks[]?.command // empty' "$inst" 2>/dev/null }
t_eq     "a retired event is cleared"      "$(ours PostToolUse)" ""
t_eq     "and so is its state-only hook"   "$(ours StopFailure)" ""
t_match  "the current hooks are installed" "$(ours UserPromptSubmit)" 'ts-turn\.zsh$'
# The whole point of matching on a convention rather than a list is that it
# must still be narrow enough to leave other people's hooks alone.
t_eq     "another tool's hook is untouched" "$(ours PreToolUse)" "/somebody/else/guard.sh"
t_eq     "and unrelated settings survive"   "$(jq -r .theme "$inst")" "dark"
t_eq     "no state directory is installed"  "$(ls "$FH/.claude/hooks" 2>/dev/null | grep -c '^state$')" "0"

( HOME="$FH" "${D:h}/uninstall.sh" ) > /dev/null 2>&1
t_eq     "uninstall removes ours"          "$(ours UserPromptSubmit)" ""
t_eq     "and still leaves theirs"         "$(ours PreToolUse)" "/somebody/else/guard.sh"

print -r -- "=== duration formatter, every branch ==="
source "$D/ts-common.zsh"
for pair in "30:30.0s" "59:59.0s" "60:1m00s" "520:8m40s" "3599:59m59s" "3600:1h00m" "7300:2h01m"; do
  t_eq "fmt ${pair%%:*}" "$(ts_fmt_dur ${pair%%:*})" "${pair##*:}"
done
# A transcript the hooks can be pointed at. The turn stamp reads every number
# it reports out of a file like this one, so the fixture is the test: change
# what Claude Code records and these assertions are what notices.
mk_tx() {
  local f=$1; shift
  print -l -- "$@" > "$f"
}
P_FIRST='{"type":"system","timestamp":"2026-08-27T09:00:00.000Z","subtype":"session_start"}'
P_ONE='{"type":"user","timestamp":"2026-08-27T09:01:00.000Z","message":{"content":"first prompt"}}'
P_TURN1='{"type":"system","subtype":"turn_duration","timestamp":"2026-08-27T09:03:00.000Z","durationMs":120000}'
P_TWO='{"type":"user","timestamp":"2026-08-27T09:10:00.000Z","message":{"content":"second prompt"}}'
P_TURN2='{"type":"system","subtype":"turn_duration","timestamp":"2026-08-27T09:12:30.000Z","durationMs":150000}'

TX="$TS_STATE_DIR/turn.jsonl"
turn_ctx() { ctx_of "$(jq -nc --arg t "$TX" '{session_id:"t",transcript_path:$t,prompt:"p"}' | "$D/ts-turn.zsh")" }
turn_msg() { msg_of "$(jq -nc --arg t "$TX" '{session_id:"t",transcript_path:$t,prompt:"p"}' | "$D/ts-turn.zsh")" }

print -r -- "=== the turn stamp reads the record instead of its own notes ==="
mkdir -p "$TS_STATE_DIR"
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$P_TURN1" "$P_TWO" "$P_TURN2"
c=$(turn_ctx)
t_json  "turn emits valid json"         "$(jq -nc --arg t "$TX" '{session_id:"t",transcript_path:$t}' | "$D/ts-turn.zsh")"
t_match "carries now"                   "$c" '<time now="[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z"'
# The session began when the transcript did, not when this hook was installed.
t_eq    "session_start is the first record" "$(attr session_start "$c")" "2026-08-27T09:00:00Z"
# turn_duration is Claude Code's own measurement of the turn, so the model's
# half of the gap is read rather than computed.
t_eq    "last_turn_dur comes from turn_duration" "$(attr last_turn_dur "$c")" "2m30s"
t_match "since_last_turn is reported"   "$c" 'since_last_turn="'
t_match "since_last_stop is reported"   "$c" 'since_last_stop="'
t_match "the scrollback line agrees"    "$(turn_msg)" 'into session'

# The whole point of the rewrite: nothing is written down.
t_eq "the turn stamp keeps no state"    "$(ls "$TS_STATE_DIR" | grep -c '^t$')" "0"

print -r -- "=== time a turn spent blocked on the user is reported, not lost ==="
# Claude Code's durationMs discounts time blocked on the user; wall clock from
# prompt to stop counts it. Reading durationMs alone would silently drop it, and
# it falls inside the turn so since_last_stop does not cover it either.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$P_TURN1" \
  '{"type":"user","timestamp":"2026-08-27T09:10:00.000Z","message":{"content":"asks a question"}}' \
  '{"type":"system","subtype":"turn_duration","timestamp":"2026-08-27T09:12:30.000Z","durationMs":30000}'
c=$(turn_ctx)
t_eq "the model's own time is claude code's" "$(attr last_turn_dur "$c")" "30.0s"
t_eq "and the block is named separately"     "$(attr last_turn_blocked "$c")" "2m00s"
# When the two agree there is nothing to report.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$P_TURN1" "$P_TWO" "$P_TURN2"
t_absent "an unblocked turn says nothing"    "$(turn_ctx)" 'last_turn_blocked'

print -r -- "=== the machine's half of the turn is separated from the model's ==="
# durationMs covers the model generating and the machine working as one number,
# and nothing the model can see splits them: a tool result carries no timing.
TC1='{"type":"assistant","timestamp":"2026-08-27T09:01:10.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cargo test"}}]}}'
TR1='{"type":"user","timestamp":"2026-08-27T09:01:40.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false}]}}'
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$TC1" "$TR1" "$P_TURN1"
t_eq "tool time is measured off the call" "$(attr last_turn_tool_time "$(turn_ctx)")" "30.0s"

# Calls issued in one message run at the same time. Summing them would report
# 70s of machine time inside a turn that only spent 40s waiting, and a share of
# the turn above 100%, so overlapping spans are merged.
mk_tx "$TX" "$P_FIRST" "$P_ONE" \
  '{"type":"assistant","timestamp":"2026-08-27T09:01:10.000Z","message":{"content":[{"type":"tool_use","id":"p1","name":"Bash","input":{"command":"a"}},{"type":"tool_use","id":"p2","name":"Bash","input":{"command":"b"}}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:01:40.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"p1","is_error":false}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:01:50.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"p2","is_error":false}]}}' \
  "$P_TURN1"
t_eq "parallel calls are counted once" "$(attr last_turn_tool_time "$(turn_ctx)")" "40.0s"

# The window is the last turn, not the session, so an earlier turn's work does
# not accumulate into this one.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$TC1" "$TR1" "$P_TURN1" "$P_TWO" \
  '{"type":"assistant","timestamp":"2026-08-27T09:10:10.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cargo build"}}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:10:15.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":false}]}}' \
  "$P_TURN2"
t_eq "only the turn that just ended counts" "$(attr last_turn_tool_time "$(turn_ctx)")" "5.0s"

# A turn that only talked has nothing to separate, and saying so on every
# conversational turn would be noise.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$P_TURN1" "$P_TWO" "$P_TURN2"
t_absent "a turn with no tools says nothing" "$(turn_ctx)" 'last_turn_tool_time'

# A call with no result is one still in flight or one the transcript never saw
# finish. ts-query drops those rather than guess at an end, and so does this.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$TC1" "$P_TURN1"
t_absent "an unfinished call is not guessed at" "$(turn_ctx)" 'last_turn_tool_time'

# An Agent call is another model generating, not the machine working, and it is
# the only tool whose cost runs to minutes. Folded in with the rest it would
# report a quarter of an hour at the build for a turn that never ran a command.
AC1='{"type":"assistant","timestamp":"2026-08-27T09:01:50.000Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{"subagent_type":"Explore","prompt":"look"}}]}}'
AR1='{"type":"user","timestamp":"2026-08-27T09:02:50.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"a1","is_error":false}]}}'
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$TC1" "$TR1" "$AC1" "$AR1" "$P_TURN1"
c=$(turn_ctx)
t_eq "the machine's half excludes the subagent" "$(attr last_turn_tool_time "$c")" "30.0s"
t_eq "and delegated time is named on its own"   "$(attr last_turn_subagent_time "$c")" "1m00s"

# A turn that only delegated ran no commands at all, and saying it spent tool
# time would be the conflation this pair exists to undo.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$AC1" "$AR1" "$P_TURN1"
c=$(turn_ctx)
t_absent "delegating alone is not machine time" "$c" 'last_turn_tool_time'
t_eq     "but is still reported"                "$(attr last_turn_subagent_time "$c")" "1m00s"

# Subagents launched together run together, so the same merge applies.
mk_tx "$TX" "$P_FIRST" "$P_ONE" \
  '{"type":"assistant","timestamp":"2026-08-27T09:01:10.000Z","message":{"content":[{"type":"tool_use","id":"a2","name":"Agent","input":{"subagent_type":"Explore"}},{"type":"tool_use","id":"a3","name":"Agent","input":{"subagent_type":"Explore"}}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:01:40.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"a2","is_error":false}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:01:50.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"a3","is_error":false}]}}' \
  "$P_TURN1"
t_eq "parallel subagents are counted once" "$(attr last_turn_subagent_time "$(turn_ctx)")" "40.0s"

# A turn with neither says neither.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$P_TURN1" "$P_TWO" "$P_TURN2"
t_absent "no delegation, no attribute" "$(turn_ctx)" 'last_turn_subagent_time'

# AskUserQuestion is neither the machine nor a delegated model: its span is the
# user deciding. Counting it would put a pause at the keyboard into a number
# claiming to be machine time, and would double-report it, since
# last_turn_blocked already names exactly that time.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$TC1" "$TR1" \
  '{"type":"assistant","timestamp":"2026-08-27T09:01:50.000Z","message":{"content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[]}}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:04:10.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"q1","is_error":false}]}}' \
  "$P_TURN1"
c=$(turn_ctx)
t_eq "waiting on the user is not machine time" "$(attr last_turn_tool_time "$c")" "30.0s"
t_absent "and is not counted as delegation"    "$c" 'last_turn_subagent_time'

# A turn that only asked has no machine time at all to report.
mk_tx "$TX" "$P_FIRST" "$P_ONE" \
  '{"type":"assistant","timestamp":"2026-08-27T09:01:50.000Z","message":{"content":[{"type":"tool_use","id":"q2","name":"AskUserQuestion","input":{"questions":[]}}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:04:10.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"q2","is_error":false}]}}' \
  "$P_TURN1"
t_absent "asking alone reports no tool time" "$(turn_ctx)" 'last_turn_tool_time'

print -r -- "=== the current prompt must not be mistaken for the previous one ==="
# By the time UserPromptSubmit fires, the prompt that triggered it may already
# be on disk. Counting it would report a gap of zero, so the previous prompt is
# taken from before the last completed turn.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$P_TURN1" "$P_TWO" "$P_TURN2" \
  '{"type":"user","timestamp":"2026-08-27T09:20:00.000Z","message":{"content":"the prompt being handled now"}}'
c=$(turn_ctx)
t_eq "the gap is measured to the last finished turn" "$(attr since_last_turn "$c")" "$(attr since_last_turn "$c")"
t_absent "and is never zero"            "$(attr since_last_turn "$c")" '^0\.0s$'

print -r -- "=== the first turn of a session has no deltas to report ==="
mk_tx "$TX" "$P_FIRST"
c=$(turn_ctx)
t_absent "no gap on the first turn"     "$c" 'since_last_turn'
t_absent "and no previous duration"     "$c" 'last_turn_dur'
t_match  "but the session is still dated" "$c" 'session_start="2026-08-27T09:00:00Z"'

print -r -- "=== a turn dying on an API error is reported once, then drops out ==="
# StopFailure used to leave a note. Claude Code already records the death.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$P_TURN1" \
  '{"type":"assistant","timestamp":"2026-08-27T09:05:00.000Z","isApiErrorMessage":true,"error":"overloaded_error","message":{"content":"..."}}'
c=$(turn_ctx)
t_eq    "the next turn names the error" "$(attr previous_turn_failed "$c")" "overloaded_error"
t_match "and says so in the scrollback" "$(turn_msg)" 'previous turn failed'
# A completed turn after the error means it is no longer the previous turn.
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$P_TURN1" \
  '{"type":"assistant","timestamp":"2026-08-27T09:05:00.000Z","isApiErrorMessage":true,"error":"overloaded_error","message":{"content":"..."}}' \
  "$P_TWO" "$P_TURN2"
t_absent "the turn after says nothing"  "$(turn_ctx)" 'previous_turn_failed'

print -r -- "=== turns are delimited by the record, not by the prompts ==="
# The one query whose unit is the turn. Its window, merge and exclusions come
# from TS_JQ_SPANS, so the number it prints for a turn is the number the stamp
# printed for that turn while it was the last one.
TQ="$TS_STATE_DIR/turns-transcript.jsonl"
q_turns() { zsh "$D/ts-query.zsh" turns --transcript "$TQ" "$@" 2>&1 }
mk_tx "$TQ" "$P_ONE" \
  '{"type":"assistant","timestamp":"2026-08-27T09:01:10.000Z","message":{"content":[{"type":"tool_use","id":"u1","name":"Bash","input":{"command":"cargo test"}}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:01:40.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"u1","is_error":false}]}}' \
  '{"type":"assistant","timestamp":"2026-08-27T09:01:45.000Z","message":{"content":[{"type":"tool_use","id":"u2","name":"Agent","input":{"subagent_type":"Explore"}}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:02:45.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"u2","is_error":false}]}}' \
  "$P_TURN1"
out=$(q_turns)
t_eq    "one turn is listed"              "${out%%$'\n'*}" "1 turn"
t_match "the machine and the subagent are separate columns" "$out" '30\.0s +1m00s'
t_match "the prompt captions the turn"    "$out" 'first prompt'
# A transcript that opens with the prompt must not lose it: the first window is
# unbounded below rather than anchored to the first record, which sits exactly
# on the bound.
t_absent "the opening prompt is not dropped" "$out" '\(no prompt\)'

# A message sent while the model is still working lands mid-turn. Counting
# prompts would split one turn in two and report the same durationMs twice.
mk_tx "$TQ" "$P_ONE" \
  '{"type":"user","timestamp":"2026-08-27T09:02:00.000Z","message":{"content":"sent while it was working"}}' \
  "$P_TURN1"
out=$(q_turns)
t_eq    "an interrupt does not open a turn" "${out%%$'\n'*}" "1 turn"
t_match "and is counted where it happened" "$out" '\[\+1 mid-turn\]'

# A turn still in flight has no turn_duration, on the same grounds as a call
# with no result.
mk_tx "$TQ" "$P_ONE"
t_match "an unfinished turn is not listed" "$(q_turns)" 'no completed turns'

# The point of sharing TS_JQ_SPANS rather than copying it. The stamp reports
# one turn as it ends and the query reports every turn afterwards; if the two
# ever disagreed about the same turn, one of them would be lying and there
# would be no way to tell which.
mk_tx "$TQ" "$P_ONE" \
  '{"type":"assistant","timestamp":"2026-08-27T09:01:10.000Z","message":{"content":[{"type":"tool_use","id":"x1","name":"Bash","input":{"command":"a"}},{"type":"tool_use","id":"x2","name":"Bash","input":{"command":"b"}}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:01:40.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"x1","is_error":false}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:01:55.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"x2","is_error":false}]}}' \
  '{"type":"assistant","timestamp":"2026-08-27T09:02:00.000Z","message":{"content":[{"type":"tool_use","id":"x3","name":"Agent","input":{"subagent_type":"Explore"}}]}}' \
  '{"type":"user","timestamp":"2026-08-27T09:02:30.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"x3","is_error":false}]}}' \
  "$P_TURN1"
stamp=$(ctx_of "$(jq -nc --arg t "$TQ" '{session_id:"t",transcript_path:$t,prompt:"p"}' | "$D/ts-turn.zsh")")
qrow=$(q_turns | tail -1)
t_eq "the query agrees with the stamp on tool time" \
  "$(print -r -- "$qrow" | awk '{print $3}')" "$(attr last_turn_tool_time "$stamp")"
t_eq "and on delegated time" \
  "$(print -r -- "$qrow" | awk '{print $4}')" "$(attr last_turn_subagent_time "$stamp")"

# A slash command closes a turn without anyone typing at the model. Naming it
# beats a blank row, which reads as broken output.
mk_tx "$TQ" \
  '{"type":"system","subtype":"local_command","timestamp":"2026-08-27T09:01:00.000Z"}' \
  "$P_TURN1"
t_match "a prompt-less turn says what it was" "$(q_turns)" '\(local_command\)'

print -r -- "=== a compaction boundary is found in the record and reported once ==="
mk_tx "$TX" "$P_FIRST" "$P_ONE" "$P_TURN1" \
  '{"type":"system","subtype":"compact_boundary","timestamp":"2026-08-27T09:05:00.000Z"}' \
  '{"type":"user","timestamp":"2026-08-27T09:06:00.000Z","message":{"content":"after the seam"}}'
c=$(turn_ctx)
t_match "the boundary rides the turn stamp" "$c" '<compaction covered_from="2026-08-27T09:05:00.000Z"'
t_match "with the span it folded"       "$c" 'span="'
t_match "and where the detail still lives" "$c" 'transcript="'
# Once the current prompt is newer than the boundary, the seam is behind us.
mk_tx "$TX" "$P_FIRST" "$P_ONE" \
  '{"type":"system","subtype":"compact_boundary","timestamp":"2026-08-27T09:05:00.000Z"}' \
  "$P_TWO" "$P_TURN2"
t_absent "and is not reported again"    "$(turn_ctx)" '<compaction'

print -r -- "=== stop closes the turn in the scrollback and nowhere else ==="
out=$(jq -nc --arg t "$TX" '{session_id:"t",transcript_path:$t,hook_event_name:"Stop"}' | "$D/ts-stop.zsh")
t_json   "stop emits valid json"        "$out"
t_match  "stop stamps the time"         "$(msg_of "$out")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z'
t_match  "stop reports session elapsed" "$(msg_of "$out")" 'into session'
# showTurnDuration already draws the turn duration after every turn.
t_absent "the duration is left to the built-in" "$(msg_of "$out")" 'turn took'
# Context here would read as feedback to act on, which holds the turn open.
t_eq     "stop sends the model nothing" "$(ctx_of "$out")" ""
t_eq     "and leaves nothing behind"    "$(ls "$TS_STATE_DIR" | grep -c '^t$')" "0"

print -r -- "=== SessionStart names the commit doing the stamping ==="
out=$(jq -nc --arg t "$TX" '{session_id:"t",transcript_path:$t,hook_event_name:"SessionStart",source:"resume"}' | "$D/ts-session-start.zsh")
c=$(ctx_of "$out")
t_eq     "session start names its event" "$(evt_of "$out")" "SessionStart"
t_eq     "the source is carried"         "$(attr session_source "$c")" "resume"

print -r -- "=== compaction is measured from the transcript at both ends ==="
TR="$TS_STATE_DIR/fake-transcript.jsonl"
# The trailing records are record types this parser has never been taught. They
# are the drift guard: the transcript format gains types over time, and a new
# one must not be mistaken for a user prompt. If this count moves, the format
# changed underneath the parser, which is the failure this file exists for.
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
out=$(jq -nc --arg t "$TR" '{session_id:"t",transcript_path:$t,hook_event_name:"PreCompact",trigger_reason:"manual"}' | "$D/ts-precompact.zsh")
t_json  "precompact emits valid json"  "$out"
t_match "precompact reports the span"  "$(msg_of "$out")" 'compacting .* 2 prompts'
t_eq    "and writes nothing down"      "$(ls "$TS_STATE_DIR" | grep -c '^t$')" "0"
out=$(jq -nc --arg t "$TR" '{session_id:"t",transcript_path:$t,hook_event_name:"PostCompact"}' | "$D/ts-postcompact.zsh")
t_json  "postcompact emits valid json" "$out"
t_match "seam reaches the scrollback"  "$(msg_of "$out")" 'compacted'
# This event rejects hookSpecificOutput, which is why the turn stamp reports the
# boundary instead. If it ever starts accepting context, this assertion fails.
t_eq    "postcompact sends no context" "$(ctx_of "$out")" ""

print -r -- "=== the model must never be sent a stamp it cannot parse ==="
# Every attribute is quoted, so a stray quote from a payload would split the
# tag. error is the field taken from the transcript and echoed back.
mk_tx "$TX" "$P_FIRST" \
  '{"type":"assistant","timestamp":"2026-08-27T09:05:00.000Z","isApiErrorMessage":true,"error":"ev\"il","message":{"content":"x"}}'
t_absent "no quote leaks into the tag"  "$(turn_ctx)" '=""[^ /]'

print -r -- "=== malformed input must not break the turn ==="
out=$(print -r -- 'not json' | "$D/ts-turn.zsh"); rc=$?
t_eq   "exits clean"                    "$rc" "0"
t_json "still emits valid json"         "$out"
out=$(jq -nc '{session_id:"t",transcript_path:"/nope/missing.jsonl"}' | "$D/ts-turn.zsh"); rc=$?
t_eq   "a missing transcript exits clean" "$rc" "0"
t_match "and still stamps the time"     "$(ctx_of "$out")" '<time now="'

print -r -- "=== a missing transcript is not an error ==="
out=$(jq -nc '{session_id:"t",transcript_path:"/nope/missing.jsonl",hook_event_name:"PreCompact",trigger:"auto"}' | "$D/ts-precompact.zsh"); rc=$?
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

print -r -- "=== intent is a caption, not a key ==="
# Bash and Agent calls carry a model-authored description. It is a self-report
# where the command is a measurement, and it captions the headline purpose of a
# call rather than everything the call did, so it groups nothing: in one real
# session fifteen calls ran the test suite and no two shared a description.
IT="$TS_STATE_DIR/intent-transcript.jsonl"
{
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:00:00.000Z","message":{"content":[{"type":"tool_use","id":"i1","name":"Bash","input":{"command":"cd /repo && cargo test","description":"Run the test suite"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"i1","is_error":false}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:01:00.000Z","message":{"content":[{"type":"tool_use","id":"i2","name":"Bash","input":{"command":"python3 patch.py && cargo test","description":"Fix the gate and re-run tests"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:01:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"i2","is_error":false}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:02:00.000Z","message":{"content":[{"type":"tool_use","id":"i3","name":"Write","input":{"file_path":"/repo/a.txt","content":"x"}}]}}'
  print -r -- '{"type":"assistant","timestamp":"2026-08-27T09:03:00.000Z","message":{"content":[{"type":"tool_use","id":"i4","name":"Bash","input":{"command":"ls","description":"A caption long enough that it has to be clipped before it fits the column"}}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:03:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"i4","is_error":false}]}}'
  print -r -- '{"type":"user","timestamp":"2026-08-27T09:02:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"i3","is_error":false}]}}'
} > "$IT"
IQ=( "$D/ts-query.zsh" --transcript "$IT" )

# `last` reads a row into named fields; one too few and the command silently
# absorbs the caption, which still looks like a plausible command.
out=$("${IQ[@]}" last "cd /repo")
t_match "last names the caption"             "$out" 'Run the test suite'
t_absent "and the command keeps no stray tab" "$out" $'\t'

out=$("${IQ[@]}" intents)
t_match "the log lists described calls"      "$out" '^3 described calls'
# Write carries no description, so it has no place in an account of purpose.
t_absent "and skips calls without one"       "$out" 'a\.txt'
# The scaffolding is not the point of the call, and showing it on every row
# hides where stated purpose and actual work part company.
t_match "a leading cd is stripped"           "$out" 'cargo test'
t_absent "so no row leads with cd"           "$out" 'cd /repo'
t_absent "nor with a dangling connector"     "$out" '^ *[0-9:Z]+ +Bash +[^ ].*  &&'

# A clipped caption must not read as a short one.
t_match "a cut caption is marked"            "$("${IQ[@]}" intents)" '…'
t_absent "a short one is left alone"         "$("${IQ[@]}" intents suite)" 'Run the test suite…'

out=$("${IQ[@]}" intents test)
t_match "one word matches both captions"     "$out" '^2 described calls'
out=$("${IQ[@]}" intents gate test)
t_match "two words are an AND"               "$out" '^1 described call'
out=$("${IQ[@]}" intents SUITE)
t_match "matching ignores case"              "$out" '^1 described call'
out=$("${IQ[@]}" intents nonesuch 2>&1); rc=$?
t_eq    "an unmatched word exits non-zero"   "$rc" "1"

# The caption names the headline, so the second call reads as a fix rather than
# as a test run. This is the limitation, asserted so it stays known.
t_absent "a caption hides secondary actions" "$("${IQ[@]}" intents 'Run the test suite')" 'patch\.py'

out=$("$D/ts-query.zsh" --transcript /nope/missing.jsonl recent x 2>&1); rc=$?
t_eq "an unreadable transcript exits 2"   "$rc" "2"

print -r -- ""
if (( FAIL )); then
  print -r -- "$PASS passed, $FAIL FAILED"
  exit 1
fi
print -r -- "$PASS passed"

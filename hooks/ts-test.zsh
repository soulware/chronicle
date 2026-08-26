#!/bin/zsh
emulate -L zsh
D="${0:A:h}"
export TS_STATE_DIR="$D/state-test"
rm -rf "$TS_STATE_DIR"
chmod +x "$D"/ts-*.zsh

TOOL='{"session_id":"test-sess","tool_use_id":"toolu_T1","tool_name":"Bash","tool_input":{"command":"cargo test -p elide-core"}}'
TOOLR='{"session_id":"test-sess","tool_use_id":"toolu_T1","tool_name":"Bash","tool_input":{"command":"cargo test -p elide-core"},"tool_response":{"stdout":"ok"}}'
PROMPT='{"session_id":"test-sess","prompt":"hello"}'

echo "=== duration formatter, every branch ==="
source "$D/ts-common.zsh"
for pair in "30:30.0s" "520:8m40s" "3599:59m59s" "7300:2h01m"; do
  got=$(ts_fmt_dur ${pair%%:*})
  [[ "$got" == "${pair##*:}" ]] && echo "  ok ${pair%%:*} -> $got" \
    || echo "  FAIL ${pair%%:*} -> [$got] want [${pair##*:}]"
done

echo "=== turn 1 (first turn of session) ==="
print -r -- "$PROMPT" | "$D/ts-turn.zsh"

echo "=== tool: pre, wait 2.4s, post ==="
print -r -- "$TOOL" | "$D/ts-tool-pre.zsh"
sleep 2.4
print -r -- "$TOOLR" | "$D/ts-tool-post.zsh"

echo "=== post with no matching pre (hook installed mid-session) ==="
print -r -- '{"session_id":"test-sess","tool_use_id":"toolu_ORPHAN","tool_name":"Read","tool_input":{"file_path":"/x"}}' | "$D/ts-tool-post.zsh"

echo "=== two concurrent calls, distinct ids ==="
A='{"session_id":"test-sess","tool_use_id":"toolu_CA","tool_name":"Bash","tool_input":{"command":"same"}}'
B='{"session_id":"test-sess","tool_use_id":"toolu_CB","tool_name":"Bash","tool_input":{"command":"same"}}'
print -r -- "$A" | "$D/ts-tool-pre.zsh"
sleep 1
print -r -- "$B" | "$D/ts-tool-pre.zsh"
sleep 1
print -r -- "$A" | "$D/ts-tool-post.zsh"   # expect ~2s
print -r -- "$B" | "$D/ts-tool-post.zsh"   # expect ~1s
echo "leftover state files: $(ls "$TS_STATE_DIR/test-sess" | grep -c '^tool-' || true)"

echo "=== turn 2 (deltas populated) ==="
sleep 1
print -r -- "$PROMPT" | "$D/ts-turn.zsh"

echo "=== stop (end of turn) ==="
print -r -- '{"session_id":"test-sess","hook_event_name":"Stop","last_assistant_message":"done"}' | "$D/ts-stop.zsh"

echo "=== malformed stdin must not break the turn ==="
print -r -- 'not json' | "$D/ts-tool-post.zsh"; echo "exit=$?"

echo "=== latency of one pre+post pair ==="
time ( print -r -- "$TOOL" | "$D/ts-tool-pre.zsh" >/dev/null; print -r -- "$TOOLR" | "$D/ts-tool-post.zsh" >/dev/null )

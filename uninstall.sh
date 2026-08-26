#!/bin/zsh
# Remove the chronicle hooks from Claude Code.
set -e

H="$HOME/.claude/hooks"
S="$HOME/.claude/settings.json"

jq '
  def strip: (. // []) | map(select((.hooks // []) | any(.command // "" | test("/ts-(turn|tool-pre|tool-post|stop|stop-fail|precompact|postcompact)\\.zsh$")) | not));
  .hooks.PreToolUse       |= strip
  | .hooks.PostToolUse      |= strip
  | .hooks.UserPromptSubmit |= strip
  | .hooks.PostToolUseFailure |= strip
  | .hooks.Stop             |= strip
  | .hooks.StopFailure      |= strip
  | .hooks.PreCompact       |= strip
  | .hooks.PostCompact      |= strip
  | .hooks |= with_entries(select(.value | length > 0))
  | if (.hooks | length) == 0 then del(.hooks) else . end
' "$S" > "$S.new"

jq -e . "$S.new" > /dev/null
mv "$S.new" "$S"

# ts-common.zsh is only present if an older copy-based install put it there.
rm -f "$H"/ts-common.zsh "$H"/ts-turn.zsh "$H"/ts-tool-pre.zsh "$H"/ts-tool-post.zsh "$H"/ts-stop.zsh "$H"/ts-stop-fail.zsh "$H"/ts-precompact.zsh "$H"/ts-postcompact.zsh
rm -rf "$H/state"

echo "removed. open /hooks once (or restart) so the config watcher reloads."

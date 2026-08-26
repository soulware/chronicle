#!/bin/zsh
# Install the chronicle hooks into Claude Code.
#
# Claude cannot run this itself: the auto mode classifier blocks writes to
# ~/.claude/hooks and ~/.claude/settings.json, since hooks are arbitrary code
# execution and that is Claude Code rewriting its own config. Run it yourself.
set -e

# Every hook pipes through jq, and each one silences its own errors, so a
# missing jq would install cleanly and then simply never stamp anything.
if ! command -v jq > /dev/null; then
  echo "chronicle needs jq. install it first (brew install jq)." >&2
  exit 1
fi

SRC="${0:A:h}/hooks"
H="$HOME/.claude/hooks"
S="$HOME/.claude/settings.json"

# Linked, not copied, so edits in this repo take effect on the next hook fire.
# ts-common.zsh is found through zsh's :A modifier, which resolves the symlink
# back to this directory, so only the entry points need linking.
mkdir -p "$H"
chmod +x "$SRC"/ts-*.zsh
for s in ts-turn ts-tool-pre ts-tool-post ts-stop ts-stop-fail ts-precompact ts-postcompact ts-session-start; do
  ln -sf "$SRC/$s.zsh" "$H/$s.zsh"
done

# A machine that has never written settings starts from an empty object. There
# is nothing to restore in that case, so no backup is taken either.
#
# Written once otherwise. A re-run would capture settings that already have the
# hooks in them, leaving a backup that no longer matches its name.
if [[ -f "$S" ]]; then
  [[ -f "$S.pre-chronicle" ]] || cp "$S" "$S.pre-chronicle"
else
  # The backup is written here too. Without it a second run would find settings
  # that already carry the hooks and back those up under the pre-chronicle name.
  print -r -- '{}' > "$S"
  print -r -- '{}' > "$S.pre-chronicle"
fi

# Chronicle's own entries are stripped first, so re-running replaces them
# rather than stacking a second copy.
jq --arg h "$H" '
  def strip: (. // []) | map(select((.hooks // []) | any(.command // "" | test("/ts-(turn|tool-pre|tool-post|stop|stop-fail|precompact|postcompact|session-start)\\.zsh$")) | not));
  def entry($n): {"hooks":[{"type":"command","command":($h+"/"+$n+".zsh")}]};
  .hooks = (.hooks // {})
  | .hooks.PreToolUse       = ((.hooks.PreToolUse       // []) | strip) + [entry("ts-tool-pre")]
  | .hooks.PostToolUse      = ((.hooks.PostToolUse      // []) | strip) + [entry("ts-tool-post")]
  | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | strip) + [entry("ts-turn")]
  | .hooks.PostToolUseFailure = ((.hooks.PostToolUseFailure // []) | strip) + [entry("ts-tool-post")]
  | .hooks.Stop             = ((.hooks.Stop             // []) | strip) + [entry("ts-stop")]
  | .hooks.StopFailure      = ((.hooks.StopFailure      // []) | strip) + [entry("ts-stop-fail")]
  | .hooks.PreCompact       = ((.hooks.PreCompact       // []) | strip) + [entry("ts-precompact")]
  | .hooks.PostCompact      = ((.hooks.PostCompact      // []) | strip) + [entry("ts-postcompact")]
  | .hooks.SessionStart     = ((.hooks.SessionStart     // []) | strip) + [entry("ts-session-start")]
' "$S" > "$S.new"

jq -e . "$S.new" > /dev/null
mv "$S.new" "$S"

if [[ -f "$S.pre-chronicle" ]]; then
  echo "installed. backup at $S.pre-chronicle"
else
  echo "installed. no backup taken, there were no settings before this."
fi
echo "open /hooks once (or restart) so the config watcher reloads."

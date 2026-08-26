#!/bin/zsh
# Install the chronicle hooks into Claude Code.
#
# Claude cannot run this itself: the auto mode classifier blocks writes to
# ~/.claude/hooks and ~/.claude/settings.json, since hooks are arbitrary code
# execution and that is Claude Code rewriting its own config. Run it yourself.
set -e

SRC="${0:A:h}/hooks"
H="$HOME/.claude/hooks"
S="$HOME/.claude/settings.json"

# Linked, not copied, so edits in this repo take effect on the next hook fire.
# ts-common.zsh is found through zsh's :A modifier, which resolves the symlink
# back to this directory, so only the three entry points need linking.
mkdir -p "$H"
chmod +x "$SRC"/ts-*.zsh
for s in ts-turn ts-tool-pre ts-tool-post; do
  ln -sf "$SRC/$s.zsh" "$H/$s.zsh"
done

cp "$S" "$S.pre-chronicle"

jq --arg h "$H" '
  .hooks = ((.hooks // {}) + {
    "PreToolUse":       ((.hooks.PreToolUse       // []) + [{"hooks":[{"type":"command","command":($h+"/ts-tool-pre.zsh")}]}]),
    "PostToolUse":      ((.hooks.PostToolUse      // []) + [{"hooks":[{"type":"command","command":($h+"/ts-tool-post.zsh")}]}]),
    "UserPromptSubmit": ((.hooks.UserPromptSubmit // []) + [{"hooks":[{"type":"command","command":($h+"/ts-turn.zsh")}]}])
  })
' "$S" > "$S.new"

jq -e . "$S.new" > /dev/null
mv "$S.new" "$S"

echo "installed. backup at $S.pre-chronicle"
echo "open /hooks once (or restart) so the config watcher reloads."

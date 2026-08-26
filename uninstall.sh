#!/bin/zsh
# Remove the chronicle hooks from Claude Code.
set -e

H="$HOME/.claude/hooks"
S="$HOME/.claude/settings.json"

# The same manifest install.sh reads, so the two can never fall out of step.
source "${0:A:h}/hooks/ts-manifest.zsh"

# An event chronicle never touched is left exactly as it was: strip only
# removes entries whose command points at one of our scripts, and the two
# passes afterwards drop keys that strip emptied.
prog='def strip: (. // []) | map(select((.hooks // []) | any(.command // "" | test($re)) | not));
.'
for e in ${(f)"$(ts_events)"}; do
  prog+=$'\n'"| .hooks.$e |= strip"
done
prog+=$'\n''| .hooks |= with_entries(select(.value | length > 0))
| if (.hooks | length) == 0 then del(.hooks) else . end'

jq --arg re "$(ts_strip_re)" "$prog" "$S" > "$S.new"

jq -e . "$S.new" > /dev/null
mv "$S.new" "$S"

for s in ${(f)"$(ts_scripts)"}; do
  rm -f "$H/$s.zsh"
done
# ts-common.zsh is only present if an older copy-based install put it there.
rm -f "$H/ts-common.zsh"
rm -rf "$H/state"

echo "removed. open /hooks once (or restart) so the config watcher reloads."

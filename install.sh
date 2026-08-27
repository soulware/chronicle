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

# Which events exist and which script serves each is written down once, in
# hooks/ts-manifest.zsh. Everything below is derived from it.
source "$SRC/ts-manifest.zsh"

# Linked, not copied, so edits in this repo take effect on the next hook fire.
# ts-common.zsh is found through zsh's :A modifier, which resolves the symlink
# back to this directory, so only the entry points need linking.
mkdir -p "$H"
chmod +x "$SRC"/ts-*.zsh
# A script dropped from the manifest leaves a symlink behind that now dangles,
# and a dangling hook is an error on every tool call rather than a silent no-op.
for old in "$H"/ts-*.zsh(N); do
  [[ -L "$old" && ! -e "$old" ]] && rm -f "$old"
done

for s in ${(f)"$(ts_scripts)"}; do
  ln -sf "$SRC/$s.zsh" "$H/$s.zsh"
done

# No hook keeps state any more. A directory left by an older install is stale
# data that nothing reads and nothing sweeps.
rm -rf "$H/state"

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

# Chronicle's own entries are stripped from every event before anything is
# written, rather than only from the events about to be assigned. An event
# dropped from the manifest is never visited by the loop below, so stripping
# there would leave its entry in place pointing at a script that no longer
# exists — which Claude Code then reports as a hook error on every fire.
#
# An event chronicle never touched is untouched here: strip only removes
# commands that match the naming convention, and the pass at the end drops
# keys that strip emptied.
prog='def strip: (. // []) | map(select((.hooks // []) | any(.command // "" | test($re)) | not));
def entry($n): {"hooks":[{"type":"command","command":($h+"/"+$n+".zsh")}]};
.hooks = ((.hooks // {}) | with_entries(.value |= strip))'
for pair in $TS_HOOKS; do
  event=${pair%%:*} script=${pair#*:}
  prog+=$'\n'"| .hooks.$event = ((.hooks.$event // []) + [entry(\"$script\")])"
done
prog+=$'\n''| .hooks |= with_entries(select(.value | length > 0))'

jq --arg h "$H" --arg re "$(ts_strip_re)" "$prog" "$S" > "$S.new"

jq -e . "$S.new" > /dev/null
mv "$S.new" "$S"

if [[ -f "$S.pre-chronicle" && "$(cat "$S.pre-chronicle")" != '{}' ]]; then
  echo "installed. backup at $S.pre-chronicle"
else
  echo "installed. no backup taken, there were no settings before this."
fi
echo "open /hooks once (or restart) so the config watcher reloads."

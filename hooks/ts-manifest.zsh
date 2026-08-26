#!/bin/zsh
# The events chronicle installs, each paired with the script that serves it.
#
# This is the one place the wiring is written down. install.sh and uninstall.sh
# derive everything they need from it: what to symlink, what to remove, and the
# pattern that recognises chronicle's own entries in settings.json. Adding a
# hook means adding a line here and nothing else.
#
# The mapping is not one to one in either direction, which is why it cannot be
# read off the filenames. A failed tool call carries the same shape as a
# successful one, so ts-tool-post serves both PostToolUse and PostToolUseFailure.
TS_HOOKS=(
  UserPromptSubmit:ts-turn
  PreToolUse:ts-tool-pre
  PostToolUse:ts-tool-post
  PostToolUseFailure:ts-tool-post
  Stop:ts-stop
  StopFailure:ts-stop-fail
  PreCompact:ts-precompact
  PostCompact:ts-postcompact
  SessionStart:ts-session-start
)

# The distinct scripts, in the order they first appear. These are the entry
# points that get linked, and the files an uninstall removes.
ts_scripts() {
  local -a s
  s=( ${TS_HOOKS[@]#*:} )
  print -l -- ${(u)s}
}

ts_events() { print -l -- ${TS_HOOKS[@]%%:*} }

# Matches a settings.json command path that points at one of our scripts.
# Passed to jq as an argument rather than spliced into the program, so the
# script names never have to survive a second round of quoting.
ts_strip_re() {
  local -a s
  s=( ${(f)"$(ts_scripts)"} )
  print -r -- "/(${(j:|:)s})\\.zsh\$"
}

#!/bin/zsh
# The events chronicle installs, each paired with the script that serves it.
#
# This is the one place the wiring is written down. install.sh and uninstall.sh
# derive everything they need from it: what to symlink, what to remove, and the
# pattern that recognises chronicle's own entries in settings.json. Adding a
# hook means adding a line here and nothing else.
#
# Two of these reach the model and three only draw a line in the scrollback.
# That split is the whole design: what the model needs is read back out of the
# transcript, which already records it, and only what the transcript cannot
# answer in time gets pushed.
TS_HOOKS=(
  UserPromptSubmit:ts-turn
  SessionStart:ts-session-start
  Stop:ts-stop
  PreCompact:ts-precompact
  PostCompact:ts-postcompact
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
#
# Deliberately the naming convention rather than the list above. Deriving it
# from the manifest meant an entry for a script that had since been deleted
# matched nothing, survived every reinstall, and left Claude Code invoking a
# path that no longer existed. A strip pattern has to recognise what chronicle
# used to install, not only what it installs now.
ts_strip_re() { print -r -- "/ts-[a-z0-9-]+\\.zsh\$" }

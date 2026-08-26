#!/bin/zsh
# StopFailure: the turn ended on an API error, so Stop never fires and the turn
# closes with no line. This event renders nothing itself, so it leaves a note
# for the next turn stamp to report and clear.
emulate -L zsh
source "${0:A:h}/ts-common.zsh"

payload=$(cat)
session=$(print -r -- "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/_}
kind=$(print -r -- "$payload" | jq -r '.error_type // "unknown"' 2>/dev/null)
kind=${kind//[^A-Za-z0-9_ -]/}

dir="${TS_STATE_DIR}/${session}"
mkdir -p "$dir" || exit 0
print -r -- "$(ts_now_iso)|$kind" > "$dir/turnfail"
exit 0

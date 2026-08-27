# chronicle

Claude Code hooks that give the model a sense of time inside a transcript.

## Why

Claude Code transcripts carry no time information into the model's context. Every
record on disk in `~/.claude/projects/<slug>/<session>.jsonl` already has an
ISO-8601 timestamp, but it sits in the envelope around the `message` object, and
only `.message` is replayed into the prompt. The data is captured and never sent.

The consequence is that the model cannot tell a two-second gap from a two-week
one, cannot say how long a command took, and cannot say when it first saw a test
fail or when it stopped failing.

## What it does

Two stamps reach the model and three lines only reach the scrollback. Both
stamps are appended to the transcript rather than placed in the system prompt,
because minute-precision time in the system prompt would invalidate the prompt
cache prefix on every turn.

`UserPromptSubmit` stamps the turn:

```
<time now="2026-08-26T09:44:31Z" session_start="2026-08-26T08:41:19Z"
      session_elapsed="1h03m" since_last_turn="4m12s"
      last_turn_dur="2m18s" since_last_stop="1m54s"/>
```

Every number in it is read out of the transcript. Claude Code writes an
ISO-8601 timestamp with milliseconds on every record, a `turn_duration` record
at the end of each turn, an `isApiErrorMessage` record when a turn dies, and a
`compact_boundary` record at a seam. `last_turn_dur` is Claude Code's own
measurement rather than one of ours.

Those deltas matter because the gap between turns holds the model's work and
the user's pause as one number. Split, `since_last_stop` is the user's alone,
which is what says whether anyone is at the keyboard.

A turn that died on an API error is named once and then drops out, because the
next completed turn writes a `turn_duration` after it:

```
<time now="..." session_elapsed="..." previous_turn_failed="overloaded_error"/>
```

`SessionStart` opens the session, names the commit doing the stamping, and says
once that the transcript can be queried:

```
<time now="2026-08-26T09:44:31Z" session_source="resume" chronicle="03d949b"/>
<transcript path="/Users/…/<session>.jsonl" query="…/ts-query.zsh">How long a
command took, how often it has been run, whether it passed last time, and when
a file was last changed are all answerable from here, including for turns that
have since been compacted away.</transcript>
```

The pointer is here rather than on every turn because it is a standing fact
about the session, and repeating it would teach the reader to skip it.

Every stamp is UTC and carries its date, so a fragment reads the same in an
excerpt, across midnight, or on the far side of a compaction that took the
anchoring turn stamp with it. Deltas are precomputed because subtracting ISO
timestamps in-context is error-prone.

## What it stopped doing

Chronicle used to stamp every tool call. `PreToolUse` recorded a start time,
`PostToolUse` reported `end`, `dur`, `exec` and `wait`, and three thresholds
decided which of those were worth saying.

All but one of those numbers is in the transcript already, at better precision:
`end` is the `tool_result` record's timestamp, `dur` is the gap between the
`tool_use` and `tool_result` records, and pass or fail is `is_error`. Only
`exec`, the tool's own execution time, appears nowhere.

What kept the per-call hooks alive was not the data but the timing. The record
of a call is written *after* the hook fires, so nothing can report a call's cost
while it is still the current call. That mattered for exactly one signal: a long
permission wait means nobody is at the keyboard.

Learning that a turn late is soon enough, since nothing acts on it in real time.
So `PreToolUse`, `PostToolUse` and `StopFailure` are gone, and with them the
state directory, the daily sweep, and `TS_TOOL_MIN`, `TS_TOOL_CTX_MIN` and
`TS_TOOL_WAIT_MIN`. Nine hooks became five, two of which reach the model.

Chronicle keeps no state at all. Every baton it used to write — the session
start, the last turn, the stop mark, the API-error note, the compaction marker —
stood in for a fact the record already holds, or holds a moment later.

## Scrollback

`additionalContext` reaches the model alone. The same information also goes to
the terminal as a top-level `systemMessage`, so a long session stays scannable
by eye:

```
2026-08-26T10:39:11Z  ·  20m21s into session  ·  +2m06s since last turn
2026-08-26T10:39:26Z  ·  3.1s
2026-08-26T10:39:30Z  ·  20m25s into session
```

Claude Code prefixes each of these with the event and tool, as
`Stop says:`, and that prefix is its own rendering rather than part
of the message.

These carry the full date where the model's tool stamps carry a clock time, on
the grounds that a person scanning back through a week of scrollback wants the
date and the model has a dated turn stamp nearby already.

Nothing reaches the scrollback per tool call any more. `Stop` closes the turn,
`PreCompact` and `PostCompact` mark a seam, and that is all.

## Compaction

Compaction replaces the message history with a summary, and the summary keeps
what the summarising model judged relevant to the task. A `<time>` tag is noise
by that measure, so the stamps go. Measured on a session that had been compacted
once, the only stamps in the summary were ones quoted inside code and test
output, and those survived because the session's subject happened to be
timestamps.

The transcript file keeps every record either way. It is append-only, so the
pre-compaction messages stay on disk alongside a `compact_boundary` marker, and
each record carries an ISO timestamp with milliseconds in its envelope. The
detail is durable and finer-grained than anything these hooks emit. What
compaction takes away is reach, not the record.

So the hooks mark the boundary rather than trying to carry detail across it.
`PreCompact` measures the stretch about to be folded up and writes it to state,
since anything it returns is subject to that same compaction. `PostCompact`
reports the span in the scrollback.

`PostCompact` rejects `hookSpecificOutput`, so it takes no context and the
marker for the model stays in state. The first event that accepts context
claims it and clears it: `SessionStart` where it fires, otherwise the next turn
stamp.

```
<compaction covered_from="2026-08-26T10:17:26.904Z" trigger="manual"
            prompts="25" span="1h35m" transcript="/Users/…/<session>.jsonl"/>
```

`covered_from` anchors on the previous boundary where there is one, so a second
compaction reports the stretch it folded rather than the whole session. The
transcript path is included because the granular record lives there, and a
boundary the model can see is what makes it worth going to look.

## Measured cost

- ~11ms for one `jq` pass over a 682K transcript, once per turn. The per-call
  pair this replaced cost 35ms and ran on every tool call, so a 500-call
  session spent about 18s stopwatching and now spends about 0.2s reading.
- ~35 tokens per turn stamp, and nothing per tool call. Over a session of 20
  turns that is under a thousand tokens, against roughly 8k when every call
  carried a stamp.
- The `SessionStart` pointer costs about 60 tokens, once.

## Querying the record

The stamps say what a call cost at the moment it cost it. Everything
retrospective lives in the transcript, which already records every tool call,
its command, its outcome and an envelope timestamp with milliseconds, and does
so whether these hooks run or not.

`hooks/ts-query.zsh` reads it. Nothing here writes, keeps state, or needs a key
registry:

```
ts-query intents [words] [--within 1h]    what the work was said to be about
ts-query touched <path>                   every read and write of a file
ts-query recent <prefix> [--within 30m]   how often, and when
ts-query last <prefix>                    outcome and age of the last run
ts-query transitions <prefix>             where pass and fail changed places
ts-query elapsed                          span and size of the transcript
```

`touched` is the reliable one and the rest are the approximate ones, because
the tools differ in what they record. `Edit`, `Write` and `Read` carry a
`file_path`, which is an absolute path and therefore an exact key: no prefix,
no normalisation, no coarseness to tune. `Bash` carries one free-form string,
which is why every other query here has to guess.

```
2 operations on "ts-turn.zsh"
  2026-08-27T09:35:59Z  Write
  2026-08-27T09:42:18Z  Edit    +17 -1     modified by user
```

The counts come from `structuredPatch` in the tool result, which holds the real
diff. `userModified` records the human quietly fixing what the model wrote, and
nothing else in the record exposes that.

`intents` reads the `description` that `Bash` and `Agent` calls carry, which is
written by the model at the time of the call:

```
8 described calls in the last 40m
  14:10:44Z  Bash   Census the envelope fields                 jq -r 'paths(scalars)…
  14:20:27Z  Bash   Check whether intent is already recorded   jq -r '.message.conte…
```

It is worth being clear about what this is not. It is not a normalisation key.
A description captions the headline purpose of a call rather than everything
the call did, so it groups nothing: measured on one session, fifteen calls ran
the test suite and no two shared a description, because a call that patches a
file and then runs tests is captioned as the patch. Anything relying on
descriptions to collapse command variants will miss almost all of them.

What it is instead is an account of what the work was about, which is the
question that has no other answer in the record, and the one worth asking after
a compaction.

The command is shown beside the caption because the two have different
standing. A description is a self-report; the command is a measurement. Where
they disagree that is a fact about the session worth seeing rather than an
error to correct.

A file changed by a shell command has no structured record at all, so `touched`
distinguishes the two silences: nothing found, versus nothing found *and* four
shell commands that mention the file. An empty answer that reads as "untouched"
when it means "not touched through a tool that records it" is the same failure
as a stamp that quietly stops firing.

Calls are matched on a command prefix rather than a normalised command, which
makes coarseness a parameter chosen when the question is asked instead of a
decision baked in when the record is written. `--contains` matches anywhere,
for work buried inside a compound command: `python3 build.py && cargo test`
does not start with `cargo test` and never will. A prefix that finds nothing
reports whether a substring would have, so the silent miss, where a call is
assumed not to have happened, is not reachable.

Outcomes come from `is_error` on the `tool_result` record, so pass and fail per
call need no output parsing. The `pipefail` caveat above applies here too: a
piped failure is recorded as a success.

Every path out is bounded. An unbounded row is how a query tool becomes the
`cat` it was built to prevent, and 682K of transcript is about 180k tokens.

Calls that invoked `ts-query` itself are excluded, because querying is done by
running commands and a query about commands otherwise counts its own history.
The count of what was dropped is always reported, and only exclusions the query
would have returned are counted. `--include-meta` keeps them. File queries need
none of this: interrogating the record cannot produce an `Edit`, so a query
keyed on a path can never match itself.

Durations are computed from envelope timestamps, so they need no cooperation
from the hooks and are available for calls made before chronicle was installed.
Measured against chronicle's own stamps on the same calls, the two agree:
13.1s, 13.9s and 33.1s read back as 13.1s, 13.9s and 33.2s.

`exec`, a tool's own execution time, is the exception: it appears nowhere in the
transcript. It used to arrive in the `PostToolUse` payload, and giving that hook
up gives it up too. `dur` covers the whole time a call was outstanding, so what
is lost is the split between running and waiting. See
[issue #1](https://github.com/soulware/chronicle/issues/1).

Subagents keep their own transcript, one file per agent, at
`<project>/<session-id>/subagents/agent-<id>.jsonl`, with `isSidechain` set on
every record. None of it reaches the parent session's file, which gains only
the prompt and the result. Point `--transcript` at one and it reads normally.

Chronicle's hooks do not fire inside a subagent, so those transcripts carry no
stamps at all. Their durations come from envelope timestamps, which is what
this reads anyway, so a subagent's work is queryable even though it was never
stamped.
## Install

```
./install.sh     # backs settings.json up to settings.json.pre-chronicle
./uninstall.sh
```

`jq` is required. Every hook pipes through it and each silences its own errors,
so `install.sh` checks for it up front rather than installing something that
would run cleanly and never stamp anything. A machine with no `settings.json`
yet starts from an empty object, and no backup is taken, there being nothing to
restore.

Then open `/hooks` once, or restart, so the config watcher reloads.

Re-running `install.sh` replaces chronicle's own entries rather than stacking a
second copy, and leaves every other hook alone.

`hooks/ts-manifest.zsh` pairs each event with the script that serves it, and is
the only place that list is written down. `install.sh` and `uninstall.sh` derive
what to link, what to remove, and how to recognise chronicle's own settings
entries from it, so adding a hook means adding a line there and nothing else.
The pairing is one to one now, but the manifest stays the single source: the
strip pattern that recognises chronicle's entries in `settings.json` is derived
from the naming convention rather than the list, so a script dropped from the
manifest is still removed on the next install.

`install.sh` symlinks those entry points into `~/.claude/hooks/`, so editing
this repo changes hook behaviour on the next fire. `ts-common.zsh` is reached
through zsh's `:A` modifier, which resolves the symlink back to this directory,
so it stays where it is. Keep this checkout in place while the hooks are
installed.

Hooks live in `~/.claude/settings.json`, which is user scope, so they apply to
every project on the machine. State is keyed on `session_id`, so concurrent
sessions across projects and git worktrees never collide.

Claude cannot run these itself. The auto mode classifier blocks writes to
`~/.claude/hooks` and `~/.claude/settings.json`, correctly, since hooks are
arbitrary code execution and that is Claude Code rewriting its own config.

## Test

```
zsh hooks/ts-test.zsh
```

Asserts on what each hook emits and exits non-zero on any failure, so it can
gate a release or run against a new Claude Code version.

It checks first that the manifest still matches the scripts on disk and still
names the events chronicle means to install, then covers every branch of the
duration formatter, the first turn and one with
populated deltas, a timed tool call, `duration_ms` becoming `exec`, a post with
no matching pre, both gates and the failure's exemption from them, two
concurrent calls, a failed call, a turn dying on an API
error, the compaction boundary and its deferred marker, a hostile payload, and
malformed stdin.

Two of those matter more than the rest, because both fail silently in normal
use. One is that each event still accepts what it is given: which events carry
`hookSpecificOutput` is not documented anywhere, and the delivery design rests
on the answers. The other is the compaction parser, which reads the transcript
JSONL directly. Its fixture ends with record types the parser has never been
taught, and the prompt count has to stay put; if it moves, the format changed
underneath it.

## Measured behaviour

Confirmed against a live install, 2026-08-26 and 2026-08-27.

- `PostCompact` accepts `systemMessage` and rejects `hookSpecificOutput`, which
  it reports as `(root): Invalid input`, so the boundary reaches the model from
  the next turn stamp instead.
- `Stop` reaches the model through `additionalContext`, but the field means
  feedback to act on and keeps the turn open, so nothing rides it.
- `SessionStart` takes `additionalContext`, on `source="resume"` and on
  `source="compact"`.
- A resume keeps the `session_id` and appends to the same transcript, so a
  resumed session goes on counting from its original start.
- A compaction appends a second `compact_boundary` record and leaves every
  earlier record in place, so the transcript holds each seam in order.
- A subagent keeps its own transcript, one file per agent, at
  `<project>/<session-id>/subagents/agent-<id>.jsonl`, with `isSidechain` set on
  every record. Chronicle's hooks do not fire inside one, so those transcripts
  carry no stamps — but their envelope timestamps are intact, so `ts-query`
  reads them normally. An earlier note here claimed subagent calls fired the
  hooks and carried stamps under the parent's `session_id`; a probe agent on
  2026-08-27 showed otherwise, and none of its tool calls reached the parent
  transcript in any form.
- A background tool call is dispatched and returns immediately, so a turn stamp
  bounds when it landed rather than anything finer. The completion notification
  carries no time of its own.
- The `Bash` tool runs without `pipefail`, so `cargo test | tail -50` exits 0 on
  a failing suite and is recorded with `is_error` false.

### Against Claude Code's own clock

Claude Code records time too, so the two can be compared, and it is worth
knowing where they agree before trusting either against the other.

The clocks agree. Both write UTC, and across 63 stamps in one session the
transcript envelope landed between 0.044s and 1.004s after the stamp it
carried, median 0.476s, spread flat across that second. That is `strftime`
truncating to whole seconds rather than any drift. A stamp is therefore always
at or before the instant it names, never after, by less than a second.

The stamps are UTC and the clock on the wall is usually not. `git log` renders
local time, so a commit and the stamp for the same moment read an hour apart
here without either being wrong. The `Z` is what settles it.

`turn_duration` records in the transcript carry Claude Code's own `durationMs`
for each turn. `last_turn_dur` now reports that number directly rather than
computing its own, so the two agree by construction. The comparison below is
what established that they measure different things, and is kept because the
difference is now reported rather than hidden. Over one session:

```
turn ends        chronicle   claude code   difference
12:13:59            13.5s        12.6s         0.8s
12:15:40            80.9s        49.5s        31.4s
12:21:06            53.4s        52.9s         0.5s
12:30:15           198.3s       198.1s         0.2s
12:36:25           311.7s       310.7s         1.0s
```

Four of the five agree inside a second. The turn that does not is the one
holding an `AskUserQuestion`: Claude Code discounts the time a turn spends
blocked on the user, and wall clock from prompt to stop counts it.

Neither is wrong, and the gap has a name now. `last_turn_blocked` reports it
whenever it reaches a second, because it falls inside the turn and so
`since_last_stop` does not cover it either. Reading `durationMs` without that
would have quietly dropped 31 seconds of a user sitting on a question.

Those records also make the case for the whole thing, since they sit on disk
carrying exactly the duration the model cannot see.

Two settings render time in the terminal, and neither reaches the model.
`showTurnDuration` defaults to on and draws a turn duration after every turn,
which is why the `Stop` line here does not. `showMessageTimestamps` defaults to
off and stamps each message with its arrival time, which overlaps these stamps
in the scrollback if it is turned on. Both are REPL rendering, so neither
changes what the model is given.

## Later

Transcript stamps answer "how long did that take" within one session. They cannot
answer "when did this break and when did it stop breaking", because the transcript
is per-session and compaction discards the body where the stamps live. That needs
a durable append-only ledger keyed by `git rev-parse --git-common-dir` so it
survives across worktrees.

The field that makes the question decidable is code identity recorded alongside
the outcome, not time alone. With `(entity, status, timestamp, HEAD sha, dirty)`
per observation: same sha and same dirty state with a flipped outcome means
nothing in the code changed, so the cause was external or flaky; a different sha
with no session of yours in between means someone else fixed it.

## License

Dual licensed under either of [Apache-2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT),
at your option.

# chronicle

Claude Code hooks that give the model a sense of time, and a query tool that
lets it read its own history back.

## Why

Claude Code transcripts carry no time information into the model's context.
Every record on disk in `~/.claude/projects/<slug>/<session>.jsonl` already has
an ISO-8601 timestamp with milliseconds, but it sits in the envelope around the
`message` object, and only `.message` is replayed into the prompt. Half the file
by weight is never sent.

So the model cannot tell a two-second gap from a two-week one, cannot say how
long a command took, and cannot say when it first saw a test fail or when it
stopped failing.

The data was never missing. It was written down and never read.

That shapes everything here. Chronicle pushes the one thing the record cannot
deliver in time, and reads back the rest.

## What it does

Two stamps reach the model. Both are appended to the transcript rather than
placed in the system prompt, because minute-precision time in a system prompt
would invalidate the prompt cache prefix on every turn.

`UserPromptSubmit` stamps the turn:

```
<time now="2026-08-26T09:44:31Z" session_start="2026-08-26T08:41:19Z"
      session_elapsed="1h03m" since_last_turn="4m12s"
      last_turn_dur="2m18s" last_turn_tool_time="24s" since_last_stop="1m54s"/>
```

Every number in it is read out of the transcript in one `jq` pass. Claude Code
writes a `turn_duration` record at the end of each turn, an `isApiErrorMessage`
record when a turn dies, and a `compact_boundary` record at a seam. Nothing is
carried forward in state; there is no state.

Those deltas matter because the gap between turns holds the model's work and the
user's pause as one number. Split, `since_last_stop` is the user's alone, which
is what says whether anyone is at the keyboard.

`last_turn_dur` is Claude Code's own `durationMs`, which discounts time a turn
spends blocked on the user. Wall clock from prompt to stop counts it. Where the
two differ by a second or more, `last_turn_blocked` names the gap — an
`AskUserQuestion` left sitting, or a permission prompt nobody answered. It falls
inside the turn, so `since_last_stop` does not cover it either, and reading
`durationMs` alone would drop it silently.

What is left inside `durationMs` is the model generating and the machine
working, with nothing separating them. `last_turn_tool_time` is the machine's
half, measured from the gap between each `tool_use` and its `tool_result`. It is
the one number in the stamp the model could not recover by looking at its own
context: it can see every call it made and every result it got back, and none of
them carry timing. Usually it is the small half — across the transcripts this
was built on, tool time is about 8% of turn duration, so a twelve minute turn
whose commands took thirty seconds went into generation, not into the build.

Overlapping calls are merged rather than summed, because calls issued in one
message run at the same time and adding their durations would report more
machine time than the turn contains. A call with no result is one still in
flight, and is left out rather than guessed at. A turn that ran no tools says
nothing, since an explicit zero would appear on every conversational turn to
report that nothing happened.

`Agent` is excluded from that number and reported as `last_turn_subagent_time`
instead. A subagent is another model generating, not the machine working, and it
is the only tool whose cost runs to minutes rather than seconds — so folding it
in would report a quarter of an hour at the build for a turn that never ran a
command. On a real turn from these transcripts the split is the whole story:

```
last_turn_dur="17m36s" last_turn_tool_time="6.5s" last_turn_subagent_time="15m24s"
```

Seventeen minutes, of which the machine worked for six and a half seconds. Read
as one number it would have said fifteen and a half minutes of commands running.
Delegation is rare — 34 calls across the 99 transcripts this was built on — so
the attribute is absent from almost every turn, which is what makes it worth
reading when it appears.

`AskUserQuestion` is excluded for a third reason: its span is the user deciding,
which `last_turn_blocked` already reports, and counting it would file a pause at
the keyboard as machine time. One wait cannot be excluded. A call held at a
permission prompt records only when it was requested and when it returned, with
nothing in between marking the wait for approval, so the prompt inflates the
call it sits inside. Across 1048 real turns that leaves two where tool time
exceeds `durationMs` — one of them by nineteen minutes, a command left sitting
overnight. It is self-announcing rather than silent: `durationMs` discounts time
blocked on the user and these spans do not, so tool time above the turn duration
is itself the sign that a prompt went unanswered.

A turn that died on an API error is named once and then drops out, because the
next completed turn writes a `turn_duration` after it:

```
<time now="…" session_elapsed="…" previous_turn_failed="overloaded_error"/>
```

`SessionStart` opens the session, names the commit doing the stamping, and says
once that the transcript can be read:

```
<time now="2026-08-26T09:44:31Z" session_source="resume" chronicle="03d949b"/>
<transcript path="/Users/…/<session>.jsonl" query="…/hooks/ts-query.zsh">How long
a command took, how often it has been run, whether it passed last time, and when
a file was last changed are all answerable from here, including for turns that
have since been compacted away.</transcript>
```

Once, rather than every turn, because it is a standing fact about the session
and repeating it would teach the reader to skip it. The path is spelled out
because deriving it is possible but fails in the worst direction: a wrong guess
finds no file and reads as *there is nothing to query* rather than *that was the
wrong path*.

The version marker says which commit is stamping. Hooks installed mid-session
leave earlier turns unstamped, and this is what tells that apart from a session
where nothing happened.

Every stamp is UTC and carries its date, so a fragment reads the same in an
excerpt, across midnight, or on the far side of a compaction that took the
anchoring turn stamp with it. Deltas are precomputed because subtracting ISO
timestamps in-context is error-prone.

## Reading the record

The stamps answer *when* and *how long since*. Everything else is a question
about the past, and the past is on disk: every tool call, its command, its
outcome and a millisecond timestamp, written whether these hooks run or not.

`hooks/ts-query.zsh` reads it. Nothing here writes, keeps state, or needs a key
registry:

```
ts-query touched <path>                   every read and write of a file
ts-query intents [words] [--within 1h]    what the work was said to be about
ts-query recent <prefix> [--within 30m]   how often, and when
ts-query last <prefix>                    outcome and age of the last run
ts-query transitions <prefix>             where pass and fail changed places
ts-query elapsed                          span and size of the transcript
```

`touched` is the reliable one and the rest are the approximate ones, because the
tools differ in what they record. `Edit`, `Write` and `Read` carry a
`file_path`, which is absolute and therefore an exact key: no prefix, no
normalisation, no coarseness to tune. `Bash` carries one free-form string, which
is why every other query here has to guess.

```
2 operations on "ts-turn.zsh"
  2026-08-27T09:35:59Z  Write
  2026-08-27T09:42:18Z  Edit    +17 -1     modified by user
```

The counts come from `structuredPatch` in the tool result, which holds the real
diff. `userModified` records the human quietly fixing what the model wrote, and
nothing else in the record exposes that.

A file changed by a shell command has no structured record at all, so `touched`
distinguishes the two silences: nothing found, versus nothing found *and* four
shell commands that mention the file. An empty answer reading as *untouched*
when it means *not touched through a tool that records it* is the same failure
as a stamp that quietly stops firing.

Command queries match on a prefix, which makes coarseness a parameter chosen
when the question is asked rather than a decision baked in when the record was
written. `--contains` matches anywhere, for work buried inside a compound
command: `python3 build.py && cargo test` does not start with `cargo test` and
never will. A prefix that finds nothing reports whether a substring would have,
so the silent miss — concluding a call never happened — is not reachable.

Outcomes come from `is_error` on the `tool_result` record, so pass and fail need
no output parsing. But the `Bash` tool runs without `pipefail`, so
`cargo test | tail -50` exits 0 on a failing suite and is recorded as a success.
An absent failure is not evidence of success.

`intents` reads the `description` that `Bash` and `Agent` calls carry:

```
8 described calls in the last 40m
  14:10:44Z  Bash   Census the envelope fields                 jq -r 'paths(scalars)…
  14:20:27Z  Bash   Check whether intent is already recorded   jq -r '.message.conte…
```

It is not a normalisation key. A description captions the headline purpose of a
call rather than everything the call did, so it groups nothing: measured on one
session, fifteen calls ran the test suite and no two shared a description,
because a call that patches a file and then runs tests is captioned as the
patch. What it answers instead is what the work was *about*, which has no other
source in the record, and is the question worth asking after a compaction.

The command sits beside the caption because the two have different standing. A
description is a self-report; the command is a measurement. Where they disagree
that is a fact about the session rather than an error.

Every path out is bounded. An unbounded row is how a query tool becomes the
`cat` it was built to prevent, and 682K of transcript is about 180k tokens.

Calls that invoked `ts-query` itself are excluded, because querying is done by
running commands and a query about commands otherwise counts its own history.
What was dropped is always reported, and only exclusions the query would have
returned are counted. `--include-meta` keeps them. File queries need none of
this: interrogating the record cannot produce an `Edit`.

Subagents keep their own transcript, one file per agent, at
`<project>/<session-id>/subagents/agent-<id>.jsonl`, with `isSidechain` set on
every record. None of it reaches the parent session's file, which gains only the
prompt and the result. Chronicle's hooks do not fire inside one, so those
transcripts carry no stamps — but their envelope timestamps are intact, so
pointing `--transcript` at one reads it normally. Work that could never have
been stamped is still queryable, which is the argument for reading the record
rather than writing to it, arriving from a direction nobody chose.

## Scrollback

`additionalContext` reaches the model alone. Three hooks also write a top-level
`systemMessage`, which reaches the terminal and the transcript but never the
model's prompt, so a long session stays scannable by eye:

```
2026-08-26T10:39:11Z  ·  20m21s into session  ·  +2m06s since last turn
2026-08-26T10:39:30Z  ·  20m25s into session
```

Claude Code prefixes each with the event, as `Stop says:`, and that prefix is
its own rendering rather than part of the message.

These carry the full date where the model's stamps carry a clock time, on the
grounds that a person scanning back through a week of scrollback wants the date
and the model has a dated turn stamp nearby already.

`Stop` closes the turn with the absolute time and how far into the session it
ended. It does not report how long the turn took: Claude Code's own
`showTurnDuration` defaults to on and already draws that after every turn.

## Compaction

Compaction replaces the message history with a summary, and the summary keeps
what the summarising model judged relevant to the task. A `<time>` tag is noise
by that measure, so the stamps go. Measured on a session compacted once, the
only stamps surviving in the summary were ones quoted inside code and test
output.

The transcript keeps every record either way. It is append-only, so the
pre-compaction messages stay on disk alongside a `compact_boundary` record, and
each carries a millisecond timestamp in its envelope. What compaction takes away
is reach, not the record — which is why the query tool matters most on the far
side of one.

`PreCompact` and `PostCompact` mark the seam in the scrollback. Neither tells
the model anything: `PostCompact` rejects `hookSpecificOutput`, and the boundary
is a record, so the next turn stamp finds it and reports it once.

```
<compaction covered_from="2026-08-26T10:17:26.904Z" prompts="25"
            span="1h35m" transcript="/Users/…/<session>.jsonl"/>
```

`covered_from` anchors on the most recent boundary, so a second compaction
reports the stretch it folded rather than the whole session. It is reported on
the first turn after the seam and not again, because by the next turn the
current prompt is newer than the boundary. The transcript path is included
because the granular record lives there, and a boundary the model can see is
what makes it worth going to look.

## Cost

- ~11ms for one `jq` pass over a 682K transcript, once per turn.
- ~35 tokens per turn stamp. Over a twenty-turn session, under a thousand.
- ~60 tokens for the `SessionStart` pointer, once.
- Nothing at all per tool call.

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
second copy, and leaves every other hook alone. It also clears entries for
events chronicle no longer installs and symlinks left by scripts it no longer
builds — either of which Claude Code reports as a hook error on every fire.

`hooks/ts-manifest.zsh` pairs each event with the script that serves it, and is
the only place that list is written down. `install.sh` and `uninstall.sh` derive
what to link and what to remove from it. The pattern that recognises chronicle's
entries in `settings.json` is deliberately the naming convention rather than the
manifest: an installer has to recognise its own past, not only its present.

`install.sh` symlinks the entry points into `~/.claude/hooks/`, so editing this
repo changes hook behaviour on the next fire. `ts-common.zsh` is reached through
zsh's `:A` modifier, which resolves the symlink back to this directory, so it
stays where it is. Keep this checkout in place while the hooks are installed.

Hooks live in `~/.claude/settings.json`, which is user scope, so they apply to
every project on the machine.

Claude cannot run these itself. The auto mode classifier blocks writes to
`~/.claude/hooks` and `~/.claude/settings.json`, correctly, since hooks are
arbitrary code execution and that is Claude Code rewriting its own config.

## Test

```
zsh hooks/ts-test.zsh
```

Asserts on what each hook emits and exits non-zero on any failure, so it can
gate a release or run against a new Claude Code version.

The two things it exists to catch both fail silently in normal use: an event
that stops accepting `hookSpecificOutput`, and a transcript format that drifts
under the parser. Neither raises an error; both just stop producing stamps.

It covers the manifest matching the scripts on disk, install and uninstall
against a throwaway `HOME` including entries for events since retired, every
branch of the duration formatter, the turn stamp read from a synthetic
transcript, a turn blocked on the user, the first turn of a session, a turn
dying on an API error, a compaction boundary reported once, the scrollback
hooks, a hostile payload, malformed stdin, and every query the tool answers.

The transcript fixtures are the test. Change what Claude Code records and these
assertions are what notices.

## Measured behaviour

Confirmed against a live install, 2026-08-26 and 2026-08-27.

- `PostCompact` accepts `systemMessage` and rejects `hookSpecificOutput`, which
  it reports as `(root): Invalid input`.
- `Stop` reaches the model through `additionalContext`, but the field means
  feedback to act on and keeps the turn open, so nothing rides it.
- `SessionStart` takes `additionalContext`, on `source="resume"` and on
  `source="compact"`.
- A resume keeps the `session_id` and appends to the same transcript, so a
  resumed session goes on counting from its original start.
- A compaction appends a second `compact_boundary` record and leaves every
  earlier record in place, so the transcript holds each seam in order.
- `systemMessage` is persisted to the transcript as a `hook_system_message`
  attachment and does not enter the model's context, so it is a way to write to
  the record for free. `additionalContext` is persisted as
  `hook_additional_context`, carrying `hookEvent`, `hookName` and `toolUseID`,
  so hook output is attributed rather than anonymous.
- A subagent keeps its own transcript and chronicle's hooks do not fire inside
  one. None of its tool calls reach the parent transcript in any form.
- A background tool call is dispatched and returns immediately, so a turn stamp
  bounds when it landed rather than anything finer. The completion notification
  carries no time of its own.
- The `Bash` tool runs without `pipefail`.
- A tool's own execution time appears nowhere in the transcript, so the split
  between time spent running and time spent queued or awaiting approval is the
  one thing here that cannot be recovered after the fact.

### Against Claude Code's own clock

Claude Code records time too, so the two can be compared, and it is worth
knowing where they agree before trusting either against the other.

The clocks agree. Both write UTC, and across 63 stamps in one session the
transcript envelope landed between 0.044s and 1.004s after the stamp it carried,
median 0.476s, spread flat across that second. That is `strftime` truncating to
whole seconds rather than any drift. A stamp is therefore always at or before
the instant it names, never after, by less than a second.

The stamps are UTC and the clock on the wall is usually not. `git log` renders
local time, so a commit and the stamp for the same moment read an hour apart
here without either being wrong. The `Z` is what settles it.

`turn_duration` and wall clock measure different things. Over one session:

```
turn ends        wall clock   claude code   difference
12:13:59              13.5s         12.6s        0.8s
12:15:40              80.9s         49.5s       31.4s
12:21:06              53.4s         52.9s        0.5s
12:30:15             198.3s        198.1s        0.2s
12:36:25             311.7s        310.7s        1.0s
```

Four of the five agree inside a second. The turn that does not is the one
holding an `AskUserQuestion`: Claude Code discounts the time a turn spends
blocked on the user, and wall clock counts it. Neither is wrong, which is why
`last_turn_dur` reports Claude Code's number and `last_turn_blocked` reports the
difference.

Two settings render time in the terminal, and neither reaches the model.
`showTurnDuration` defaults to on and draws a turn duration after every turn,
which is why the `Stop` line here does not. `showMessageTimestamps` defaults to
off and stamps each message with its arrival time, which overlaps these stamps
in the scrollback if it is turned on.

## Later

Within one session the transcript answers everything. Across sessions it does
not: a transcript is per-session, so "when did this break and when did it stop
breaking" spans files, and scanning many of them per query is where a cache
starts to look necessary — and a cache is state, with staleness and
invalidation and a second writer, which is what this design exists without.

`cwd` and `gitBranch` are on every record, so the key that would otherwise need
maintaining is already a column. What is genuinely open is whether the scan
stays fast enough. That is a measurement, not a design problem.

The field that would make the question decidable is code identity recorded
alongside the outcome, not time alone. With `(entity, status, timestamp, HEAD
sha, dirty)` per observation: the same sha and dirty state with a flipped
outcome means nothing in the code changed, so the cause was external or flaky;
a different sha with no session of yours in between means someone else fixed it.

See [issue #1](https://github.com/soulware/chronicle/issues/1).

## License

Dual licensed under either of [Apache-2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT),
at your option.

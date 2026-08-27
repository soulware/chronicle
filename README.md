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

Two stamps, both appended to the transcript rather than placed in the system
prompt. Minute-precision time in the system prompt would invalidate the prompt
cache prefix on every turn.

`UserPromptSubmit` stamps the turn:

```
<time now="2026-08-26T09:44:31Z" session_start="2026-08-26T08:41:19Z"
      session_elapsed="1h03m" since_last_turn="4m12s"
      last_turn_dur="2m18s" since_last_stop="1m54s"/>
```

`PostToolUse` stamps a tool result that cost something:

```
<time end="2026-08-26T09:43:42Z" dur="2.8s" exec="0.4s" wait="2.4s"/>
```

Most calls get no stamp at all. `TS_TOOL_CTX_MIN` sets the seconds a call must
reach to be worth telling the model about, and defaults to 5. A block that
appears on every call and says nothing almost every time teaches the reader to
skip the shape, and the rare informative one goes with it. Gated, the presence
of a stamp is itself the signal: a `cat` that took 0.1s says nothing, and what
survives is worth reading.

The gate reads `exec` rather than `dur`, so a fast command behind a slow
permission prompt is not filed as slow work. Where the payload carries no
`duration_ms` there is nothing to separate and the whole span is measured
instead.

`wait` has its own gate, `TS_TOOL_WAIT_MIN`, defaulting to 60. The two bands do
not line up: five seconds of execution is a slow command, five seconds of wait
is a permission prompt answered by someone sitting there. The only wait worth
reporting is one long enough to mean nobody is at the keyboard. `wait` is still
*reported* from a second, which is what separates a rejection from a timeout on
a failure — the gate decides whether to speak, the second threshold decides
what to say.

`PostToolUseFailure` stamps a call that failed, marking the outcome and ignoring
both gates, on the grounds that a failure is always worth seeing:

```
<time end="2026-08-26T09:43:42Z" outcome="failed" dur="4m12s" exec="0.1s" wait="4m11s"/>
```

The split matters most here, because a rejection and a timeout need opposite
responses and look alike in `dur` alone. A rejection is wait with no execution
behind it and should not be retried. A timeout is execution that ran out of
time and should be.

The exemption covers less than it sounds like. `PostToolUseFailure` fires on
the tool call failing, and the Bash tool runs without `pipefail`, so
`cargo test | tail -50` exits 0 on a failing suite and is stamped, if at all,
as an ordinary call. Piping to bound the output is common precisely on the
commands whose failure matters most. So an absent `outcome="failed"` is not
evidence that anything succeeded, and the stamps say nothing about the result
of a call, only about what it cost. What did or did not pass is in the tool
result, which the model is already reading.

`Stop` closes the turn in the scrollback and records when the model stopped.
It takes `additionalContext`, but the meaning there is feedback the model is
expected to act on, which holds the turn open, so the time goes to state and
the next turn stamp reports it as `last_turn_dur` and `since_last_stop`.

Its scrollback line does not report how long the turn took. Claude Code's own
`showTurnDuration` setting defaults to on and already draws that after every
turn, so the line carries only what the built-in one does not: the absolute
time, and how far into the session the turn ended.

Those two matter because `since_last_turn` holds the model's own work and the
user's pause as one number. Split, `since_last_stop` is the user's gap alone,
which is what says whether anyone is at the keyboard.

`StopFailure` fires when a turn ends on an API error, where `Stop` stays silent.
It renders nothing itself, so it leaves a note that the next turn stamp reports
and clears:

```
<time now="..." session_elapsed="..." previous_turn_failed="overloaded_error"/>
```

`SessionStart` opens the session and names the commit doing the stamping:

```
<time now="2026-08-26T09:44:31Z" session_source="resume" chronicle="03d949b"/>
```

Hooks installed mid-session leave the earlier calls unstamped, which reads the
same as a tool the hooks skip. The version marker separates the two.

Every stamp is UTC and carries its date, so a fragment reads the same in an
excerpt, across midnight, or on the far side of a compaction that took the
anchoring turn stamp with it. Deltas are precomputed because subtracting ISO
timestamps in-context is error-prone.

`dur` is the whole time a call was outstanding, `exec` is the payload's own
execution time, and `wait` is the difference: queuing and approval, outstanding
but not running. A large `wait` is a presence signal rather than a slow command.
It is precomputed for the same reason the turn deltas are, and appears once it
reaches a second, below which there is nothing to say.

Interleaving stamps between tool results is cache-safe. The cache breaks on
rewriting earlier content, not on appending between it, and each stamp is
written once and never revised.

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
`PostToolUse:Bash says:`, and that prefix is its own rendering rather than part
of the message.

These carry the full date where the model's tool stamps carry a clock time, on
the grounds that a person scanning back through a week of scrollback wants the
date and the model has a dated turn stamp nearby already.

`TS_TOOL_MIN` sets the seconds a call must reach before it appears here, and is
a separate gate from `TS_TOOL_CTX_MIN` above because the two readers pay
differently. A line here costs a person a glance, so it defaults to 0 and every
call shows. Raising it to 5 limits the scrollback to slow calls and leaves the
model's stamps untouched; lowering `TS_TOOL_CTX_MIN` to 0 restores a stamp on
every call for the model and leaves the scrollback untouched.

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

- 35ms per pre+post pair, so about 18s across a 500-call session.
- ~16 tokens per tool stamp, ~35 per turn stamp. 8k was the figure when all 500
  calls carried one; under the default gate only the calls that cost something
  do, so the total tracks how much of a session was spent waiting rather than
  how many calls it made.

## Correlation

`PreToolUse` records a start time under the call's `tool_use_id`; `PostToolUse`
reads it back and deletes it. Both events carry that id, so each call is matched
exactly and concurrent calls with identical input stay distinct. `PreToolUse`
emits nothing and therefore costs no context.

A `PostToolUse` with no matching start has no duration to gate on and stamps
nothing, so installing mid-session is safe and leaves the calls already in
flight looking like the cheap ones. Malformed stdin exits 0 the same way. A hook
with nothing to say prints nothing rather than an empty stamp.

State lives in `~/.claude/hooks/state/<session_id>/`, overridable with
`TS_STATE_DIR`. Tool entries older than a day are swept on each turn.

## Querying the record

The stamps say what a call cost at the moment it cost it. Everything
retrospective lives in the transcript, which already records every tool call,
its command, its outcome and an envelope timestamp with milliseconds, and does
so whether these hooks run or not.

`hooks/ts-query.zsh` reads it. Nothing here writes, keeps state, or needs a key
registry:

```
ts-query recent <prefix> [--within 30m]   how often, and when
ts-query last <prefix>                    outcome and age of the last run
ts-query transitions <prefix>             where pass and fail changed places
ts-query elapsed                          span and size of the transcript
```

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

Durations are computed from envelope timestamps, so they need no cooperation
from the hooks and are available for calls made before chronicle was installed.
Measured against chronicle's own stamps on the same calls, the two agree:
13.1s, 13.9s and 33.1s read back as 13.1s, 13.9s and 33.2s.

`exec` is the exception. It arrives in the `PostToolUse` payload and is written
nowhere in the transcript, which is why that hook still has a job. See
[issue #1](https://github.com/soulware/chronicle/issues/1).

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
The pairing is not one to one, which is why it cannot be read off the
filenames: `ts-tool-post` serves both `PostToolUse` and `PostToolUseFailure`.

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

Confirmed against a live install on 2026-08-26.

- `PostToolUse` `additionalContext` renders attached to its own tool result, so
  each stamp stays anchored to the call it describes.
- Both hook payloads carry `tool_use_id`, which is what the matching keys on.
- Hooks fire across every project on the machine, with each session's state in
  its own directory.
- A tool call that fails goes to `PostToolUseFailure` rather than `PostToolUse`,
  which is why both events run the same script. A failure carries its duration
  and clears its start entry like any other call.
- Subagent tool calls fire the hooks and carry stamps, under the parent's
  `session_id`, so parent and subagent share one state directory. Keying on
  `tool_use_id` keeps their entries distinct.
- A background tool call is stamped when it is dispatched, so `dur` covers the
  handoff. A `sleep 12` returned `dur="0.0s"`. The same applies to an async
  `Agent` call, stamped at launch rather than at completion.
- The completion notification for a background task carries no time of its own.
  The following turn stamp is what bounds when it landed.
- `PostCompact` accepts `systemMessage` and rejects `hookSpecificOutput`, which
  it reports as `(root): Invalid input`. `PostToolUseFailure` takes the same
  shape and is accepted, so the schema quoted in that error is abbreviated
  rather than exhaustive.
- The compaction payload names the trigger `trigger`.
- `Stop` reaches the model through `additionalContext`, but the field means
  feedback to act on and keeps the turn open, so a duration cannot ride it.
- `SessionStart` takes `additionalContext`, so the compaction marker reaches
  the model there rather than a turn later. Confirmed on `source="resume"` and
  on `source="compact"`, which is the seam the marker is written for.
- The span in the marker is longer than the span `PreCompact` reports, because
  the marker runs from `covered_from` to the moment a later event claims it.
  The difference is the time the compaction itself takes.
- A resume keeps the `session_id`, so the state directory carries over and a
  resumed session goes on counting from its original start.
- A compaction appends a second `compact_boundary` record and leaves every
  earlier record in place, so the transcript holds each seam in order.

`dur` spans the pre-hook to the post-hook, so it covers the whole time the call
was outstanding: queuing and permission waits included. One `sed` measured 45ms
of execution against 3.7s of `dur`, the difference being a permission prompt.
Both numbers are emitted, `dur` and `exec`, so the wait is readable as its own
quantity.

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
for each turn, and it does not measure what `last_turn_dur` measures. Over one
session:

```
turn ends        chronicle   claude code   difference
12:13:59            13.5s        12.6s         0.8s
12:15:40            80.9s        49.5s        31.4s
12:21:06            53.4s        52.9s         0.5s
12:30:15           198.3s       198.1s         0.2s
12:36:25           311.7s       310.7s         1.0s
```

Four of the five agree inside a second. The turn that does not is the one
holding an `AskUserQuestion`, whose own stamp reads `dur="31.0s"`, which is the
gap. Claude Code discounts the time a turn spends blocked on the user;
`last_turn_dur` is wall clock from prompt to stop and counts it. Neither is
wrong, and the distinction is the one `dur` and `exec` already draw for a single
call, resolved the other way one level up.

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

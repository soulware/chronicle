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

`PostToolUse` stamps each tool result:

```
<time end="2026-08-26T09:43:42Z" dur="2.8s" exec="0.4s"/>
```

`PostToolUseFailure` stamps a call that failed, marking the outcome and showing
in the scrollback whatever `TS_TOOL_MIN` says, on the grounds that a failure is
always worth seeing:

```
<time end="2026-08-26T09:43:42Z" outcome="failed" dur="4m12s"/>
```

`Stop` closes the turn in the scrollback and records when the model stopped.
It takes `additionalContext`, but the meaning there is feedback the model is
expected to act on, which holds the turn open, so the time goes to state and
the next turn stamp reports it as `last_turn_dur` and `since_last_stop`.

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

`dur` is the whole time a call was outstanding and `exec` is the payload's own
execution time, so the difference between them is queuing and approval wait.
A large gap between the two is a presence signal rather than a slow command.

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
2026-08-26T10:39:30Z  ·  turn took 2m14s  ·  20m25s into session
```

Claude Code prefixes each of these with the event and tool, as
`PostToolUse:Bash says:`, and that prefix is its own rendering rather than part
of the message.

These carry the full date where the model's tool stamps carry a clock time, on
the grounds that a person scanning back through a week of scrollback wants the
date and the model has a dated turn stamp nearby already.

`TS_TOOL_MIN` sets the seconds a call must reach before it appears here. It
defaults to 0, so every call shows. Raising it to 5 limits the scrollback to
slow calls and leaves the model's stamps untouched.

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
- ~16 tokens per tool stamp, ~35 per turn stamp, about 8k over 500 calls.

## Correlation

`PreToolUse` records a start time under the call's `tool_use_id`; `PostToolUse`
reads it back and deletes it. Both events carry that id, so each call is matched
exactly and concurrent calls with identical input stay distinct. `PreToolUse`
emits nothing and therefore costs no context.

A `PostToolUse` with no matching start degrades to end-time-only, so installing
mid-session is safe. Malformed stdin exits 0 and still emits.

State lives in `~/.claude/hooks/state/<session_id>/`, overridable with
`TS_STATE_DIR`. Tool entries older than a day are swept on each turn.

## Install

```
./install.sh     # backs settings.json up to settings.json.pre-chronicle
./uninstall.sh
```

Then open `/hooks` once, or restart, so the config watcher reloads.

Re-running `install.sh` replaces chronicle's own entries rather than stacking a
second copy, and leaves every other hook alone.

`install.sh` symlinks the four entry points into `~/.claude/hooks/`, so editing
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

Covers every branch of the duration formatter, first turn, populated deltas, a
2.4s tool call, a post with no matching pre, two concurrent calls, malformed
stdin, and the latency of a pair.

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

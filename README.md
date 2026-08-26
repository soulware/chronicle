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
<time now="2026-08-26T09:44:31Z" session_elapsed="1h03m" since_last_turn="4m12s"/>
```

`PostToolUse` stamps each tool result:

```
<time end="09:43:42" dur="2.8s"/>
```

`Stop` closes the turn in the scrollback alone, since by then the model has
stopped and nothing more reaches it this turn.

Every stamp is UTC, so a transcript reads the same wherever it was recorded and
whatever the machine's clock was set to. The date lives on the turn stamp so the
tool stamps stay short. Deltas are
precomputed because subtracting ISO timestamps in-context is error-prone.

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
- A tool call that fails skips `PostToolUse`, so it carries no stamp and leaves
  its start entry behind for the daily sweep to collect. Unique ids keep that
  entry from ever matching a later call.
- Subagent tool calls fire the hooks and carry stamps, under the parent's
  `session_id`, so parent and subagent share one state directory. Keying on
  `tool_use_id` keeps their entries distinct.
- A background tool call is stamped when it is dispatched, so `dur` covers the
  handoff. A `sleep 12` returned `dur="0.0s"`. The same applies to an async
  `Agent` call, stamped at launch rather than at completion.
- The completion notification for a background task carries no time of its own.
  The following turn stamp is what bounds when it landed.

`dur` spans the pre-hook to the post-hook, so it covers the whole time the call
was outstanding: queuing and permission waits included. One `sed` measured 45ms
of execution against 3.7s of `dur`, the difference being a permission prompt.
Read it as latency paid, which is what the transcript position implies anyway.
The payload's `duration_ms` holds the execution time alone.

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

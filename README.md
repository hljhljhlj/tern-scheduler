# tern-scheduler

Timed prompts delivered to fixed omp agent blocks, as a [Tern](https://tern.so)
plugin. Each task in `tasks.json` has a prompt and an interval; when it is due,
the prompt is sent to that task's block — opened on first use, then reused.

Author: He lijun

## Install

```bash
tern plugin install github.com/hljhljhlj/tern-scheduler
# or, while developing:
tern plugin link ~/Project/tern-scheduler
tern plugin list --json     # status: ready, no problems
```

Reload after edits: `tern plugin reload scheduler`.

## Tasks

`tasks.json` holds one entry per task:

```json
[
  {
    "id": "pityplan",
    "title": "pityplan patrol",
    "every": "6h",
    "prompt": "prompts/pityplan.md",
    "cwd": "~/Project"
  }
]
```

- `every` — `30s`, `10m`, `6h`, `1d`.
- `prompt` — the file delivered into the block (relative to the plugin).
- `cwd` — working directory used when a block has to be opened.
- `place` — optional `{ "session": "name", "tab": "name" }`: when a block has to
  be opened, it is moved into that session (created if missing) and that tab
  (created and named if missing), instead of a new tab in whatever session
  happens to be current. Either key may be omitted; a fresh session's birth
  shell tab is closed once the block is in place.

## Commands

| Command | Effect |
| --- | --- |
| `Scheduler: tasks` | List every task with its next run and last outcome; Enter runs one now |
| `Scheduler: pin this block` | Give the focused agent block to a task |
| `Scheduler: status` | Toast the task count and the nearest run |

`Scheduler: tasks` is the way to see what is scheduled at any moment.

## Behaviour

- **Schedule** — each task keeps `next` in the plugin's `kv.json`, so reloads
  and Tern restarts do not lose the slot. A run between due and two hours late
  is delivered late; beyond that it is recorded as `missed` and the next slot
  is armed. Changing `every` re-arms the next slot at the new interval; state
  written before a task had an interval keeps its armed slot. Intervals below
  30 seconds are rejected, and an unreadable `tasks.json` is reported instead
  of silently running nothing.
- **At-most-once delivery** — a due slot is claimed in `kv.json` *before*
  anything is sent: the claim is saved, re-read, and only the window whose
  token survived delivers. A crash can lose a run, never duplicate one, and
  two windows cannot double-deliver the same slot.
- **Target block** — resolved by, in order: the pinned pane id (checked
  against a conversation fingerprint, so a block that switched to another
  conversation is reopened instead of prompted), a pane inside
  `place.session`/`place.tab` when configured, else — with no `place` — a pane
  matching the task id or title at the task's own `cwd`. Failing all that, a
  new agent block is opened with the prompt and moved to `place`; if the move
  fails the run records the reason and toasts instead of reporting a clean
  `opened`.
- **Delivery** — `cx.agents:ask(pane, prompt)`. Native omp receives one atomic
  TSP send; the prompt queues until the block can take it.
- **One owner** — a single window holds the schedule through a heartbeat;
  another window takes over once the heartbeat is 15 minutes stale. A failed
  tick (a transient store error, say) is logged and the schedule keeps
  ticking.
- **History** — the last ten runs per task (`opened`, `sent`, `manual`,
  `failed`, `missed`) live in `kv.json` and show up in `Scheduler: tasks`.

The window half schedules because Tern's durable-task `check` runs in Carly's
VM, where `tern.plugin.dir` and `tern.kv` resolve to Carly's directory.

## Test mode

`touch test-once` next to the manifest switches every interval to one minute
and reads `<prompt>.test.md` instead of the real prompt:

```bash
tern plugin reload scheduler
```

Remove `test-once` and reload to restore the configured intervals.

## License

MIT — see [LICENSE](LICENSE).

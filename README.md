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
  is armed.
- **Target block** — resolved by, in order: the pinned pane id, a pane matching
  the task id or title, else a new agent block opened with the prompt.
- **Delivery** — `cx.agents:ask(pane, prompt)`. Native omp receives one atomic
  TSP send; the prompt queues until the block can take it.
- **One owner** — a single window holds the schedule through a heartbeat;
  another window takes over once the heartbeat is 15 minutes stale. A due slot
  is claimed before delivery, so two windows cannot double-run a task.
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

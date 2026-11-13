# tern-patrol-plugin

A Tern plugin that delivers a prompt into one fixed omp block on a schedule.

Tern owns the clock: the window half ticks every 30 seconds, keeps the next run
in `tern.kv`, and sends `prompt.md` to a single agent block — creating that block
on first use, then reusing it. Nothing is appended to an unrelated conversation.

## Files

| File | Purpose |
| --- | --- |
| `plugin.toml` | Tern plugin manifest (`schema = 1`, window half only) |
| `window.luau` | Schedule, delivery, and the `Patrol:` palette commands |
| `prompt.md` | The text delivered into the block |

## Behaviour

- **Schedule** — every 6 hours, kept as `state.next` in the plugin's `kv.json`,
  so it survives plugin reloads and Tern restarts. A run between due and two
  hours late is delivered late; beyond that it is recorded as `missed` and the
  next slot is armed.
- **Target block** — resolved by, in order: the pinned pane id, a pane titled
  `patrol`, else a new agent block opened with the prompt (`cwd ~/Project`,
  new tab).
- **Delivery** — `cx.agents:ask(pane, prompt)`. Native omp receives one atomic
  TSP send; the prompt queues until the block can take it.
- **History** — the last ten runs (`opened`, `sent`, `manual`, `failed`,
  `missed`) live in `kv.json` and show up in `Patrol: status`.

## Why the window half schedules

Tern's durable task API (`tern.carly.schedule`) runs its `check` inside Carly's
VM, where `tern.plugin.dir` and `tern.kv` resolve to Carly's directory and store.
The prompt and the pinned pane therefore cannot be reached from a check. The
window half keeps the clock itself: a 30 s timer, `state.next` in the plugin's
own `kv.json`, and the same `agents:ask` path the commands use.

## Commands

| Command | Effect |
| --- | --- |
| `Patrol: run now` | Deliver `prompt.md` immediately, keeping the schedule |
| `Patrol: pin this block` | Use the focused agent block as the target |
| `Patrol: status` | Toast the next run and the last outcome |

## Install

```bash
tern plugin link ~/Project/tern-patrol-plugin
tern plugin list --json     # status: ready, no problems
```

Reload after edits:

```bash
tern plugin reload patrol
```

## Test mode

`touch test-once` next to the manifest switches the interval to one minute and
uses `test-prompt.md` instead of the real prompt:

```bash
tern plugin reload patrol
```

Remove `test-once` and reload to restore the six-hour schedule.

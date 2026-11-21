# Agent tools

Back to the [docs index](README.md).

The bridge serves 40 MCP tools. This page lists all of them.

- "In app" means the tool runs inside the running app. It needs "Allow agent control" on. See [agent setup](agent-setup.md).
- "Bridge" means the bridge answers itself.
- Drafts are never visible to any tool.
- A widget is named with a `handle` (from `get_screen` or `find_widgets`, for example `h12`) or with a `target` query. A `target` is found again on each call, so it is never stale. A target has `file`, `line`, `type`, `text`, `key` and `index`.

## Notes

| Tool | Where | What it does | Key inputs |
| --- | --- | --- | --- |
| `list_notes` | Bridge | Lists the notes you sent. Default: open ones. At most 50. | `status` (`open`, `all`, or one status), `detail` |
| `get_note` | Bridge | One note. At standard and full detail it attaches the screenshot (at most 800 px wide). | `id`, `detail` (`compact`, `standard`, `full`) |
| `update_note` | Bridge | Sets a status and adds a message. `resolved` and `rejected` move the note to `.pinpoint/resolved/`. Warns while `PinPoint.probe` lines remain in `lib/`. | `id`, `status` (`inProgress`, `fixed`, `resolved`, `rejected`), `message`, `changes` (`[{summary, files}]`) |
| `get_note_diff` | Bridge | The patch of one round of a note, for all changes or one. A patch over 40 KB gives the file list only. Without git, it lists the files the agent named. | `id`, `round`, `change` |
| `verify_note` | In app | Runs the note's checks under the environment and route it was filed in. Takes an after screenshot. Returns pass or fail for each check. | `id` |

## See and find

| Tool | Where | What it does | Key inputs |
| --- | --- | --- | --- |
| `get_screen` | In app | Route, URL, viewport, what-if settings, and the local widgets on screen, each with a handle. | `limit`, `max_chars` |
| `find_widgets` | In app | Finds live widgets by source line, type, text or key. | `file`, `line`, `type`, `text`, `key`, `limit` |
| `inspect` | In app | The note payload for a widget: source, layout, enclosing widgets. | `handle` or `target`, `detail` |
| `flash` | In app | Outlines a widget for 1.5 s, so you see which one the agent means. | `handle` or `target` |
| `screenshot` | In app | The whole app, or one widget outlined, downscaled. | `handle` or `target`, `max_width` (default 800) |
| `get_state` | In app | The widget's nearest `State` properties, scroll position, focus, text field value, inherited widgets above it, and state adapters. | `handle` or `target`, `limit` |

## Operate the app

| Tool | Where | What it does | Key inputs |
| --- | --- | --- | --- |
| `tap` | In app | A synthetic tap at the widget's center. Refused with "obscured by X" when something is on top. | `handle` or `target` |
| `long_press` | In app | A synthetic long press. | `handle` or `target` |
| `enter_text` | In app | Types into a text field. Input formatters and `onChanged` run. | `handle` or `target`, `text` |
| `scroll` | In app | Moves the nearest list by `dx` or `dy` logical pixels. | `handle` or `target`, `dx`, `dy` |
| `scroll_to` | In app | Brings a widget into view. For a lazy list, scrolls until the item is built. | `handle`, or a query; `within`, `max_steps` |
| `navigate` | In app | Pushes a route by path (named routes and `Router` apps). | `path` |
| `back` | In app | Pops the current route. | none |
| `wait_idle` | In app | Returns when no frame is scheduled and no animation runs, or with `idle: false` at the timeout. | `timeout_ms` (default 2000) |
| `run_steps` | In app | Runs several tools in order, in one call. Stops at the first failure. At most 20 steps. Not `inspect`, `screenshot`, `verify_note` or `stress_matrix`. | `steps` (`[{tool, ...args}]`) |
| `hot_reload` | Bridge | Hot reloads the app after a code edit and says whether the new code runs. Works with agent control off. | `vm_service` (address, once per run) |

## What-if and checks

| Tool | Where | What it does | Key inputs |
| --- | --- | --- | --- |
| `set_environment` | In app | Sets what-if switches. `null` clears one. | `viewport`, `textScale`, `boldText`, `textDirection`, `brightness`, `platform`, `timeDilation`, `keyboardHeight`, `themeVariant`, `seedColor` |
| `reset_environment` | In app | Removes every what-if override. | none |
| `scan` | In app | Runs the detectors on the current screen. | `kinds` (`overflow`, `truncated_text`, `oversized_image`, `accessibility`), `limit` |
| `stress_matrix` | In app | Varies widths, text scales, directions and brightness. Scans each run. Files a draft note for each distinct problem. At most 48 runs. | `widths`, `textScales`, `directions`, `brightness`, `full`, `kinds` |

## What happened (flight recorder)

| Tool | Where | What it does | Key inputs |
| --- | --- | --- | --- |
| `get_trace` | In app (`run`: bridge) | One compact line for each event, with repeats folded. With `run`, reads a stored replay run. | `since`, `until`, `kinds`, `widget`, `cause`, `limit`, `detail`, `run` |
| `trace_detail` | In app | Starts or stops level 3 recording (rebuilds and watches). | `on` |
| `watch` | In app | Follows a widget's `State` and the local `State`s above it. At most 8 watches. | `handle` or `target`, `ancestors` |
| `unwatch` | In app | Stops a watch by id, or all. | `id` |
| `mark` | In app | Records a mark with an optional sentence and a thumbnail. | `text` |
| `why` | In app | Walks back from one event to the tap, key or message that started it. Needs `PinPoint.run`. | `seq` |
| `caused_by` | In app | What a widget's subtree started: requests, rebuilds, state changes, timers, errors. | `handle` or `target`, `since` |
| `state_flow` | In app | The state lens as text: why a value changed. First call opens a window of up to 30 s. Call again after acting. | `handle` or `target`, `seconds`, `rearm`, `hover`, `controllers` |
| `list_probes` | Bridge | The `PinPoint.probe(` lines left under `lib/`. | none |

## Tapes

| Tool | Where | What it does | Key inputs |
| --- | --- | --- | --- |
| `list_tapes` | Bridge | The tapes on the bridge, newest first. No body is shown. | none |
| `get_tape` | Bridge | One tape in short: summary, start page, marks, route order, inputs, requests. No body. | `id` |
| `save_tape` | In app | Saves the inputs and network answers of the run as a tape. | `since` (`start`, `mark`, `mark:N`, seconds), `name` |
| `replay` | In app | Plays a tape's inputs into the app while requests are answered from the tape. | `tape`, `until`, `speed`, `unmatched`, `latency` |
| `resume_replay` | In app | Goes on after a hold set by `until`. | none |
| `stop_replay` | In app | Ends the replay and gives input and network back. | none |

Details: [flight recorder](flight-recorder.md), [causes and network](causes-and-network.md), [tapes](tapes.md), [state lens](usage/state-lens.md), [undo](undo.md).

## Timeouts

The bridge waits up to 20 s for most in-app tools. `wait_idle` waits its timeout plus 5 s. `verify_note`, `scroll_to` and `save_tape` wait 60 s. `stress_matrix`, `replay` and `resume_replay` wait 240 s. `run_steps` waits the sum of its steps, at most 240 s.

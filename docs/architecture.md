# Architecture

Back to the [docs index](README.md).

Pinpoint has three processes.

```text
app (Flutter web)  --HTTP-->  bridge (plain Dart, port 4747)  <--MCP /mcp--  coding agent
```

- **The app** runs the overlay: picking, panels, pins, the recorder and the tape player. Notes leave it through sinks (`HttpSink.bridge()`, `ClipboardSink()`).
- **The bridge** (`dart run pinpoint:bridge`) stores notes, tapes and runs in `.pinpoint/`. It serves MCP tools to the agent. It queues commands from the agent. The app picks them up by long poll and runs them.
- **The agent** is your coding agent. It connects to the bridge over MCP.

`dart run pinpoint:setup` writes the agent instructions and the MCP config.

## The path of one note

1. You pick a widget in the overlay.
2. The search code finds which widget it is, and which source line made it.
3. The capture code builds the note: comment, target, enclosing widgets, layout, what-if settings, findings, and the screenshot.
4. The HTTP sink posts the note to the bridge.
5. The bridge writes it into `.pinpoint/open/`.
6. The agent reads it through MCP (`list_notes`, `get_note`) and changes the code.
7. The agent sets a status with `update_note`.
8. The app polls the bridge, sees the change, and updates the pin.

## Folder map

| Folder (`lib/src/`) | What it holds |
| --- | --- |
| `core/` | The wrapper widget, the config, the controller (modes: idle, picking, commenting, sending), the keymap, the list of notes shown as pins, and note sync with the bridge. |
| `search/` | Finds the widget under the pointer, and its file and line. |
| `info/` | The data for the INFO tab. One extractor for each render type (padding, flex, decoration...). The TWEAK tab uses them too. |
| `capture/` | Builds the note: context, screenshot crop, subtree outline. |
| `model/` | Plain data shared with the bridge: the note, source locations, trace events, tapes. |
| `sink/` | Where a note goes: the HTTP sink, the clipboard sink, the Markdown text, the bridge client. |
| `overlay/` | Everything drawn over the app: highlight, rulers, panels, pins, rail, Timeline, Findings, What-if, Tweak, toasts. |
| `theme/` | Colors, palettes (Redline, Cobalt, Ember), controls, motion. |
| `detect/` | Automatic findings: overflow, truncation, images, accessibility, rebuild heat, errors, debug paint. |
| `env/` | Device presets and the What-if overrides. |
| `tweak/` | Live edits of render properties and their reset. |
| `trace/` | The flight recorder: the event log, sources (pointer, key, text, route, frame, network, message), causes, probes, watches, redaction, the state story. |
| `state/` | The state lens: build stacks, dependencies, listeners, names. |
| `tape/` | Record and replay of a run. |
| `agent/` | The app side of agent control: the command channel, the commands (tap, scroll, screenshot, state dump), checks, the stress matrix. |
| `bridge/` | The bridge side (plain Dart with `dart:io`): HTTP routes, MCP server and tools, note, tape and run stores, command queue, hot reload, undo checkpoints, setup. |

Other folders: `bin/` has the two commands (`bridge.dart`, `setup.dart`). `assets/` has the Roboto Mono font and the images of the "under construction" cover. `example/` is the test app. `test/` mirrors `lib/src/` folder by folder.

## Rules that shape the design

- Files that `bin/` imports are plain Dart. There is no `dart:ui` and no `package:flutter` in `bridge/` and `model/`. The app never imports `dart:io`.
- Web-only code uses a conditional import: an interface file, a `_web` file and a `_stub` file.
- While an agent works, Pinpoint does not animate in Flutter. Agent commands wait until the app stops drawing, because Pinpoint's own frames would look like app motion. The "under construction" cover is HTML and CSS in the page.
- Colors and type come from the theme. Every surface works in all palettes.
- Agent-facing text is pinned by tests. Text and tests change together.

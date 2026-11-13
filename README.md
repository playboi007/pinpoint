# Pinpoint

A debug-only Flutter package. Click any widget in a running app, write a comment, and give a coding agent the widget's source location, layout context and a screenshot.

Web is the first target.

> **Status: Milestone 12 (Session 12).** The wrapper, the inspect mode (Alt+Shift+C or the launcher button), Esc and freeze (P while picking) work. Hover outlines the widget under the pointer, and a click selects the nearest widget written in your own project (a `Text`, not the `RichText` it builds), with `file:line` in the label. The click opens a panel next to the widget with a clickable breadcrumb and three tabs. Comment: choose Bug, Improve or Question, type the comment, then Send (or Ctrl/Cmd+Enter) to every sink in `PinPointConfig.sinks`, with a toast per sink, or Copy as Markdown. The comment is kept until a send succeeds. Info: the widget's layout data; there, Arrow Up or `[` moves to the next local ancestor, Arrow Down or `]` moves back, and Alt plus an arrow steps through framework widgets too. Rulers measure to the nearest local ancestor (hold Alt and hover another widget to measure the gap), and the mouse wheel still scrolls the app. The note is an `Annotation` (schema 7, under 8 KB as JSON). With "Include screenshot" ticked (the default), Send adds a PNG crop of the widget with a red outline, at most 1600 px wide (`PinPointConfig.maxScreenshotWidth`). `HttpSink` posts each note to the local bridge (`dart run pinpoint:bridge`), which writes it into `.pinpoint/open/` as Markdown, JSON and PNG; `ClipboardSink` copies the Markdown. When picking starts and the bridge does not answer, a "bridge offline" badge shows. Each note stays on screen as a numbered pin on its widget, through scroll, resize and hot reload; Save draft keeps a note as a draft pin that no agent sees until you send it. A click on a pin opens its note: Send, Send all, Delete, and Accept or Reopen once the agent is done. A pin clicked with Pinpoint off keeps Pinpoint off: the app takes every click outside the panel, so you can try the agent's change before you accept it, and closing the note goes back to off. The agent reads and resolves notes through MCP tools on the bridge, and a resolved pin shows a tick and fades within 3 seconds. The What-if button (bottom-left while picking) changes what the app inherits without touching app code: viewport size (presets, rotate, free width and height), text scale, bold text, safe areas, a fake keyboard, RTL, the app's light or dark theme (or `PinPointConfig.themeVariants`), a Material 3 seed color, the platform and slow motion. While any switch is on, the bar stays and names it, with a one-click reset, and every note records the overrides in `environment`. The Findings button (bottom-right while picking) lists problems Pinpoint finds by itself: Scan this screen finds flex overflow (measured, so it is found again after every what-if change), text cut at its line limit and images decoded at more than twice the pixels they show; errors (with the widget's file and line) and oversized decoration images are captured as they happen; Check accessibility lists actions without a label, tap targets under 48x48 and text under the WCAG contrast ratio; rebuild heat (off by default) lists and tints the ten widgets that rebuilt most in the last 5 seconds; chips turn Flutter's debug paint flags on and off. Hovering a finding outlines its widget, and Send note turns it into a note with the matching check for Milestone 12 and sends it, so the agent sees it at once (if a sink fails, it stays a draft and the row offers Send draft). The example's Bug zoo screen has one planted problem of each kind. Tweak: edit the selected widget's padding, size, flex, alignment, stack, opacity, clip radius, aspect ratio, wrap gaps, image fit, text style and decoration in the running app (number steppers with steps of 1, 4 and 8, arrow keys, hex colors, menus, four linked inset fields). A `Container` shows its padding, size and decoration together; `Container(color:)` is read-only. Each tweak holds through rebuilds (at most one frame at the old value), stops with a warning when the widget animates, and can be reset one by one or all at once. Tweaked widgets get a dotted outline and an "N tweaks active" chip shows in every mode. Every note lists the active tweaks as from-and-to pairs with the widget that made each value and the nearest widget in your source, and with a screenshot the image shows the crop before and after the tweaks. Agent drive and verify: with "Allow agent control" turned on (the round button above the launcher; off at every start, a chip shows while it is on, Esc turns it off), the coding agent operates the running app through MCP tools on the bridge: `get_screen`, `find_widgets` by source line, type, text or key, `inspect`, `flash`, `tap` and `long_press` (refused with "obscured by X" when something covers the widget), `enter_text`, `scroll`, `scroll_to` (it scrolls a lazy list until the item is built), `navigate` and `back` (named routes and `Router` apps), `wait_idle`, `set_environment`, `scan`, `screenshot` and `get_state` (with `PinPointConfig.stateAdapters` for Bloc, Riverpod or Provider values). A note can carry checks (Add check in the comment form, or from a finding); `verify_note` runs them under the note's environment and route, with an after screenshot, and the pin shows pass or fail for you to accept. `stress_matrix` tries widths, text scales, RTL and dark, and files one draft note per distinct problem. `hot_reload` asks `flutter run` for a hot reload through the app's debug service (start the app with `flutter run --vmservice-out-file=.pinpoint/vm-service.txt`, or give the agent the address once) and says whether the new code runs: on web a reload that did not compile is reported as one that did not apply. It works with agent control off. The example has named routes and a `Router` app (`lib/router_app.dart`). See `PLAN.md` for the build order.

```dart
MaterialApp(
  builder: (context, child) => PinPointWrapper(
    config: PinPointConfig(sinks: [HttpSink.bridge(), const ClipboardSink()]),
    child: child,
  ),
  home: const HomeScreen(),
)
```

## Notes into the project: the bridge

Run the bridge in the project folder, next to `flutter run`:

```bash
dart run pinpoint:bridge            # http://127.0.0.1:4747, notes in .pinpoint/
dart run pinpoint:bridge --help     # --port, --dir, --lan, --allow-origin
```

Each Send writes `.pinpoint/open/<id>.md`, `<id>.json` (no image data) and `<id>.png`. Drafts go to `.pinpoint/drafts/` (no `.md`, so no agent finds them), and closed notes to `.pinpoint/resolved/`. The app loads its pins from the bridge at start, and asks it every 2 seconds what changed, only while the overlay is active. The bridge address comes from `PinPointConfig.bridgeUrl`, else from the first `HttpSink.bridge()` in `sinks`. The bridge listens on this machine only and accepts notes only from pages served from this machine (`localhost`, `127.0.0.1`); `--lan` and `--allow-origin <url>` widen that for testing on a phone. It writes `.pinpoint/.gitignore` (`*`), so the notes are never committed; add `.pinpoint/` to your own `.gitignore` too if you like.

If port 4747 is taken, start the bridge with `--port <n>` and give the app the same port: `HttpSink.bridge(port: n)`, or `--dart-define=PINPOINT_BRIDGE_PORT=n`.

## Agent hand-off

```bash
dart run pinpoint:setup             # writes .pinpoint/agent-instructions.md and mcp.json, prints the rest
dart run pinpoint:setup --write     # also edits CLAUDE.md (or AGENTS.md) and .mcp.json
claude mcp add --transport http pinpoint http://127.0.0.1:4747/mcp   # or this, for Claude Code
```

The bridge serves MCP at `/mcp` (HTTP, on the bridge's port) with three tools: `list_notes(status, detail)`, `get_note(id, detail)` and `update_note(id, status, message)`. `detail` is `compact` (comment, source, rect; under 600 characters), `standard` (the default: adds layout, enclosing widgets and the screenshot, at most 800 px wide) or `full`. Drafts are invisible to every tool.

The section setup adds to your agent instruction file (the bridge prints it at start until `CLAUDE.md` or `AGENTS.md` has it):

```text
## Pinpoint notes
UI feedback from the running app lives in .pinpoint/open/*.md.
When asked to "work the pinpoint notes": for each note, open the Source
file at the given line, read the comment, view the PNG named on the
Screenshot line, make the change, run flutter analyze, then move the
note's files (<id>.md, <id>.json and <id>.png) to .pinpoint/resolved/ and
append one line describing the fix to the .md.
With the pinpoint MCP server connected, use its tools instead: list_notes,
get_note (it attaches the screenshot), then update_note(id, "resolved",
message) with one line saying what you changed. The pin in the app
updates. Leave .pinpoint/drafts/ alone: drafts are not sent yet.
```

## Flight recorder (v2, Milestone 13)

From the moment the wrapper starts, Pinpoint keeps a bounded record of what the app did: taps (with the widget under the pointer and its anchor), keys, text field values (masked for `obscureText`), routes, errors, findings, frames, `PinPoint.probe` lines and marks. It holds at most 20,000 events and about 4 MB (`TraceConfig.maxEvents`, `maxBytes`); when a limit drops old events, every answer built on the record says `partial`. Rebuilds per widget and watched state are level 3: they run only while the Timeline is open, a watch is set, or the agent asked with `trace_detail`, because the rebuild hook is the slot DevTools "track rebuilds" needs.

- The Timeline button on the rail lists the events by frame, with the recorder's own time per frame, filter chips per kind, and a click that flashes the widget. M while picking, or the Timeline's Mark button, marks the moment; a mark can be named.
- A note carries `trace`: what happened in its widget's subtree in the 10 seconds before you started picking, under "What happened" in the Markdown. When rebuilds were not recorded, its first line says so.
- Agent tools: `get_trace` (compact lines, repeats folded with ×n), `trace_detail`, `watch` and `unwatch` (only values a `State` lists in `debugFillProperties`), `mark`, and on the bridge `list_probes`. `update_note` warns while `PinPoint.probe` lines remain in `lib/`.

```dart
PinPoint.probe('existing.ensureLoaded', {'type': type, 'loaded': _loadedForType});
```

The recorder changes timing a little. If a bug goes away with Pinpoint on, turn the recorder off first: `PinPointConfig(trace: TraceConfig(enabled: false))`. With Pinpoint off, nothing is recorded and `PinPoint.probe` returns at once.

## Causes and network (v2, Milestone 14)

Wrap `runApp` in `PinPoint.run`, and every event names the entry that started it: a tap, a frame, a key, a `window` message, or an agent command. `get_trace` shows it as `c37` on each line.

```dart
void main() => PinPoint.run(() => runApp(const MyApp()));
```

- **Call it first in `main`.** Put `WidgetsFlutterBinding.ensureInitialized()` inside it too. Flutter prints "Zone mismatch" when the binding is set up in one zone and `runApp` runs in another. When the binding already exists, `PinPoint.run` runs the app with no zone, records no causes, and prints one hint.
- **What it costs.** One child zone per entry from the engine (a pointer packet, a frame), for the whole run: the zone cannot start later. `PinPoint.run(..., trace: const TraceConfig(causes: false))` turns it off; pass the same `TraceConfig` you give `PinPointConfig.trace`.
- **Errors nobody caught** (an `async` handler nobody awaits) become `error` events with their cause, and still reach the app's own handler. On web they otherwise show only in the browser console.
- **Requests.** On web, `fetch` (`package:http`) and `XMLHttpRequest` (Dio) give `net.request`, then `net.response` or `net.error`, with the cause of the call. The app gets the browser's own promise and response. Bodies are read from a clone to hash them, and kept up to 256 KB each for tapes; large, binary and event-stream answers are never cloned. `TraceConfig(bodies: false)` reads no body.
- **Secrets.** Header values and URL parameters named in `TraceConfig.redact` are masked before an event exists. The defaults are `authorization`, `cookie`, `set-cookie`, and any name with `token`, `key` or `secret` in it. Traffic to the bridge is never recorded.
- **Agent tools.** `why({seq})` walks back from one event to the tap or frame that started it, and through the frames that led there; `loop: true` when each frame repeats the same work. `caused_by({target})` counts what a widget's subtree started. The Timeline groups events by cause, and the Info tab says what the picked widget caused in the last 5 seconds.

Limits: a post-frame callback runs with the cause of the frame that calls it. A frame is linked to every cause that ran since the frame before it, and `why` picks the one that set state, answered a request or took input. A timer or a stream keeps the cause of the moment it was made; `why` shows the age of an old cause.

## Tapes (v2, Milestone 15)

A tape is the inputs and network answers of a run, saved so the run can happen again. The recorder keeps them from app start, apart from the ring buffer, with up to 20 MB of answer bodies.

- **Attach what happened.** The comment form has this switch, with the size next to it. A note then carries a tape: a **full** tape from app start when nothing was dropped, else a **segment** from the last mark. Its pin shows a Replay button; the agent's header says "has tape". The tape is on the bridge in `.pinpoint/tapes/`, which `setup` git-ignores, and no tool answer shows a body.
- **Replay.** `replay({tape})` plays the inputs into the app while `fetch` and XHR are answered from the tape: no request reaches a server with `unmatched: "fail"` (the default). A full tape reloads the page first, so in-memory state starts from a known value; `PinPoint.run` then loads the tape before `runApp`. Inputs go by logical order: each waits for the answers that came before it and for its widget, found by anchor, so a button that moved is still hit. Real taps are blocked and a banner shows the step; Esc stops and puts everything back.
- **What it answers.** `state` (done, held, stopped, diverged), `first_difference` (route order, request keys, anchors), and the requests the tape had no answer for. `until: "mark"` holds at the user's mark: pick, `get_state` and `screenshot` work there; `resume_replay` goes on. Each run streams to the bridge, so `get_trace({run})` reads it after the page reloaded.
- **Config.** `TraceConfig(storage: true)` copies `localStorage` and `sessionStorage` at app start and puts them back on replay (off by default: they hold session tokens). `TraceConfig(matchIgnore: ['ts', 'requestId'])` leaves fields that change on every run out of a request's key. `bodies: false` gives segments only, whose requests reach the server.

Limits: replay does not control the clock or random numbers; a token that expired since the recording shows as the first difference. Key events alone are not replayed (the text they made is). WebSockets reach the server during a replay.

## What it will do

- Inspect mode: hover to outline a widget, click to select it.
- Source refinement: select the nearest widget written in your own project, with `file:line`.
- Comments and a payload an agent can act on without seeing the app.
- Sinks: clipboard, and a local bridge that writes notes into `.pinpoint/`.
- Agent hand-off: an instruction section, so the agent works the notes in `.pinpoint/open/`.
- Pins and drafts, and MCP tools on the bridge, so a resolved note clears its pin in the running app.
- What-if switches: viewport, text scale, safe areas, keyboard, direction, theme, platform and slow motion.
- Later: automatic problem detection, live tweak, and agent drive and verify.

What the what-if switches cannot do:

- Code that reads `View.of(context).physicalSize` or `PlatformDispatcher` directly sees the real window, not the viewport. That is a finding about the app: read `MediaQuery` instead.
- The device pixel ratio cannot be faked. A 390-wide viewport on a 1x screen renders at 1x.
- The color scheme switch is Material 3 only. In a Material 2 theme, `copyWith(colorScheme:)` does not re-derive the component themes, so it is off there.
- The platform switch rebuilds the whole app, like hot reload, and clears the selection. Outside web (desktop, `flutter test`), a switch between iOS or macOS and another platform also mounts the widgets above the Navigator again, because Flutter adds a `Shortcuts` layer only on Apple platforms. The routes keep their state; pass your own `PinPointController` to keep the switches too.

Source locations come from Flutter's `--track-widget-creation`, which is on only in debug builds. The package defaults to `enabled: kDebugMode`.

## Repository layout

```text
PLAN.md             # the implementation plan (read this first)
docs/api-notes.md   # Flutter SDK API checks; overrides PLAN.md where they differ
lib/                # package source (empty files are later milestones)
bin/                # bridge.dart (Milestones 7 and 8), setup.dart (Milestone 8)
example/            # manual test bed: six screens
test/               # package tests
```

## Development

Flutter 3.47.5 (Dart 3.13.4) is the version the notes were checked against.

```bash
flutter pub get
flutter analyze

# the Session 0 spike: reads a real creation location from a Text widget
flutter test test/source/spike_location_test.dart

# Milestone 1: wrapper, modes, keys, launcher, freeze
flutter test test/core

# Milestone 2: picking, highlight, info panel, rulers, scroll passthrough
flutter test test/search test/info test/overlay

# Milestone 3: source locations, local-project selection, chain navigation
flutter test test/source
cd example && flutter test test/source_selection_test.dart

# Milestone 4: payload model, context capture, size budget, example sweep
flutter test test/model test/capture
cd example && flutter test test/collect_sweep_test.dart

# Milestone 5: panel placement, comment form, keys and focus, send flow
flutter test test/overlay/place_panel_test.dart test/overlay/comment_form_test.dart \
  test/overlay/comment_keys_test.dart test/overlay/comment_send_test.dart test/sink

# Milestone 6: crop math, capture and outline, payload, width cap
flutter test test/capture/screenshot_plan_test.dart test/capture/screenshot_capture_test.dart \
  test/capture/screenshot_context_test.dart test/model/screenshot_info_test.dart \
  test/overlay/screenshot_send_test.dart

# Milestone 7: Markdown goldens, bridge, HTTP and clipboard sinks, offline badge
flutter test test/sink test/bridge test/overlay/bridge_badge_test.dart

# Milestone 8: SourceIndex, pins and drafts, bridge store and feed, polling, MCP, setup
flutter test test/search/source_index_test.dart test/overlay/pins_test.dart \
  test/overlay/note_sync_test.dart test/core/note_book_test.dart test/model/note_status_test.dart \
  test/bridge test/sink/bridge_client_test.dart

# Milestone 9: viewport frame, environment host, globals, note environment, panel
flutter test test/env test/core/hook_registry_test.dart
(cd example && flutter test test/environment_probe_test.dart)

# Milestone 10: detectors, error capture, findings list, audit, heat, debug paint
flutter test test/detect test/core/hook_registry_test.dart test/model/annotation_test.dart \
  test/sink/markdown_formatter_test.dart
(cd example && flutter test test/bug_zoo_test.dart)

# Milestone 11: tweak extractors, Tweak tab, session (reapply, reset), note diff
flutter test test/tweak test/info test/model/annotation_test.dart test/sink/markdown_formatter_test.dart

# v2 Milestone 13: recorder, sources, probes, watches, marks, Timeline, trace in notes
flutter test test/trace test/bridge/list_probes_test.dart test/detect/rebuild_tracker_test.dart

# after a deliberate change to the note's shape: rewrite the golden, review the diff
flutter test --update-goldens test/capture/target_test.dart
flutter test --update-goldens test/sink/markdown_formatter_test.dart

# the bridge by hand: preflight, then a real note
dart run pinpoint:bridge
curl -i -X OPTIONS http://localhost:4747/annotations -H 'Origin: http://localhost:5000' \
  -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type'
curl -i -X POST http://localhost:4747/annotations -H 'content-type: application/json' \
  --data @test/fixtures/note.json
# and an MCP tool call, as an agent makes it
curl -s -X POST http://localhost:4747/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}'

# the example app; PINPOINT_ROOT makes paths project-relative. Start the bridge
# in example/ first (dart run pinpoint:bridge), or Send reports it offline.
cd example && flutter run -d chrome --dart-define=PINPOINT_ROOT=$(pwd)

# the same, printing p50 and p95 pick time after every 200 hover picks
cd example && flutter run -d chrome --dart-define=PINPOINT_PICK_TIMINGS=true

# the same, printing the time and size of each screenshot (over 300 ms prints anyway)
cd example && flutter run -d chrome --dart-define=PINPOINT_CAPTURE_TIMINGS=true

# screenshots under the WebAssembly build
cd example && flutter run -d chrome --wasm
```

## Example screens

Counter and spinner, long list, dialog and bottom sheet, nested navigator, `CustomPaint`, form with text fields and a custom `SaveBar` widget, `HtmlElementView` (web only), and a What-if probe that prints what the app inherits. The bug zoo has one planted problem of each kind, and the planted loop screen schedules a load from `build`: try `why` on its fifth request.

## License

Not chosen yet. The `LICENSE` file is the Flutter template placeholder.

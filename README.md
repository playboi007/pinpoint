# Pinpoint

A debug-only Flutter package. Click any widget in a running app, write a comment, and give a coding agent the widget's source location, layout context and a screenshot.

Web is the first target.

> **Status: Milestone 12 (Session 12).** The wrapper, the inspect mode (Alt+Shift+C or the launcher button), Esc and freeze (P while picking) work. Hover outlines the widget under the pointer, and a click selects the nearest widget written in your own project (a `Text`, not the `RichText` it builds), with `file:line` in the label. The click opens a panel next to the widget with a clickable breadcrumb and three tabs. Comment: choose Bug, Improve or Question, type the comment, then Send (or Ctrl/Cmd+Enter) to every sink in `PinPointConfig.sinks`, with a toast per sink, or Copy as Markdown. The comment is kept until a send succeeds. Info: the widget's layout data; there, Arrow Up or `[` moves to the next local ancestor, Arrow Down or `]` moves back, and Alt plus an arrow steps through framework widgets too. Rulers measure to the nearest local ancestor (hold Alt and hover another widget to measure the gap), and the mouse wheel still scrolls the app. The note is an `Annotation` (schema 6, under 8 KB as JSON). With "Include screenshot" ticked (the default), Send adds a PNG crop of the widget with a red outline, at most 1600 px wide (`PinPointConfig.maxScreenshotWidth`). `HttpSink` posts each note to the local bridge (`dart run pinpoint:bridge`), which writes it into `.pinpoint/open/` as Markdown, JSON and PNG; `ClipboardSink` copies the Markdown. When picking starts and the bridge does not answer, a "bridge offline" badge shows. Each note stays on screen as a numbered pin on its widget, through scroll, resize and hot reload; Save draft keeps a note as a draft pin that no agent sees until you send it. A click on a pin opens its note: Send, Send all, Delete, and Accept or Reopen once the agent is done. The agent reads and resolves notes through MCP tools on the bridge, and a resolved pin shows a tick and fades within 3 seconds. The What-if button (bottom-left while picking) changes what the app inherits without touching app code: viewport size (presets, rotate, free width and height), text scale, bold text, safe areas, a fake keyboard, RTL, the app's light or dark theme (or `PinPointConfig.themeVariants`), a Material 3 seed color, the platform and slow motion. While any switch is on, the bar stays and names it, with a one-click reset, and every note records the overrides in `environment`. The Findings button (bottom-right while picking) lists problems Pinpoint finds by itself: Scan this screen finds flex overflow (measured, so it is found again after every what-if change), text cut at its line limit and images decoded at more than twice the pixels they show; errors (with the widget's file and line) and oversized decoration images are captured as they happen; Check accessibility lists actions without a label, tap targets under 48x48 and text under the WCAG contrast ratio; rebuild heat (off by default) lists and tints the ten widgets that rebuilt most in the last 5 seconds; chips turn Flutter's debug paint flags on and off. Hovering a finding outlines its widget, and Make note turns it into a draft note with the matching check for Milestone 12. The example's Bug zoo screen has one planted problem of each kind. Tweak: edit the selected widget's padding, size, flex, alignment, stack, opacity, clip radius, aspect ratio, wrap gaps, image fit, text style and decoration in the running app (number steppers with steps of 1, 4 and 8, arrow keys, hex colors, menus, four linked inset fields). A `Container` shows its padding, size and decoration together; `Container(color:)` is read-only. Each tweak holds through rebuilds (at most one frame at the old value), stops with a warning when the widget animates, and can be reset one by one or all at once. Tweaked widgets get a dotted outline and an "N tweaks active" chip shows in every mode. Every note lists the active tweaks as from-and-to pairs with the widget that made each value and the nearest widget in your source, and with a screenshot the image shows the crop before and after the tweaks. Agent drive and verify: with "Allow agent control" turned on (the round button above the launcher; off at every start, a chip shows while it is on, Esc turns it off), the coding agent operates the running app through MCP tools on the bridge: `get_screen`, `find_widgets` by source line, type, text or key, `inspect`, `flash`, `tap` and `long_press` (refused with "obscured by X" when something covers the widget), `enter_text`, `scroll`, `scroll_to` (it scrolls a lazy list until the item is built), `navigate` and `back` (named routes and `Router` apps), `wait_idle`, `set_environment`, `scan`, `screenshot` and `get_state` (with `PinPointConfig.stateAdapters` for Bloc, Riverpod or Provider values). A note can carry checks (Add check in the comment form, or from a finding); `verify_note` runs them under the note's environment and route, with an after screenshot, and the pin shows pass or fail for you to accept. `stress_matrix` tries widths, text scales, RTL and dark, and files one draft note per distinct problem. The example has named routes and a `Router` app (`lib/router_app.dart`). See `PLAN.md` for the build order.

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

Counter and spinner, long list, dialog and bottom sheet, nested navigator, `CustomPaint`, form with text fields and a custom `SaveBar` widget, `HtmlElementView` (web only), and a What-if probe that prints what the app inherits.

## License

Not chosen yet. The `LICENSE` file is the Flutter template placeholder.

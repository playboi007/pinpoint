# Pinpoint

A debug-only Flutter package. Click any widget in a running app, write a comment, and give a coding agent the widget's source location, layout context and a screenshot.

Web is the first target.

> **Status: Milestone 7 (Session 7).** The wrapper, the inspect mode (Alt+Shift+C or the launcher button), Esc and freeze (P while picking) work. Hover outlines the widget under the pointer, and a click selects the nearest widget written in your own project (a `Text`, not the `RichText` it builds), with `file:line` in the label. The click opens a panel next to the widget with a clickable breadcrumb and two tabs. Comment: choose Bug, Improve or Question, type the comment, then Send (or Ctrl/Cmd+Enter) to every sink in `PinPointConfig.sinks`, with a toast per sink, or Copy as Markdown. The comment is kept until a send succeeds. Info: the widget's layout data; there, Arrow Up or `[` moves to the next local ancestor, Arrow Down or `]` moves back, and Alt plus an arrow steps through framework widgets too. Rulers measure to the nearest local ancestor (hold Alt and hover another widget to measure the gap), and the mouse wheel still scrolls the app. The note is an `Annotation` (schema 1, under 8 KB as JSON). With "Include screenshot" ticked (the default), Send adds a PNG crop of the widget with a red outline, at most 1600 px wide (`PinPointConfig.maxScreenshotWidth`). `HttpSink` posts each note to the local bridge (`dart run pinpoint:bridge`), which writes it into `.pinpoint/open/` as Markdown, JSON and PNG; `ClipboardSink` copies the Markdown. When picking starts and the bridge does not answer, a "bridge offline" badge shows. Empty files under `lib/src/` and `bin/setup.dart` are for later milestones. See `PLAN.md` for the build order.

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

Each Send writes `.pinpoint/open/<id>.md`, `<id>.json` (no image data) and `<id>.png`. The bridge listens on this machine only and accepts notes only from pages served from this machine (`localhost`, `127.0.0.1`); `--lan` and `--allow-origin <url>` widen that for testing on a phone. It writes `.pinpoint/.gitignore` (`*`), so the notes are never committed; add `.pinpoint/` to your own `.gitignore` too if you like.

If port 4747 is taken, start the bridge with `--port <n>` and give the app the same port: `HttpSink.bridge(port: n)`, or `--dart-define=PINPOINT_BRIDGE_PORT=n`.

## Agent hand-off

Add this section to your agent instruction file (`CLAUDE.md` for Claude Code, `AGENTS.md` for others). The bridge prints it at start until one of them has it:

```text
## Pinpoint notes
UI feedback from the running app lives in .pinpoint/open/*.md.
When asked to "work the pinpoint notes": for each note, open the Source
file at the given line, read the comment, view the PNG named on the
Screenshot line, make the change, run flutter analyze, then move the
note's files (<id>.md, <id>.json and <id>.png) to .pinpoint/resolved/ and
append one line describing the fix to the .md.
```

## What it will do

- Inspect mode: hover to outline a widget, click to select it.
- Source refinement: select the nearest widget written in your own project, with `file:line`.
- Comments and a payload an agent can act on without seeing the app.
- Sinks: clipboard, and a local bridge that writes notes into `.pinpoint/`.
- Agent hand-off: an instruction section, so the agent works the notes in `.pinpoint/open/`.
- Later: pins, an MCP bridge, what-if environment switches, automatic problem detection, live tweak, and agent drive and verify.

Source locations come from Flutter's `--track-widget-creation`, which is on only in debug builds. The package defaults to `enabled: kDebugMode`.

## Repository layout

```text
PLAN.md             # the implementation plan (read this first)
docs/api-notes.md   # Flutter SDK API checks; overrides PLAN.md where they differ
lib/                # package source (empty files are later milestones)
bin/                # bridge.dart (Milestone 7); setup.dart is empty
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

# after a deliberate change to the note's shape: rewrite the golden, review the diff
flutter test --update-goldens test/capture/target_test.dart
flutter test --update-goldens test/sink/markdown_formatter_test.dart

# the bridge by hand: preflight, then a real note
dart run pinpoint:bridge
curl -i -X OPTIONS http://localhost:4747/annotations -H 'Origin: http://localhost:5000' \
  -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type'
curl -i -X POST http://localhost:4747/annotations -H 'content-type: application/json' \
  --data @test/fixtures/note.json

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

Counter and spinner, long list, dialog and bottom sheet, nested navigator, `CustomPaint`, form with text fields and a custom `SaveBar` widget, and `HtmlElementView` (web only).

## License

Not chosen yet. The `LICENSE` file is the Flutter template placeholder.

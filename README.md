# Pinpoint

A debug-only Flutter package. Click any widget in a running app, write a comment, and give a coding agent the widget's source location, layout context and a screenshot.

Web is the first target.

> **Status: Milestone 6 (Session 6).** The wrapper, the inspect mode (Alt+Shift+C or the launcher button), Esc and freeze (P while picking) work. Hover outlines the widget under the pointer, and a click selects the nearest widget written in your own project (a `Text`, not the `RichText` it builds), with `file:line` in the label. The click opens a panel next to the widget with a clickable breadcrumb and two tabs. Comment: choose Bug, Improve or Question, type the comment, then Send (or Ctrl/Cmd+Enter) to every sink in `PinPointConfig.sinks`, with a toast per sink, or Copy as Markdown. The comment is kept until a send succeeds. Info: the widget's layout data; there, Arrow Up or `[` moves to the next local ancestor, Arrow Down or `]` moves back, and Alt plus an arrow steps through framework widgets too. Rulers measure to the nearest local ancestor (hold Alt and hover another widget to measure the gap), and the mouse wheel still scrolls the app. The note is an `Annotation` (schema 1, under 8 KB as JSON). With "Include screenshot" ticked (the default), Send adds a PNG crop of the widget with a red outline, at most 1600 px wide (`PinPointConfig.maxScreenshotWidth`); the image goes to a sink as base64 only when it asks for it. The HTTP and clipboard sinks come in Milestone 7; the example app prints each note to the console, and the screenshot as a `data:` URL you can paste in the address bar. Empty files under `lib/src/` and `bin/` are for later milestones. See `PLAN.md` for the build order.

```dart
MaterialApp(
  builder: (context, child) => PinPointWrapper(
    config: const PinPointConfig(sinks: [MySink()]), // a PinPointSink
    child: child,
  ),
  home: const HomeScreen(),
)
```

## What it will do

- Inspect mode: hover to outline a widget, click to select it.
- Source refinement: select the nearest widget written in your own project, with `file:line`.
- Comments and a payload an agent can act on without seeing the app.
- Sinks: clipboard, and a local bridge that writes notes into `.pinpoint/`.
- Later: pins, an MCP bridge, what-if environment switches, automatic problem detection, live tweak, and agent drive and verify.

Source locations come from Flutter's `--track-widget-creation`, which is on only in debug builds. The package defaults to `enabled: kDebugMode`.

## Repository layout

```text
PLAN.md             # the implementation plan (read this first)
docs/api-notes.md   # Flutter SDK API checks; overrides PLAN.md where they differ
lib/                # package source (empty files are later milestones)
bin/                # bridge and setup entry points (empty)
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

# after a deliberate change to the note's shape: rewrite the golden, review the diff
flutter test --update-goldens test/capture/target_test.dart

# the example app; PINPOINT_ROOT makes paths project-relative
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

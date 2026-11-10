# Pinpoint

A debug-only Flutter package. Click any widget in a running app, write a comment, and give a coding agent the widget's source location, layout context and a screenshot.

Web is the first target.

> **Status: Milestone 2 (Session 2).** The wrapper, the inspect mode (Alt+Shift+C or the launcher button), Esc and freeze (P while picking) work. Hover outlines the widget under the pointer, a click selects it and opens a draggable info panel, rulers measure to the parent (hold Alt and hover another widget to measure the gap), and the mouse wheel still scrolls the app. Source locations come in Milestone 3. Empty files under `lib/src/` and `bin/` are for later milestones. See `PLAN.md` for the build order.

```dart
MaterialApp(
  builder: (context, child) => PinPointWrapper(child: child),
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

# the example app
cd example && flutter run -d chrome

# the same, printing p50 and p95 pick time after every 200 hover picks
cd example && flutter run -d chrome --dart-define=PINPOINT_PICK_TIMINGS=true
```

## Example screens

Counter and spinner, long list, dialog and bottom sheet, nested navigator, `CustomPaint`, form with text fields, and `HtmlElementView` (web only).

## License

Not chosen yet. The `LICENSE` file is the Flutter template placeholder.

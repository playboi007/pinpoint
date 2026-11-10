# Pinpoint

A debug-only Flutter package. Click any widget in a running app, write a comment, and give a coding agent the widget's source location, layout context and a screenshot.

Web is the first target.

> **Status: Milestone 1 (Session 1).** The wrapper, the inspect mode (Alt+Shift+C or the launcher button), Esc and freeze (P while picking) work. Picking a widget comes in Milestone 2. Empty files under `lib/src/` and `bin/` are for later milestones. See `PLAN.md` for the build order.

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
lib/                # package source (empty files, by design)
bin/                # bridge and setup entry points (empty)
example/            # manual test bed: six screens
test/               # package tests (one spike test so far)
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

# the example app
cd example && flutter run -d chrome
```

## Example screens

Counter and spinner, long list, dialog and bottom sheet, nested navigator, `CustomPaint`, form with text fields, and `HtmlElementView` (web only).

## License

Not chosen yet. The `LICENSE` file is the Flutter template placeholder.

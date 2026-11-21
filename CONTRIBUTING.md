# Contributing

Thank you for your interest in Pinpoint. This page tells you how to set up, test and send a change.

Report bugs and request features in the [issue tracker](https://github.com/playboi007/pinpoint/issues). The user docs are in [docs/](docs/README.md). Notes on Flutter SDK behavior that the code relies on are in [docs/api-notes.md](docs/api-notes.md). If one of those facts changes, fix it there.

## Set up

You need Flutter 3.38.0 or newer. The code is checked with Flutter 3.47.5 (Dart 3.13.4).

```bash
git clone https://github.com/playboi007/pinpoint
cd pinpoint
flutter pub get
flutter analyze                # fast compile-break check, includes example/
```

`analysis_options.yaml` is strict. `invalid_use_of_protected_member` and `invalid_use_of_visible_for_testing_member` are errors on purpose.

Run the example app (see [docs/example-app.md](docs/example-app.md)):

```bash
cd example
dart run pinpoint:bridge
# in a second terminal:
flutter run -d chrome --dart-define=PINPOINT_ROOT=$(pwd)
```

New assets need a full `flutter run`, not a hot restart.

## Run tests

Run only the tests for what you changed. Run the whole suite (root and `example/`) only before a commit that touches shared code.

```bash
flutter test test/overlay/construction            # a folder
flutter test test/sink/markdown_formatter_test.dart   # a file
(cd example && flutter test test/screens_test.dart)   # example app tests
```

Tests mirror `lib/src/` folder by folder:

| Folder | Covers |
| --- | --- |
| `test/core` | Wrapper, controller, keymap, note book, note sync |
| `test/search`, `test/source` | Picking, source locations |
| `test/info`, `test/tweak` | The INFO and TWEAK tabs |
| `test/capture`, `test/model`, `test/sink` | The note: context, screenshot, shape, Markdown, sinks |
| `test/overlay`, `test/theme` | Everything drawn over the app |
| `test/detect`, `test/env` | Findings and what-if |
| `test/trace`, `test/tape`, `test/state` | Recorder, tapes, state lens |
| `test/agent` | Commands the agent runs in the app |
| `test/bridge` | The bridge, MCP tools, setup, undo |
| `test/support` | Fakes and hosts. Reuse them. Do not write new fakes. |

Tests marked `@TestOn('browser')` need Chrome:

```bash
flutter test --platform chrome test/overlay/construction/web
flutter test --platform chrome test/trace/web test/tape/web test/state/web
flutter test --platform chrome test/theme/palette_store_web_test.dart
flutter test --platform chrome --wasm test/state/web     # under dart2wasm
```

After a deliberate change to the note's shape, update the goldens and review the diff:

```bash
flutter test --update-goldens test/sink/markdown_formatter_test.dart
flutter test --update-goldens test/capture/target_test.dart
```

## Rules

Tests check most of these rules.

- Files that `bin/` imports stay plain Dart: no `dart:ui` and no `package:flutter`. This covers `lib/src/bridge/` and `lib/src/model/`. The app never imports `dart:io`.
- Only `source_resolver.dart` and `source_index.dart` touch `WidgetInspectorService`.
- Web-only code uses a conditional import: `x.dart` (interface), `x_web.dart` (`dart:js_interop`, no `package:web`) and `x_stub.dart`. Tests use fakes from `test/support/`.
- No Flutter animation while an agent works. Work-in-progress visuals are HTML and CSS in the page.
- Motion durations come from `lib/src/theme/pinpoint_motion.dart`. Do not hard-code durations.
- Colors and type come from the theme. Every surface must work in all palettes.
- Privacy: recorded network bodies stay local. Storage capture is off by default. Mask `obscureText` values. Use `lib/src/trace/redact.dart`.
- The note shape (`lib/src/model/annotation.dart`) has a schema version and goldens. A shape change bumps the schema and updates the goldens on purpose.
- Agent-facing text (`agent_instructions.dart`, the MCP `instructions` in `mcp_server.dart`, the tool descriptions in `agent_tools.dart`) is pinned by tests. Change text and tests together.
- Pinpoint is a package for many apps. Do not write a rule that depends on one app's field names, widget names or folder layout. Test each state style with a small fake, not a new dependency. The package depends only on `flutter` and `http`.

## Send a change

- Work on a feature branch. Do not push to `main`.
- Make one commit for each logical step. Write a clean subject and a body that says why.
- Before you open a pull request: `flutter analyze` is clean and the targeted tests pass. Run the whole suite if you touched shared code.
- Do not commit files that are not part of your change.

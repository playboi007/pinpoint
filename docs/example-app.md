# Example app

Back to the [docs index](README.md).

The `example/` folder is a test bed. It uses Pinpoint through a path dependency.

## Run it

```bash
cd example
dart run pinpoint:bridge          # keep it running
```

In a second terminal:

```bash
cd example
flutter run -d chrome --dart-define=PINPOINT_ROOT=$(pwd)
```

Start the bridge in `example/` first, or Send reports it offline. `PINPOINT_ROOT` makes paths in notes relative to the project.

Optional `--dart-define` flags:

- `PINPOINT_PICK_TIMINGS=true` prints the p50 and p95 pick time after every 200 hover picks.
- `PINPOINT_CAPTURE_TIMINGS=true` prints the time and size of each screenshot. A capture over 300 ms prints anyway.

`flutter run -d chrome --wasm` runs the app under WebAssembly. A full app run under wasm is not verified.

## Screens

The home screen lists these screens. Each has a named route, so a note records its route and the agent can `navigate` there.

| Screen | Route | What it is for |
| --- | --- | --- |
| Counter and spinner | `/counter` | A simple screen with a counter and a spinner. |
| Long list | `/long-list` | A lazy list of 1000 items. Try `scroll_to`. |
| Dialog and bottom sheet | `/dialog-sheet` | A dialog and a bottom sheet. |
| Nested navigator | `/nested` | A `Navigator` inside a screen. |
| CustomPaint | `/custom-paint` | A `CustomPaint` widget. |
| Form | `/form` | Text fields and a custom `SaveBar` widget. |
| HtmlElementView | `/html-view` | An HTML element in the page (web only). |
| What-if probe | `/what-if` | Prints what the app inherits, so you can check each [what-if](usage/what-if.md) switch. |
| Bug zoo | `/bug-zoo` | One planted problem of each kind. See [findings](usage/findings.md). The overflow shows only below 432 px wide. |
| Planted loop | `/planted-loop` | A load scheduled from `build`. Try `why` on the fifth request. See [causes and network](causes-and-network.md). |
| State coupling | `/state-coupling` | Three ways two values change together. Try Watch state. See [state lens](usage/state-lens.md). |

## A Router app

A second entry point navigates with a `Router` instead of named routes. The agent's `navigate` and `back` are checked on both kinds.

```bash
cd example
flutter run -d chrome -t lib/router_app.dart
```

The main example calls `PinPoint.run` in `main`, so events have causes.

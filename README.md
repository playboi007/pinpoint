<a id="readme-top"></a>

<div align="center">

# Pinpoint

**Debug-only widget comment overlay: click any widget, comment, and hand a coding agent its source location, layout context and screenshot.**

[Docs](docs/README.md) · [Report a bug](https://github.com/playboi007/pinpoint/issues) · [Request a feature](https://github.com/playboi007/pinpoint/issues)

[![Flutter][flutter-shield]][flutter-url]
[![Debug only][debug-shield]][about]
[![Web first][web-shield]][platform-support]
[![License: MIT][license-shield]][license-url]

</div>

<details>
  <summary>Table of contents</summary>
  <ol>
    <li><a href="#about">About</a></li>
    <li><a href="#platform-support">Platform support</a></li>
    <li><a href="#how-it-works">How it works</a></li>
    <li><a href="#getting-started">Getting started</a></li>
    <li><a href="#usage">Usage</a></li>
    <li><a href="#agent-setup-mcp">Agent setup (MCP)</a></li>
    <li><a href="#advanced">Advanced</a></li>
    <li><a href="#privacy">Privacy</a></li>
    <li><a href="#limits">Limits</a></li>
    <li><a href="#troubleshooting">Troubleshooting</a></li>
    <li><a href="#example-app">Example app</a></li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license-and-acknowledgments">License and acknowledgments</a></li>
  </ol>
</details>

## About

Pinpoint is a debug-only Flutter package. You click a widget in your running app, write a comment, and press Send. A coding agent gets the widget's source file and line, its layout and a screenshot. The agent can also read what the app did, and it can operate the app.

It is for Flutter developers who work with a coding agent that supports MCP. The web is the first target. Pinpoint is under active development (version 0.0.1).

<!-- MEDIA E1: hero loop 10-15 s — Alt+Shift+C, hover, click, comment, Send, pin appears -->

<p align="right"><a href="#readme-top">back to top</a></p>

## Platform support

| Platform | Status |
| --- | --- |
| Chrome, `flutter run -d chrome` (DDC, debug) | Main target. Tested by hand and by tests. |
| Web, wasm | The network, replay and state hooks have browser tests that run under dart2wasm. A full app run under wasm is not verified. |
| Dart VM (`flutter test`) | Widget tests cover the overlay and the bridge. The VM is not an app target. |
| Android, iOS, macOS, Windows, Linux | Not tested on a device. Browser-only parts (network hooks, tape replay, storage, page messages) are stubs outside the web. |

<p align="right"><a href="#readme-top">back to top</a></p>

## How it works

Three processes work together.

```text
app (Flutter web)  --HTTP-->  bridge (Dart, port 4747)  <--MCP /mcp--  coding agent
```

- The **app** holds the overlay. It picks widgets, builds notes and shows pins.
- The **bridge** is a small Dart server. It stores notes in `.pinpoint/` and serves MCP tools.
- The **agent** reads notes through MCP. It can also drive the app through the bridge.

The path of one note: you pick a widget, and Pinpoint finds its source line. Pinpoint builds the note and sends it to the bridge. The bridge writes it into `.pinpoint/open/`. The agent reads it, changes the code and sets the note to fixed. The app polls the bridge and updates the pin. You accept the result or reopen the note.

More in [docs/architecture.md](docs/architecture.md).

## Getting started

### Prerequisites

- Flutter 3.38.0 or newer. The notes in this repo were checked with Flutter 3.47.5 (Dart 3.13.4).
- For the agent part: a coding agent that can connect to an MCP server over HTTP, for example Claude Code.

### Installation

Pinpoint is not on pub.dev. Install it from git.

1. Add the package to `dependencies`. The wrapper is imported from `lib/main.dart`, so it must not be a dev dependency.

   ```yaml
   dependencies:
     pinpoint:
       git: https://github.com/playboi007/pinpoint
   ```

   ```bash
   flutter pub get
   ```

2. Wrap the app in `PinPointWrapper`. Put it in `MaterialApp.builder`, above the Navigator.

   ```dart
   import 'package:pinpoint/pinpoint.dart';

   MaterialApp(
     builder: (context, child) => PinPointWrapper(
       config: PinPointConfig(sinks: [HttpSink.bridge(), const ClipboardSink()]),
       child: child,
     ),
     home: const HomeScreen(),
   )
   ```

3. Recommended: run the app inside `PinPoint.run`. Without it, Pinpoint cannot say which tap or frame caused an event. Call it first in `main`. If `main` calls `WidgetsFlutterBinding.ensureInitialized()`, put that call inside it.

   ```dart
   void main() => PinPoint.run(() => runApp(const MyApp()));
   ```

4. Start the bridge in the app folder. Keep it running.

   ```bash
   dart run pinpoint:bridge
   ```

5. Run setup once. It writes the agent instructions and an MCP config. With `--write` it also edits `CLAUDE.md` (or `AGENTS.md`) and `.mcp.json`.

   ```bash
   dart run pinpoint:setup --write
   ```

6. Run the app. `PINPOINT_ROOT` makes paths in notes relative to your project. The last flag lets the agent hot reload the app.

   ```bash
   flutter run -d chrome \
     --dart-define=PINPOINT_ROOT=$(pwd) \
     --vmservice-out-file=.pinpoint/vm-service.txt
   ```

Press Alt+Shift+C, or click the launcher button, to start picking.

<p align="right"><a href="#readme-top">back to top</a></p>

## Usage

Each mode has its own page in [docs/usage/](docs/usage/).

**Pick and comment.** Hover to outline a widget, click to select it, write the comment, press Send. [More](docs/usage/pick-and-comment.md).

<!-- MEDIA E2: pick and comment, 8-10 s — pick a widget, choose Bug, type, Ctrl+Enter, toast -->

**Info, rulers and the candidate dial.** Layout data, rulers, and a dial that steps through the widgets under one spot. [More](docs/usage/info-and-rulers.md).

<!-- MEDIA E3: info tab, rulers, Alt-hover gap, turning the candidate dial, 10 s -->

**What-if.** Change viewport, text scale, theme and more without touching app code. [More](docs/usage/what-if.md).

<!-- MEDIA E4: what-if panel, narrow viewport, text scale 2x, RTL, reset, 10 s -->

**Findings.** Pinpoint finds overflow, cut text, large images, errors and accessibility problems. [More](docs/usage/findings.md).

<!-- MEDIA E5: findings list on the Bug zoo screen, hover a finding, Send note, 10 s -->

**Tweak.** Edit padding, size, colors and more on the live widget. [More](docs/usage/tweak.md).

<!-- MEDIA E6: tweak tab, change padding and a color, reset one, 8 s -->

**Pins and drafts.** Each note stays on screen as a numbered pin. A draft is a pin no agent sees. Delete moves a note to `.pinpoint/tmp/` for at least 1 hour. To restore it, move its files back. [More](docs/usage/pins-and-drafts.md).

<!-- MEDIA E7: save a draft, send it, agent sets fixed, accept, 12 s -->

**State lens.** Open the STATE tab and press Watch state. Pinpoint shows what changed, which method did it and which widgets rebuilt. [More](docs/usage/state-lens.md).

<!-- MEDIA E8: State coupling screen, Watch state, tap Fetch, read the story card, 12 s -->

<p align="right"><a href="#readme-top">back to top</a></p>

## Agent setup (MCP)

`dart run pinpoint:setup` writes the agent guide into `.pinpoint/`: `README.md`, `SKILL.md`, three commands, `tools.md` and `mcp.json`. `dart run pinpoint:setup --write` also copies it where your agent looks (Claude Code, Cursor, VS Code, `AGENTS.md`) and merges the MCP entry into each agent's MCP file. Other servers in those files stay.

```bash
dart run pinpoint:setup --write                      # all four agents
dart run pinpoint:setup --write --agents claude,cursor
dart run pinpoint:setup --write --refresh            # after a package update
```

For Claude Code you can also run:

```bash
claude mcp add --transport http pinpoint http://127.0.0.1:4747/mcp
```

The agent reads notes with `list_notes` and `get_note` and reports with `update_note`. A note moves from submitted to inProgress, then to fixed or resolved. You accept it, or you reopen it.

<!-- MEDIA E9: agent works a note, pin changes, user presses Accept, 12 s -->

**Undo of agent work.** The `Changes · N` button on a note lets you undo some or all of the agent's changes. With git, the bridge puts the files back. Without git, it asks the agent to do it. [More](docs/undo.md).

<!-- MEDIA E10: Changes · 2, tick one change, Undo selected, note reopens, 10 s -->

Tools: [docs/agent-tools.md](docs/agent-tools.md). Details: [docs/agent-setup.md](docs/agent-setup.md), [docs/bridge.md](docs/bridge.md).

## Advanced

- **Flight recorder.** A bounded record of taps, keys, routes and errors. [More](docs/flight-recorder.md)
- **Causes and network.** With `PinPoint.run`, each event names what started it. Requests are recorded with secrets masked. [More](docs/causes-and-network.md)
- **Tapes.** A tape saves the inputs and network answers of a run, so an agent can replay it. [More](docs/tapes.md)
- **state_flow.** The agent tool that explains why a value changed. [More](docs/usage/state-lens.md)

<!-- MEDIA E11: Timeline panel with events grouped by cause, click flashes a widget, 10 s -->
<!-- MEDIA E12: replay of a tape with the banner, 10 s -->

## Privacy

- The bridge listens on this machine only. It accepts notes only from pages served from this machine.
- `.pinpoint/` is git-ignored.
- Secrets are masked before they are stored. This covers header values, URL parameters and page URL query values.
- `localStorage` and `sessionStorage` capture is off by default. Text fields with `obscureText` are masked.
- Tapes hold request and response bodies. They stay in `.pinpoint/tapes/`.
- `--ttl` deletes old notes, tapes and runs. Deleted notes are flushed from `.pinpoint/tmp/` after at least 1 hour.
- Pinpoint runs only in debug builds. Whether its code is fully left out of release builds is not verified yet.

More: [docs/privacy.md](docs/privacy.md).

## Limits

- Pinpoint cannot read plain or private fields.
- Without `PinPoint.run`, events have no causes. An async gap cuts the chain even with it.
- Bloc and Riverpod are not verified. They show as rebuilds today.
- Stack formats differ per platform. In wasm, only closures have names.
- Hover is not recorded by default. Some what-if switches cannot fake the device (for example, the pixel ratio).

More: [docs/limits.md](docs/limits.md).

## Troubleshooting

- **"bridge offline" badge.** Start `dart run pinpoint:bridge` in the app folder.
- **Port 4747 is in use.** Start the bridge with `--port <n>`. Give the app the same port.
- **A phone cannot reach the bridge.** See `--lan` in [docs/bridge.md](docs/bridge.md).
- **"Zone mismatch".** Call `PinPoint.run` first in `main`.
- **A bug goes away with Pinpoint on.** Try `PinPointConfig(trace: TraceConfig(enabled: false))`.
- **Missing assets.** Check that the app runs a fresh build.

More: [docs/troubleshooting.md](docs/troubleshooting.md).

## Example app

The `example/` app is a test bed with 11 screens. Run it:

```bash
dart run pinpoint:bridge          # in example/
flutter run -d chrome --dart-define=PINPOINT_ROOT=$(pwd)
```

Screens: [docs/example-app.md](docs/example-app.md).

## Roadmap

- Check that release builds leave Pinpoint out.
- Choose a name that can be published.
- Opt-in adapters for Bloc and Riverpod.
- Demo videos.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License and acknowledgments

MIT. See [LICENSE](LICENSE).

Built with [Flutter](https://flutter.dev) and the [`http`](https://pub.dev/packages/http) package. The bundled Roboto Mono font is under the SIL Open Font License ([assets/fonts/OFL.txt](assets/fonts/OFL.txt)).

<p align="right"><a href="#readme-top">back to top</a></p>

[about]: #about
[platform-support]: #platform-support
[flutter-shield]: https://img.shields.io/badge/Flutter-%E2%89%A53.38-02569B?logo=flutter&logoColor=white
[flutter-url]: https://flutter.dev
[debug-shield]: https://img.shields.io/badge/build-debug%20only-orange
[web-shield]: https://img.shields.io/badge/platform-web%20first-blue
[license-shield]: https://img.shields.io/badge/license-MIT-green
[license-url]: LICENSE

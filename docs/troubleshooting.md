# Troubleshooting

Back to the [docs index](README.md).

## The bridge

- **A "bridge offline" badge shows when picking starts.** The app cannot reach the bridge. Start `dart run pinpoint:bridge` in the app folder. The badge names the address, for example `127.0.0.1:4747`.
- **The bridge says it cannot listen.** Port 4747 is in use. Start the bridge with `--port <n>`. Give the app the same port: `HttpSink.bridge(port: n)` or `--dart-define=PINPOINT_BRIDGE_PORT=n`.
- **The bridge refuses a request.** The log names the origin. Start the bridge with `--allow-origin <that origin>`.
- **A phone cannot reach the bridge.** Start the bridge with `--lan` and `--allow-origin <the page origin>`. Give the app a sink with the LAN address. See [bridge](bridge.md). Not verified here.

## The overlay

- **Alt+Shift+C does nothing.** Some browsers and operating systems take certain key combinations first. Click the launcher button. Or set another shortcut with `PinPointConfig.shortcut`.
- **Nothing shows in a release build.** Pinpoint runs only in debug builds.
- **Missing images in the "under construction" cover, or old behavior.** The app may run an old build. New assets need a full `flutter run`, not a hot restart.

## The agent

- **"agent control is disabled".** Turn on "Allow agent control" on the rail. It is off at every start. Esc turns it off.
- **The agent says the app does not answer.** A hidden browser tab stops the command poll. On macOS, a Chrome window that other windows cover fully counts as hidden. Keep the window visible.
- **`hot_reload` fails.** Start the app with `flutter run --vmservice-out-file=.pinpoint/vm-service.txt`. Or give the agent the debug service address once.
- **A tap is refused with "obscured by X".** Something covers the widget, for example a dialog barrier. Close it first.

## Events and causes

- **"Zone mismatch" in the console.** The Flutter binding was set up in one zone and `runApp` runs in another. Call `PinPoint.run` first in `main`, around `WidgetsFlutterBinding.ensureInitialized()` and `runApp`.
- **"no causes. The Flutter binding existed before PinPoint.run".** Same fix.
- **Blocks say "no cause recorded".** `PinPoint.run` is not in use. See [causes and network](causes-and-network.md).
- **A bug goes away with Pinpoint on.** The recorder changes timing a little. Turn it off: `PinPointConfig(trace: TraceConfig(enabled: false))`. If you use `PinPoint.run`, pass the same `TraceConfig` to it.
- **Rebuilds are not recorded.** Open the Timeline, set a watch, or ask the agent to call `trace_detail`. If DevTools "track rebuilds" was turned on after Pinpoint, turn it on first. See [flight recorder](flight-recorder.md).

## Undo

- **The button reads "Ask agent to undo selected".** There is no git repository, or git is not installed. The bridge cannot put the files back. See [undo](undo.md).

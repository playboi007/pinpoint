# Causes and network

Back to the [docs index](README.md).

## Causes

Wrap `runApp` in `PinPoint.run`. Then every event names the entry that started it: a tap, a frame, a key, a `window` message, or an agent command. `get_trace` shows the cause as `c37` on each line.

```dart
void main() => PinPoint.run(() => runApp(const MyApp()));
```

- **Call it first in `main`.** Put `WidgetsFlutterBinding.ensureInitialized()` inside it too. Flutter prints "Zone mismatch" when the binding is set up in one zone and `runApp` runs in another. When the binding already exists, `PinPoint.run` runs the app with no zone, records no causes, and prints one hint.
- **What it costs.** One child zone for each entry from the engine (a pointer packet, a frame), for the whole run. The zone cannot start later. To turn it off, use `PinPoint.run(..., trace: const TraceConfig(causes: false))`. Pass the same `TraceConfig` you give `PinPointConfig.trace`.
- **Errors nobody caught** (an `async` handler nobody awaits) become `error` events with their cause. They still reach the app's own handler. On web they otherwise show only in the browser console.
- **Outside debug builds**, `PinPoint.run` only calls your function.

Without `PinPoint.run`, events group by frame, and any "after tap X" is only a hint.

## Agent tools for causes

- `why({seq})` walks back from one event to the tap or frame that started it, and through the frames that led there. It says `loop: true` when each frame repeats the same work.
- `caused_by({target})` counts what a widget's subtree started.
- The Timeline groups events by cause. The INFO tab says what the picked widget caused in the last 5 seconds.

## Limits of causes

- A post-frame callback runs with the cause of the frame that calls it.
- A frame is linked to every cause that ran since the frame before it. `why` picks the one that set state, answered a request or took input.
- A timer or a stream keeps the cause of the moment it was made. `why` shows the age of an old cause.
- An async gap cuts the chain. The cause zone bridges it only with `PinPoint.run`. Work in another isolate (`compute`) is not seen.

## Network

On web, `fetch` (used by `package:http`) and `XMLHttpRequest` (used by Dio) give `net.request`, then `net.response` or `net.error`, with the cause of the call. The app gets the browser's own promise and response.

- Bodies are read from a clone, to hash them. Up to 256 KB of each is kept for tapes. Large, binary and event-stream answers are never cloned.
- `TraceConfig(bodies: false)` reads no body.
- **Secrets.** Header values and URL parameters named in `TraceConfig.redact` are masked before an event exists. The defaults are `authorization`, `cookie`, `set-cookie`, and any name with `token`, `key` or `secret` in it. To keep the defaults and add one, use `[...TraceRedact.defaults, 'x-session']`. A `*` matches any text at the start or end of a name.
- Traffic to the bridge is never recorded.
- Outside web, the network source is a stub. Nothing is recorded there.

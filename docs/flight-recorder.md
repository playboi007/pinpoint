# Flight recorder

Back to the [docs index](README.md).

<!-- MEDIA E11: Timeline panel with events grouped by cause, click flashes a widget, 10 s -->

From the moment the wrapper starts, Pinpoint keeps a bounded record of what the app did. It records:

- Taps, with the widget under the pointer and its anchor.
- Keys.
- Text field values. Values of `obscureText` fields are masked.
- Routes.
- Errors and findings.
- Frames.
- `PinPoint.probe` lines and marks.
- Network requests, on web. See [causes and network](causes-and-network.md).

## Limits of the record

The record holds at most 20,000 events and about 4 MB (`TraceConfig.maxEvents` and `TraceConfig.maxBytes`). When a limit drops old events, every answer built on the record says `partial`.

Frames with nothing else between them fold into one `frame` event per second at most. A screen that animates does not push older events out.

## Rebuilds and watches (level 3)

Rebuilds per widget, and watched state, run only while one of these is true: the Timeline is open, a watch is set, or the agent asked with `trace_detail`. They are costly for each event.

The rebuild hook is the slot that DevTools "track rebuilds" needs. Turn DevTools tracking on first, and Pinpoint shares the slot: both get every rebuild. The other order fails, because DevTools asserts that the slot is empty.

## The Timeline

Open it with the Timeline button on the rail.

- It lists events by frame, with the recorder's own time for each frame.
- Filter chips select event kinds.
- A click on an event flashes its widget.
- Events are grouped by cause when `PinPoint.run` is in use.
- Press M while picking, or the Mark button in the Timeline, to mark the moment. A mark can be named.

## In notes

A note carries `trace`: what happened in its widget's subtree in the 10 seconds before you started picking. It shows under "What happened" in the Markdown. When rebuilds were not recorded, the first line says so.

## Agent tools

- `get_trace` reads the record as compact lines, with repeats folded (`×n`).
- `trace_detail` turns level 3 on or off.
- `watch` and `unwatch` follow a widget's `State`. Only values that a `State` lists in `debugFillProperties` are seen.
- `mark` records a mark.
- `list_probes` (on the bridge) lists `PinPoint.probe(` lines left in `lib/`.

`update_note` warns while probe lines remain in `lib/`.

## Probes

A probe records values each time its line runs. Use it for a value that diagnostics cannot show, such as a private field. The agent adds a probe, hot reloads, reads it with `get_trace`, and removes it.

```dart
PinPoint.probe('existing.ensureLoaded', {'type': type, 'loaded': _loadedForType});
```

With Pinpoint off, nothing is recorded and `PinPoint.probe` returns at once. It does nothing in release builds.

## Settings

Set `PinPointConfig(trace: TraceConfig(...))`. See `TraceConfig` for `enabled`, `maxEvents`, `maxBytes`, `sources`, `causes`, `bodies`, `redact`, `storage` and `matchIgnore`.

The recorder changes timing a little. If a bug goes away with Pinpoint on, turn the recorder off first:

```dart
PinPointConfig(trace: TraceConfig(enabled: false))
```

`enabled: false` is the real off switch: no recorder, no source, no hook.

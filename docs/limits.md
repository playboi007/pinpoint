# Limits

Back to the [docs index](README.md).

## What Pinpoint cannot see

- **No reflection.** Plain and private fields are not readable. Pinpoint reads `ValueListenable.value`, diagnostics (`debugFillProperties`) and opt-in adapters. For anything else, an agent can add a `PinPoint.probe` line.
- **No causes without `PinPoint.run`.** Changes group by frame. Any "after tap X" is only a hint.
- **Async gaps.** A stream, an `await` or an isolate cuts the stack. The cause zone bridges the gap only with `PinPoint.run`. Work in another isolate (`compute`) is not seen.
- **Stack formats differ.** DDC, dart2js, wasm and the VM give different stack formats. In wasm, only closures have names. Names do not depend on the stack alone.
- **Hover** moves are not recorded by default, because of the cost.
- **Mobile.** Platform channels are not an input source on mobile.

## State styles

How Pinpoint sees each state style with no app code.

| State style | What Pinpoint sees | What it cannot see | Status |
| --- | --- | --- | --- |
| `setState` | The `State`, the line that called `setState`, rebuilds | Plain field values | The story reads from `setState` rows and code lines. |
| `ValueNotifier` with `ValueListenableBuilder` | Notifies, the setter's line, values before and after | A notifier no builder or scope exposes | Verified. Many rows of one notifier type are grouped. |
| `ChangeNotifier`, `ListenableBuilder`, `InheritedNotifier` | Notifies, the line of `notifyListeners`, readers | Field values | Verified. |
| Provider (`ChangeNotifierProvider`, `context.watch`) | Scopes, the value, who reads it | Field values; `select` aspects | Verified on Provider 6.1.5. |
| Bloc / Cubit | `BlocProvider` scopes, `BlocBuilder` rebuilds | The `emit` line, because a stream delivers the state later | Not verified. The cause is linked to the tap with `PinPoint.run`. An opt-in adapter is planned. |
| Riverpod | The `ProviderScope`, consumer rebuilds | Which provider a widget watches; provider values | Not verified. An opt-in adapter is planned. |
| Streams, `StreamBuilder`, `FutureBuilder`, GetX, MobX, signals, Redux | Rebuilds, causes (with `PinPoint.run`) | Usually the line that pushed the value | Shown as a `setState` after an async gap. |

`PinPointConfig.stateAdapters` adds the app's own state (Bloc, Riverpod, Provider) to the agent's `get_state` dump. It is opt-in. The zero-code path works without it.

## Source locations

Source locations come from Flutter's `--track-widget-creation`, which is on only in debug builds.

## What-if

Some what-if switches cannot fake the device. See [what-if](usage/what-if.md#what-the-switches-cannot-do).

## Tapes and causes

See the limits in [tapes](tapes.md) and [causes and network](causes-and-network.md).

## Debug only

Pinpoint runs only in debug builds. Whether its code is fully left out of release builds is not verified yet.

## Platforms

Web is the main target. Other platforms are not tested. See [Platform support](../README.md#platform-support).

## The recorder

- The recorder changes timing a little. If a bug goes away with Pinpoint on, try `TraceConfig(enabled: false)`.
- It keeps at most 20,000 events and about 4 MB. Older events go first.

# State lens

Back to the [docs index](../README.md).

<!-- MEDIA E8: State coupling screen, Watch state, tap Fetch, read the story card, 12 s -->

The state lens shows how state moves on a screen: which object notified, which method did it, which values changed and which widgets rebuilt. It needs no change in app code.

## Start a watch

1. Pick a widget.
2. Open the STATE tab.
3. Press **Watch state**.

For up to 30 seconds, Pinpoint listens to the objects the widget reads and to the builders under it. A live card shows the result as a story. Press **Stop** to end the watch early, or **Watch again** to start a new one. The STATE tab has three sections: Reads (the objects the widget reads), Watch, and Changes (the story).

The agent can do the same with the `state_flow` tool. See [agent tools](../agent-tools.md).

## Read the story

Time runs down the card. The oldest block is at the top and the newest is at the bottom. The card follows the bottom until you scroll up. Then it shows a "3 new ↓" button.

**A block is one cause.** Examples: `tap "Fetch"`, `key Enter`, `typing in Email`, `timer or async callback`, `network answer GET /items`, `route change`, `frame callback`, `agent tap`, `replayed tap`.

**The time** is `+1.24 s` from the start of the watch. Hover it for the clock time. A change after an `await` stays under its tap and shows an offset such as `+420 ms`.

**Under the cause are the rows that changed.** Each row has:

- The name of the object.
- What changed, in a few words: `focused false → true`, `length 3 → 4`, `changed in place`, `new object, same value`.
- The method, with a folder button to `file:line`.
- The code lines there.
- Which widgets rebuilt.

**Names.** The name is the app's class when it has one. If not, it is the expression in your code (for example `_focused`, read by the bridge from the builder's line). If not, it is a short type. The short type shows first.

**Folds.** Many instances of one notifier (list rows) are one row with a count, for example `×12`. Open it to see each instance by its `Key`, index or text.

## Filters

- Hover blocks, and blocks that only move focus, are folded: "4 hover changes hidden · show".
- Framework controllers (text, scroll, focus, tab, animation) are folded the same way.
- **Only my state** hides owners that live outside your project.

For the agent, `hover: true` and `controllers: true` show the folded blocks.

## "No cause recorded"

Without `PinPoint.run`, changes group by frame and say "no cause recorded". A tap or key in the 300 ms before a change shows as "maybe after". With `PinPoint.run` in `main`, causes are exact. See [causes and network](../causes-and-network.md).

## Values

- Values are clipped and run through the redaction names (`token`, `key`, `secret`, `password`).
- A controller shows its verb ("text changed"), never its text.
- A value Pinpoint cannot read shows nothing. It does not guess. The code lines show what a plain field was set to.

## Limits

- The card keeps the last 60 blocks, with at most 12 rows in a block. Older blocks and dropped `setState` stacks are counted.
- A hot reload adds a line and the watch goes on. If the target leaves the screen, the watch ends.
- A watch costs a stack for each `setState` while it is open, so it closes by itself.
- Pinpoint cannot read plain or private fields. See [limits](../limits.md) for state styles (Provider, Bloc, Riverpod and others).
- On web, the lens reads the browser's `console.error` output for a while to drop Flutter's own noise. It forwards everything else unchanged.

## Try it

The example app has a State coupling screen. Pick the "loading" line, open the STATE tab and press Watch state. Then tap Open dialog and Fetch in the dialog. See [example app](../example-app.md).

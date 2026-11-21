# Pick and comment

Back to the [docs index](../README.md).

<!-- MEDIA E2: pick and comment, 8-10 s — pick a widget, choose Bug, type, Ctrl+Enter, toast -->

## Start and stop picking

- Press Alt+Shift+C, or click the launcher button. The launcher is at the bottom of the rail on the right edge of the screen. You can drag the rail up and down.
- Press Esc to go one step back.
- Change the shortcut with `PinPointConfig.shortcut`. On macOS, Option+Shift+C types a character, so Pinpoint also matches the physical C key.
- Some browsers and operating systems take certain key combinations first. Use the launcher button then.

While you pick:

- Hover outlines the widget under the pointer.
- Click selects the nearest widget that is written in your own project. For a `Text`, it selects the `Text`, not the `RichText` it builds. The label shows `file:line`. A folder button shows the short path and line in a popover.
- P freezes the app's tickers (animations). Press it again to resume.
- M marks this moment in the [flight recorder](../flight-recorder.md).
- The mouse wheel still scrolls the app.

## The panel

A click opens a panel next to the widget. It has a breadcrumb of the widget's ancestors, and four tabs: INFO, TWEAK, STATE and COMMENT. The breadcrumb is clickable. See [info and rulers](info-and-rulers.md) for how to move the selection.

## Write the comment

1. Choose Bug, Improve or Question.
2. Type the comment in the field ("What should change?").
3. Press Send, or press Ctrl+Enter (Cmd+Enter on macOS).

Pinpoint sends the note to every sink in `PinPointConfig.sinks` and shows a toast for each sink. The comment stays in the field until a send succeeds.

Other controls on the tab:

- **Include screenshot** is on by default. The note gets a PNG crop of the widget, with a red outline. The image is at most 1600 px wide (`PinPointConfig.maxScreenshotWidth`).
- **Add check** attaches a check to the note. The agent can run it with `verify_note`.
- A switch to attach what happened as a tape. It shows the size. See [tapes](../tapes.md).
- The copy button copies the note as Markdown.
- **Save draft** keeps the note as a draft. See [pins and drafts](pins-and-drafts.md).
- **Cancel** closes the form.

## Sinks

`PinPointConfig.sinks` lists where Send delivers a note:

- `HttpSink.bridge()` posts to the local bridge at `http://127.0.0.1:4747`. It uses the port from `--dart-define=PINPOINT_BRIDGE_PORT=n`, or you pass `HttpSink.bridge(port: n)`.
- `ClipboardSink()` copies the Markdown. It needs no bridge.

With no sink, Send reports that nothing took the note. The copy button still works.

When picking starts and the bridge does not answer, a "bridge offline" badge shows.

## What a note holds

The note is an `Annotation` (schema version 11). It holds your comment, the target widget with its source line, the enclosing widgets, layout, page and route, the what-if settings, findings, tweaks, checks, the screenshot, and a short record of what happened in the widget in the 10 seconds before you started picking. The text the agent reads is the standard detail. Ask for more with `get_note` detail `full`.

The page URL in a note has its query values masked.

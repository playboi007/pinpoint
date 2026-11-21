# Tapes

Back to the [docs index](README.md).

<!-- MEDIA E12: replay of a tape with the banner, 10 s -->

A tape is the inputs and network answers of a run, saved so the run can happen again. The recorder keeps them from app start, apart from the ring buffer, with up to 20 MB of answer bodies. When a limit is passed, the oldest go and the tape is partial.

## Attach to a note

The comment form has a switch for this, with the size next to it. A note then carries a tape:

- a **full** tape from app start, when nothing was dropped, or
- a **segment** from the last mark.

You can pick the range with the range picker in the form. The pin shows a **Replay** button. The agent sees "has tape". The tape is on the bridge in `.pinpoint/tapes/`, which is git-ignored. No tool answer shows a body.

An agent can also save a tape with `save_tape` and list tapes with `list_tapes` and `get_tape`.

## Replay

`replay({tape})` plays the inputs into the app. While it runs, `fetch` and XHR are answered from the tape. With `unmatched: "fail"` (the default), no request reaches a server.

- A full tape reloads the page first, so in-memory state starts from a known value. `PinPoint.run` then loads the tape before `runApp`.
- Inputs go in logical order: each waits for the answers that came before it, and for its widget. The widget is found by anchor, so a button that moved is still hit.
- Real taps are blocked. A banner shows the step. Press Esc to stop. Everything is put back.

## What replay answers

- `state`: done, held, stopped or diverged.
- `first_difference`: the first step that differs (route order, request keys, anchors).
- The requests the tape had no answer for.

`until: "mark"` holds at your mark. Pick, `get_state` and `screenshot` work there. `resume_replay` goes on. Each run streams to the bridge, so `get_trace({run})` reads it after the page reloaded.

`unmatched` can also be `passthrough` (to the real server; use it after a fix that changes requests) or `last`. `speed` and `latency` change the timing.

## Settings

- `TraceConfig(storage: true)` copies `localStorage` and `sessionStorage` at app start and puts them back on replay. It is off by default, because they hold session tokens.
- `TraceConfig(matchIgnore: ['ts', 'requestId'])` leaves fields that change on every run out of a request's key.
- `TraceConfig(bodies: false)` gives segments only. Their requests reach the server.

## Limits

- Replay does not control the clock or random numbers. A token that expired since the recording shows as the first difference.
- Key events alone are not replayed. The text they made is.
- WebSockets reach the server during a replay.
- Replay works on web. Outside web the browser parts are stubs.

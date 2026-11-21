# Privacy

Back to the [docs index](README.md).

Pinpoint keeps data on your machine. This page lists what it records and how it protects it.

## Where data goes

- The bridge listens on `127.0.0.1` only, unless you start it with `--lan`. See [bridge](bridge.md).
- The bridge accepts notes only from pages served from this machine (`localhost`, `127.0.0.1`). `--allow-origin` adds more origins.
- Notes, screenshots, tapes and runs are files in `.pinpoint/`. The bridge writes `.pinpoint/.gitignore` with `*`, so they are never committed. You can also add `.pinpoint/` to your own `.gitignore`.
- The agent reads what the bridge gives it. A screenshot shows whatever is on screen, and the agent reads it. Keep personal data off the screen when you send a note.

## What is masked or off

- **Secrets in the record.** Header values and URL parameters named in `TraceConfig.redact` are masked before an event exists. The defaults are `authorization`, `cookie`, `set-cookie`, and any name with `token`, `key` or `secret` in it. Traffic to the bridge is never recorded.
- **Page URL.** A note masks the query values of the page URL, because the URL often carries a session token. The names stay.
- **Storage.** `localStorage` and `sessionStorage` capture is off by default. `TraceConfig(storage: true)` turns it on for tapes.
- **Text fields.** Values of `obscureText` fields are masked.
- **State lens values.** Values are clipped and run through the redaction names (`token`, `key`, `secret`, `password`). A controller shows its verb, never its text.
- **Network bodies.** Bodies are read from a clone, only to hash them and to keep up to 256 KB each for tapes. They stay in the app and never go into an event. `TraceConfig(bodies: false)` reads no body.
- **Tapes.** A tape holds request and response bodies. They stay in `.pinpoint/tapes/` on your machine. No tool answer shows a body.

## Deleting data

- By default, notes, tapes and runs stay until you delete them.
- `--ttl 24h` (or `30m`, `7d`) makes the bridge delete each one that has not changed for that long.
- A note you delete in the app moves to `.pinpoint/tmp/`. The bridge flushes entries at least 1 hour old, every hour.
- When a note is deleted, its undo checkpoints (git refs under `refs/pinpoint/`) are dropped.

## Debug builds and release builds

Pinpoint runs only in debug builds. `PinPointConfig.enabled` defaults to `kDebugMode`. Whether its code is fully left out of release builds is not verified yet.

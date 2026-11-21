# The bridge

Back to the [docs index](README.md).

The bridge is a small Dart server. The app sends notes to it over HTTP. The agent reads them over MCP. You start it in the app folder:

```bash
dart run pinpoint:bridge            # http://127.0.0.1:4747, notes in .pinpoint/
dart run pinpoint:bridge --help
```

The bridge code is plain Dart. It uses no `dart:ui` and no `package:flutter`, and adds no dependency.

## Flags

| Flag | What it does |
| --- | --- |
| `--port <n>` | The port to listen on. Default 4747. The app must use the same port: `HttpSink.bridge(port: n)` or `--dart-define=PINPOINT_BRIDGE_PORT=n`. |
| `--dir <path>` | The folder for the notes. Default `.pinpoint`. |
| `--lan` | Listen on every network interface, for testing on a phone. Without it, only this machine can connect. |
| `--allow-origin <url>` | Also accept notes from pages served at `<url>`, for example `http://192.168.1.20:5000`. Repeatable. Pages served from this machine are always accepted. |
| `--ttl <age>` | Delete notes (any status, with their screenshots), tapes and replay runs not changed for `<age>`: `30m`, `24h` or `7d`. Checked at start and every hour. Without it, nothing is deleted. |
| `--timing` | Log where the time of each agent command went: in the queue, in the app, on the network. |
| `-h`, `--help` | Show the usage text. |

## Ports

- The bridge listens on `127.0.0.1`. It does not listen on IPv6.
- `HttpSink.bridge()` posts to `http://127.0.0.1:<port>/annotations`.
- The bridge address in the app comes from `PinPointConfig.bridgeUrl`. If that is null, it comes from the first `HttpSink.bridge()` in `sinks`. With neither, notes and pins live in that browser tab only.
- If the port is in use, the bridge says so and exits. Start it with `--port <n>` and give the app the same port.

## Who can talk to the bridge

The bridge refuses requests with an `Origin` header that is not from this machine (`localhost`, `127.0.0.1`). It logs the refusal and the flag to use. A request with no `Origin` header (curl, an agent) is accepted. `GET /health` always answers while the bridge runs.

`--lan` and `--allow-origin` widen this for a phone. With `--lan`, every device on your network can reach the port. `HttpSink.bridge()` points to `127.0.0.1`. For a phone, give the sink the LAN address yourself, for example `HttpSink(Uri.parse('http://192.168.1.20:4747/annotations'))`. This path is not verified here.

## The .pinpoint/ folder

| Path | What is in it |
| --- | --- |
| `open/` | `<id>.md`, `<id>.json`, `<id>.png` of notes that are submitted, inProgress or fixed. The agent's work list. |
| `resolved/` | The same files for notes that are resolved, accepted or rejected. |
| `drafts/` | `<id>.json` and `<id>.png` of drafts. There is no `.md`, so no agent finds them. |
| `tmp/` | Deleted notes, in `<id>__<time>/` folders. Flushed after at least 1 hour. See below. |
| `tapes/` | Tapes (inputs and network answers of a run), with bodies. |
| `runs/` | Replay runs, as `<id>.jsonl` and `<id>.json`. |
| `undo/` | A temporary copy of the git index, used for undo checkpoints. |
| `config.json` | The bridge's live status. See below. |
| `README.md`, `SKILL.md`, `commands/`, `tools.md`, `agent-instructions.md`, `mcp.json` | The agent guide, written by `dart run pinpoint:setup`. See [agent setup](agent-setup.md). |
| `vm-service.txt` | The app's debug service address, if you start `flutter run` with `--vmservice-out-file=.pinpoint/vm-service.txt`. |
| `.gitignore` | Contains `*`, so nothing in this folder is committed. |

The `.json` file holds no image data. The `.md` is the note as text for the agent. It is the standard detail plus a last line: `More: get_note detail full, or <id>.json`.

You can move a note's files between `open/` and `resolved/` by hand. The bridge notices.

## config.json

The bridge writes `.pinpoint/config.json` at start and again when it stops with Ctrl+C or `kill`. It is status, not settings: options are flags.

```json
{
  "name": "pinpoint",
  "status": "running",
  "version": "0.0.1",
  "noteSchema": 11,
  "port": 4747,
  "root": "/path/to/app",
  "pid": 12345,
  "startedAt": "2026-11-21T09:00:00.000Z",
  "endpoints": { "mcp": "http://127.0.0.1:4747/mcp", "health": "http://127.0.0.1:4747/health" }
}
```

After a clean stop, `status` is `stopped` and `stoppedAt` is added. A bridge that crashes cannot update the file, so `running` can be stale: call `GET /health` or `list_notes` to be sure. If a newer bridge started in the same folder, the older one does not overwrite its file.

At start, if `.pinpoint/SKILL.md` is from an older package version, the bridge logs one line: `pinpoint: agent guide files are from <version>; run dart run pinpoint:setup --refresh`.

## Keeping and deleting

- Notes, screenshots, tapes and runs stay until you delete them. With `--ttl`, the bridge deletes each one that has not changed for that long. The pin of a deleted note goes from the app too.
- A note you delete in the app moves, with its files, into `tmp/<id>__<time>/`. The bridge flushes entries at least 1 hour old, at start and every hour. A deleted note stays 1 to 2 hours. To undo a delete, move the files back.
- When a note is deleted or expires, its git checkpoints are dropped. See [undo](undo.md).

## How the app talks to the bridge

- The app loads its pins at start.
- While the overlay is active, the app asks `GET /changes` with a long poll. The bridge holds the request up to 25 s and answers at once when something changes. Idle, the app sends no polls. A tab does not hear about its own writes.
- With agent control on, the app long-polls `GET /commands` for the agent's commands and posts the results back.
- `GET /source` and `GET /declaration` give the state lens the lines of a method and where a class is declared.
- Tapes go to `/tapes`. Replay runs go to `/runs`.

## Hot reload

The bridge can hot reload the app through its debug service. It finds the address in `.pinpoint/vm-service.txt`, or from the agent's `hot_reload` call. On web, a reload that did not compile is reported as one that did not apply. The bridge also hot reloads after a clean undo, when the address file exists.

# Changelog

## Unreleased

Pinpoint is at version 0.0.1 and not published.

### Notes and the overlay

- Pick a widget in a running app (Alt+Shift+C or the launcher). The note gets the source `file:line`, layout, enclosing widgets and a screenshot.
- Comment as Bug, Improve or Question. Send to the local bridge, copy as Markdown, or save a draft.
- Pins stay on their widgets. Drafts, accept and reopen with a reason.
- INFO tab with rulers, a breadcrumb and a candidate dial for the widgets under one spot.
- What-if switches: viewport, text scale, bold text, safe area, fake keyboard, direction, theme, color scheme, platform and slow motion.
- Findings: overflow, cut text, oversized images, errors, accessibility checks, rebuild heat and debug paint.
- Tweak: live edits of padding, size, flex, alignment, opacity, clip, text style, decoration and more. Notes list the tweaks.

### The bridge and the agent

- `dart run pinpoint:bridge` writes notes to `.pinpoint/`. It serves MCP at `/mcp`, listens on loopback only, and has `--port`, `--dir`, `--lan`, `--allow-origin`, `--ttl` and `--timing`.
- `dart run pinpoint:setup` writes agent instructions and an MCP config. `--write` edits `CLAUDE.md` (or `AGENTS.md`) and `.mcp.json`.
- 40 MCP tools: notes, drive and verify the app, what-if and scan, `hot_reload`, flight recorder, and tapes.
- Notes can carry checks. `verify_note` runs them. `stress_matrix` files draft notes for problems.

### Flight recorder, causes and tapes

- A bounded record of taps, keys, text, routes, errors, findings, frames, probes and marks. A Timeline panel and a `trace` in each note.
- `PinPoint.run` links each event to the tap, frame or key that started it. `why` and `caused_by` read the chain.
- On web, `fetch` and XHR are recorded with secrets masked.
- Tapes record the inputs and network answers of a run. `replay` plays them back and reports the first difference.

### Lean notes and undo

- Smaller notes: short paths, fewer ancestors, one default text, masked page URL.
- The overlay long-polls the bridge for changes (25 s) and sends no polls while idle.
- Deleted notes move to `.pinpoint/tmp/` and are flushed after at least 1 hour.
- Undo of agent work: the bridge records rounds with git checkpoints. The `Changes · N` button undoes some or all of a round. Without git, it asks the agent. `get_note_diff` gives the patch.

### State lens

- STATE tab and Watch state: a story of causes, changed values, methods with source lines, and rebuilt widgets. The agent tool `state_flow` gives the same story as text.

# Media shot list

The README and the docs have slots for GIFs and screenshots. A slot is an HTML comment, for example `<!-- MEDIA E1: ... -->`. The page renders clean until a file exists. To fill a slot, put the file in this folder and replace the comment with an image link.

## Rules

- Record only the example app (`example/`).
- Use one palette (Redline) and one viewport for all media.
- A GIF must be smaller than 4 MB.
- Keep each loop short (see the length in the table).
- Show the real UI. Do not add overlays or edits that change what the UI looks like.

## Slots

| ID | Place | Format | What to show |
| --- | --- | --- | --- |
| E1 | README, About (hero) | GIF, 10-15 s | Alt+Shift+C, hover, click a widget, type a comment, Send, the pin appears. |
| E2 | README, Usage: pick and comment. Also `docs/usage/pick-and-comment.md` | GIF, 8-10 s | Pick a widget, choose Bug, type a comment, press Ctrl+Enter or Cmd+Enter, the toast shows. |
| E3 | README, Usage: info and rulers. Also `docs/usage/info-and-rulers.md` | GIF, 10 s | INFO tab, rulers, hold Alt and hover another widget to see the gap, turn the candidate dial. |
| E4 | README, Usage: what-if. Also `docs/usage/what-if.md` | GIF, 10 s | Open What-if, set a narrow viewport, text scale 2x and RTL, then Reset all. |
| E5 | README, Usage: findings. Also `docs/usage/findings.md` | GIF, 10 s | Bug zoo screen. Scan this screen, hover a finding, press Send note. |
| E6 | README, Usage: tweak. Also `docs/usage/tweak.md` | GIF, 8 s | TWEAK tab. Change padding and a color. Reset one tweak. |
| E7 | README, Usage: pins and drafts. Also `docs/usage/pins-and-drafts.md` | GIF, 12 s | Save a draft, send it, the agent sets fixed, press Accept. |
| E8 | README, Usage: state lens. Also `docs/usage/state-lens.md` | GIF, 12 s | State coupling screen. Pick the "loading" line, STATE tab, Watch state, tap Open dialog and Fetch, read the story card. |
| E9 | README, Agent setup. Also `docs/agent-setup.md` | GIF, 12 s | An agent works a note. The pin changes. Press Accept. |
| E10 | README, Agent setup (undo). Also `docs/undo.md` | GIF, 10 s | Open `Changes · 2`, tick one change, press Undo selected, the note opens again. |
| E11 | README, Advanced. Also `docs/flight-recorder.md` | GIF, 10 s | Timeline panel with events grouped by cause. Click an event: the widget flashes. |
| E12 | README, Advanced. Also `docs/tapes.md` | GIF, 10 s | A tape replay: the banner shows the step. |

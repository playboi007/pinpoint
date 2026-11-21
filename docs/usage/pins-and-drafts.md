# Pins and drafts

Back to the [docs index](../README.md).

<!-- MEDIA E7: save a draft, send it, agent sets fixed, accept, 12 s -->

## Pins

Each note stays on screen as a numbered pin on its widget. The pin follows the widget through scroll, resize and hot reload. The app loads its pins from the bridge at start.

Click a pin to open its note. The note view has these buttons:

- **Delete**.
- **Replay**, when the note has a tape. See [tapes](../tapes.md).
- **Reopen**, once the agent marks the note done. You can type a reason first ("What is still wrong?").
- **Accept**, once the agent says it is done. For a note the agent has answered but not marked done, the button is **Accept anyway**.
- **Changes · N**, when the latest closed round has changes. See [undo](../undo.md).

The agent's replies show under REPLIES.

A pin fades when the agent says the note is done. It stays until you accept the result, because an agent can mark a note resolved without fixing it. After you accept, the pin goes and the note files move to `.pinpoint/resolved/`.

If Pinpoint is off when you click a pin, it stays off. The app then takes every click outside the panel, so you can try the agent's change before you accept it. Closing the note returns to off.

## Drafts

**Save draft** keeps a note as a draft pin. The bridge stores it in `.pinpoint/drafts/`. No agent tool lists, reads or changes a draft. Half-written feedback never starts an edit.

To send a draft, open it and press **Send**. With more than one draft, **Send all N drafts** sends them together.

## Delete and restore

Delete moves the note and its files into `.pinpoint/tmp/<id>__<time>/`. It does not destroy them. The bridge flushes entries at least 1 hour old, every hour. So a deleted note stays between 1 and 2 hours.

To restore a note, move its files back into `.pinpoint/open/`, `.pinpoint/drafts/` or `.pinpoint/resolved/`. The bridge sees the move.

If the note has a tape, the tape moves with it, unless another note uses the same tape.

See [bridge](../bridge.md) for the folders.

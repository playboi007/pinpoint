# Undo of agent work

Back to the [docs index](README.md).

<!-- MEDIA E10: Changes · 2, tick one change, Undo selected, note reopens, 10 s -->

The bridge records what the agent changed for each note. You can undo all of it or part of it. The note opens again, and your reason goes to the agent.

## Words

- **Round**: one pass of the agent on a note, from `inProgress` to `fixed` or `resolved`.
- **Checkpoint**: a git tree of the working folder at one moment.
- **Change**: one labelled unit of a round. It has a summary and the files it touched.

## How the bridge records a round

1. When you send a note (or reopen it), the bridge takes a base checkpoint.
2. When the agent sets `inProgress`, a round starts with a checkpoint.
3. When the agent sets `fixed` or `resolved`, the round ends with a second checkpoint. The bridge compares the two and lists the files and line counts. If the agent never set `inProgress`, the round starts from the base checkpoint.

The agent gives `changes` with `update_note`: one `{summary, files}` for each separate change. The bridge matches each file to the diff. Files in the diff that no change names go into a change called `other`. A file that is not in the diff is dropped, and the answer says so. A file that another note's open round also changed has a `shared` tag.

The bridge compares the whole working folder before and after the round. Files that `.gitignore` ignores are not in it, so `.pinpoint/` and `build/` are left out. Edits you make in that time also show up.

## Undo from the note

When the latest closed round has changes, the note shows a `Changes · N` button. It is hidden for drafts and while the agent works. Press it to open the section.

- One checkbox for each change, with its summary and a line for each file (`file +added −removed`). Nothing is ticked at first. A change that is already undone is struck through.
- With more than one round, pick one (R1, R2...). The latest closed round is shown first.
- **Undo selected** and **Undo all** act on the ticked changes or on all.
- The reason field is the one used by Reopen: "What is still wrong? Sent with Reopen or Undo".

After the call, a toast shows the result. The note goes back to `submitted`, as a reopen does, with a message from you.

## With git

The bridge reverses the files of the chosen changes with `git apply`. First it runs `git apply --check` on the same patch. If the check fails, because a file changed since, no file changes. Then the bridge asks the agent to undo the changes (see below).

On a clean undo, the bridge hot reloads the app when it knows the debug service address (`.pinpoint/vm-service.txt`). The agent then gets this message: `Undone by the bridge: <summaries>. Kept: <summaries>. Do not make the undone changes again. Reason: <reason>`.

**Git commands the bridge runs:** `rev-parse`, `add -A` and `write-tree` (against a temporary copy of the index in `.pinpoint/undo/`), `commit-tree`, `update-ref` (only under `refs/pinpoint/<noteId>/<label>`), `diff-tree`, and `apply --check` and `apply`.

**Git commands the bridge never runs:** `checkout`, `reset`, `stash`, or a commit on a branch. It never moves `HEAD` and never writes your index. It writes git objects and the refs under `refs/pinpoint/`. It drops the refs when the note is deleted or expires.

## Without git, or after a conflict

No file changes. The note goes back to `submitted` with this message: `Undo these changes yourself: <summaries> (<files>). Keep: <summaries>. Then continue. Reason: <reason>. get_note_diff gives the patch.` The buttons then read **Ask agent to undo selected** and **Ask agent to undo all**. The agent reverts the files itself. `get_note_diff` gives it the patch. Without git, it lists only the files the agent named.

## Limits

- Undo works on a closed round. The bridge refuses it while the agent has the note, for a round still open, and for changes already undone.
- The smallest unit is one labelled change. There is no line-level undo.
- There is no undo of an undo.
- A patch over 40 KB from `get_note_diff` gives the file list only. Ask for one change at a time.
- Without labels, all files go into `other`. Ask the agent to label its changes.

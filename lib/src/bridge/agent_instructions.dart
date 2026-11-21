// Plain Dart: the bridge prints this, and `dart run pinpoint:setup` writes
// it. The shared sentences are also used by the MCP instructions and the
// generated SKILL.md, so the three cannot disagree.

/// The heading an agent instruction file has once the section is in it.
const String agentSectionHeading = '## Pinpoint notes';

/// How the agent labels its changes with `fixed`.
const String changeLabelsLine =
    'When you set a note fixed, give changes: one {summary, files} for each '
    'separate change, so the user can undo one of them.';

/// What the agent does after an undo.
const String undoLine =
    'After an undo the note is submitted again: do not make the undone '
    'changes again. If the last reply says "Undo these changes yourself", '
    'revert those files (get_note_diff gives the patch), then continue.';

/// What the agent does with a reopened note.
const String reopenedLine =
    'A note the user reopened is submitted again, "reopened" in its header, '
    'with their reason as the last reply: work it again, set it fixed again, '
    'and call verify_note again if it has checks.';

/// Why every code change for a note ends with `update_note`.
const String finishInNotesLine =
    'Finish every code change for a note that way, also when the user asked '
    'for it in chat: the pin shows only what update_note says.';

/// How the agent operates the app.
const String operateLine =
    'To operate the app, name widgets with target queries and put several '
    'actions in one run_steps call; check once at the end.';

/// How the agent reads what happened and why.
const String readTraceLine =
    'To see what happened over time, call get_trace (trace_detail or watch '
    'add rebuilds and state). To learn what started an event, call why with '
    'its seq; to learn what a widget started, caused_by; to learn why two '
    'values change together, or what changed a value, state_flow.';

/// How the agent reads a value no diagnostics show.
const String probeLine =
    'For a value no diagnostics show, add a PinPoint.probe line, hot_reload, '
    'read it with get_trace, and remove it before you set the note fixed '
    '(list_probes).';

/// How the agent uses a tape.
const String tapeLine =
    'A note that "has tape" can happen again: replay({tape}) plays what the '
    'user did and answers first_difference; until: "mark" holds at the '
    'user\'s mark for get_state and screenshot. Read the run with '
    'get_trace({run}).';

/// The section to add to the project's agent instruction file (`CLAUDE.md`
/// for Claude Code, `AGENTS.md` for others), for notes kept in [dir].
String agentInstructions({String dir = '.pinpoint'}) =>
    '''
$agentSectionHeading
UI feedback from the running app lives in $dir/open/*.md.
When asked to "work the pinpoint notes": for each note, open the Source
file at the given line, read the comment, view the PNG named on the
Screenshot line, make the change, run flutter analyze, then move the
note's files (<id>.md, <id>.json and <id>.png) to $dir/resolved/ and
append one line describing the fix to the .md.
With the pinpoint MCP server connected, use its tools instead: list_notes,
get_note (it attaches the screenshot), then update_note(id, "resolved",
message) with one line saying what you changed. The pin in the app
updates. Leave $dir/drafts/ alone: drafts are not sent yet.
$changeLabelsLine
$undoLine
To learn why two values change together, or what changed a value, call
state_flow with the widget as target, act, then call it again.
''';

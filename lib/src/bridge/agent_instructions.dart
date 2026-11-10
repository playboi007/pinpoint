// Plain Dart: the bridge prints this, and Milestone 8's setup writes it.

/// The heading an agent instruction file has once the section is in it.
const String agentSectionHeading = '## Pinpoint notes';

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
''';

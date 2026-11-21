// Plain Dart with `dart:io`: `dart run pinpoint:setup` runs this. No `args`
// package, so setup adds no dependency.

import 'dart:convert';
import 'dart:io';

import 'agent_guide.dart';
import 'agent_instructions.dart';
import 'bridge_protocol.dart';
import 'package_version.dart';

/// How to run `dart run pinpoint:setup`.
const String setupUsage =
    '''
Usage: dart run pinpoint:setup [options]

Writes the agent guide into <dir>/ (README.md, SKILL.md, commands/,
tools.md, mcp.json, agent-instructions.md) and prints what to add where.
Edits your agent files only with --write.

Options:
  --dir <path>      Folder for the notes (default .pinpoint).
  --port <n>        The bridge's port (default $defaultBridgePort).
  --write           Also copy the guide to where each agent looks, add the
                    pinpoint server to its MCP file (merged: other servers
                    stay), and add the section to CLAUDE.md or AGENTS.md.
  --agents <list>   Which agents --write serves, comma separated: claude
                    (.claude/ skill and commands, .mcp.json, CLAUDE.md),
                    cursor (.cursor/rules, .cursor/mcp.json), vscode
                    (.vscode/mcp.json), agents (AGENTS.md). Default: all.
  --refresh         Rewrite files that already exist and differ, and update
                    an existing pinpoint server entry. Without it, setup
                    keeps them and says so. Use it after you update the
                    package.
  -h, --help        Show this text.
''';

const Set<AgentKind> _allAgents = {
  AgentKind.claude,
  AgentKind.cursor,
  AgentKind.vscode,
  AgentKind.agents,
};

/// The setup's flags.
class SetupOptions {
  const SetupOptions({
    this.dir = '.pinpoint',
    this.port = defaultBridgePort,
    this.write = false,
    this.refresh = false,
    this.agents = _allAgents,
    this.help = false,
  });

  final String dir;
  final int port;

  /// Edit the agent files, not only print what to add.
  final bool write;

  /// Rewrite existing files that differ, and update an existing `pinpoint`
  /// MCP entry.
  final bool refresh;

  /// The agents `--write` serves.
  final Set<AgentKind> agents;

  final bool help;
}

/// Why setup stopped.
class SetupException implements Exception {
  const SetupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [args] as [SetupOptions]. Throws a [FormatException] that says what is
/// wrong.
SetupOptions parseSetupArgs(List<String> args) {
  var dir = '.pinpoint';
  var port = defaultBridgePort;
  var write = false;
  var refresh = false;
  var agents = _allAgents;
  var help = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    final equals = arg.indexOf('=');
    final name = equals < 0 ? arg : arg.substring(0, equals);
    String value() {
      final text = equals >= 0
          ? arg.substring(equals + 1)
          : i + 1 < args.length
          ? args[++i]
          : '';
      if (text.isEmpty) throw FormatException('$name needs a value');
      return text;
    }

    switch (name) {
      case '--dir':
        dir = value();
      case '--port':
        final text = value();
        final n = int.tryParse(text);
        if (n == null || n < 1 || n > 65535) {
          throw FormatException('--port must be 1 to 65535, not $text');
        }
        port = n;
      case '--agents':
        agents = _parseAgents(value());
      case '--write' when equals < 0:
        write = true;
      case '--refresh' when equals < 0:
        refresh = true;
      case '-h' || '--help' when equals < 0:
        help = true;
      default:
        throw FormatException('Unknown option: $arg');
    }
  }
  return SetupOptions(
    dir: dir,
    port: port,
    write: write,
    refresh: refresh,
    agents: agents,
    help: help,
  );
}

Set<AgentKind> _parseAgents(String text) => {
  for (final part in text.split(','))
    AgentKind.values.firstWhere(
      (kind) => kind.flag == part.trim().toLowerCase(),
      orElse: () => throw FormatException(
        '--agents: unknown agent "$part"; use '
        '${AgentKind.values.map((kind) => kind.flag).join(', ')}',
      ),
    ),
};

/// The MCP server entry for the bridge on [port], in Claude Code's form.
Map<String, Object?> mcpServerEntry(int port) =>
    mcpEntryFor(AgentKind.claude, port)!;

/// How to start the app so the agent's `hot_reload` finds it: the debug
/// service address goes into `<dir>/vm-service.txt`.
String hotReloadHint(String dir) =>
    'So the agent can hot reload the app, start it with: flutter run '
    '--vmservice-out-file=$dir/$vmServiceFileName';

enum _Action { wrote, updated, unchanged, kept, merged, skipped, added }

/// What setup did with one file, for the summary.
class _Result {
  const _Result(this.action, this.path, [this.note]);

  final _Action action;
  final String path;
  final String? note;

  @override
  String toString() =>
      '  ${action.name.padRight(9)} $path${note == null ? '' : ' ($note)'}';
}

/// Results of a step, and the reasons it left a file alone.
typedef _Step = (List<_Result> results, List<String> problems);

/// Runs the setup in [project] (the app's folder) and returns what to
/// print, line by line.
///
/// Writes the guide into `<dir>/`. A file that exists and differs (an edit,
/// or an older version) is kept unless [SetupOptions.refresh] is set. With
/// [SetupOptions.write], also copies the guide where each of
/// [SetupOptions.agents] looks, merges the `pinpoint` server into their MCP
/// files, and adds the agent section to `CLAUDE.md` or `AGENTS.md`.
///
/// A JSON file that is not valid is never touched. Setup goes on with the
/// other files, then throws a [SetupException] with the whole summary.
Future<List<String>> runSetup(SetupOptions options, Directory project) async {
  final notes = _notesFolder(options.dir, project);
  await notes.create(recursive: true);
  final ignore = File('${notes.path}/.gitignore');
  if (!ignore.existsSync()) await ignore.writeAsString('*\n');

  final dirName = notes.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  final section = agentInstructions(dir: dirName);
  final (inNotes, notesProblems) = await _writeGuide(
    notes,
    dirName,
    section,
    options,
  );
  final head = [
    'Pinpoint setup, version $pinpointVersion.',
    '',
    'In $dirName/:',
    ...inNotes.map((r) => '$r'),
    '',
  ];
  if (!options.write) {
    return [...head, ..._preview(options, project, dirName, section)];
  }

  final (copies, copyProblems) = await _writeCopies(
    project,
    dirName,
    section,
    options,
  );
  final problems = [...notesProblems, ...copyProblems];
  final out = [
    ...head,
    'Where each agent looks (${_agentNames(options)}):',
    ...copies.map((r) => '$r'),
    '',
    'Start the bridge with `dart run pinpoint:bridge`.',
    hotReloadHint(dirName),
    if (!options.refresh &&
        [...inNotes, ...copies].any((r) => r.action == _Action.kept)) ...[
      '',
      'Files marked "kept" differ from the generated text. Run with '
          '--refresh to rewrite them.',
    ],
  ];
  if (problems.isEmpty) return out;
  throw SetupException(
    [...out, '', 'Left alone:', ...problems.map((p) => '  $p')].join('\n'),
  );
}

Directory _notesFolder(String dir, Directory project) =>
    Directory(Directory(dir).isAbsolute ? dir : '${project.path}/$dir');

String _agentNames(SetupOptions options) => AgentKind.values
    .where(options.agents.contains)
    .map((a) => a.label)
    .join(', ');

/// The guide in `<dir>/`: the generated files, `agent-instructions.md` and
/// the example MCP entry.
Future<_Step> _writeGuide(
  Directory notes,
  String dirName,
  String section,
  SetupOptions options,
) async {
  final results = <_Result>[];
  for (final file in guideFiles(dir: dirName)) {
    results.add(
      await _writeGenerated(
        File('${notes.path}/${file.path}'),
        file.content,
        '$dirName/${file.path}',
        refresh: options.refresh,
      ),
    );
  }
  await File('${notes.path}/agent-instructions.md').writeAsString(section);
  results.add(_Result(_Action.wrote, '$dirName/agent-instructions.md'));
  final (mcp, problem) = await _mergeMcp(
    File('${notes.path}/mcp.json'),
    '$dirName/mcp.json',
    'mcpServers',
    mcpServerEntry(options.port),
    refresh: options.refresh,
  );
  return ([...results, mcp], [?problem]);
}

/// The copies for each agent: skill, commands, rule, MCP files and the
/// section in the agent file.
Future<_Step> _writeCopies(
  Directory project,
  String dirName,
  String section,
  SetupOptions options,
) async {
  final results = <_Result>[];
  final problems = <String>[];
  for (final copy in guideCopies(options.agents, dir: dirName)) {
    results.add(
      await _writeGenerated(
        File('${project.path}/${copy.path}'),
        copy.content,
        copy.path,
        refresh: options.refresh,
      ),
    );
  }
  for (final mcp in mcpFiles(options.agents, options.port)) {
    final (result, problem) = await _mergeMcp(
      File('${project.path}/${mcp.path}'),
      mcp.path,
      mcp.serversKey,
      mcp.entry,
      refresh: options.refresh,
    );
    results.add(result);
    if (problem != null) problems.add(problem);
  }
  if (_agentFile(project, options.agents) case final file?) {
    results.add(await _addSection(file, section));
  }
  return (results, problems);
}

/// What `setup` prints without `--write`: the section, how to connect, and
/// what `--write` would add.
List<String> _preview(
  SetupOptions options,
  Directory project,
  String dirName,
  String section,
) {
  final agentFile = _agentFile(project, options.agents);
  final url = mcpServerEntry(options.port)['url']! as String;
  return [
    if (agentFile != null) ...[
      'Add this section to ${agentFile.uri.pathSegments.last}:',
      '',
      section,
    ],
    'Connect the agent to the bridge (run `dart run pinpoint:bridge` first).',
    if (options.agents.contains(AgentKind.claude)) ...[
      'Claude Code:',
      '  claude mcp add --transport http pinpoint $url',
    ],
    "or merge $dirName/mcp.json into your agent's MCP file.",
    '',
    hotReloadHint(dirName),
    '',
    'Run again with --write to copy the guide to where each agent looks '
        '(${_agentNames(options)}):',
    for (final copy in guideCopies(options.agents, dir: dirName))
      '  ${copy.path}',
    for (final mcp in mcpFiles(options.agents, options.port)) '  ${mcp.path}',
    if (agentFile != null) '  ${agentFile.uri.pathSegments.last}',
  ];
}

/// The file that gets the agent section: `CLAUDE.md` for Claude Code,
/// `AGENTS.md` for the generic agents; null when neither is chosen.
File? _agentFile(Directory project, Set<AgentKind> agents) {
  final claudeMd = File('${project.path}/CLAUDE.md');
  final agentsMd = File('${project.path}/AGENTS.md');
  return switch ((
    agents.contains(AgentKind.claude),
    agents.contains(AgentKind.agents),
  )) {
    (true, true) =>
      claudeMd.existsSync() || !agentsMd.existsSync() ? claudeMd : agentsMd,
    (true, false) => claudeMd,
    (false, true) => agentsMd,
    (false, false) => null,
  };
}

/// Appends [section] to [file] unless its heading is there.
Future<_Result> _addSection(File file, String section) async {
  final name = file.uri.pathSegments.last;
  final existing = file.existsSync() ? await file.readAsString() : '';
  if (existing.contains(agentSectionHeading)) {
    return _Result(
      _Action.unchanged,
      name,
      'it already has "$agentSectionHeading"',
    );
  }
  await file.writeAsString('$existing${_gap(existing)}$section');
  return _Result(_Action.added, name, 'the "$agentSectionHeading" section');
}

/// What goes between [text] and a section appended to it.
String _gap(String text) => switch (text) {
  '' => '',
  _ when text.endsWith('\n\n') => '',
  _ when text.endsWith('\n') => '\n',
  _ => '\n\n',
};

/// Writes [content] to [file] when it is missing; keeps a file that differs
/// unless [refresh].
Future<_Result> _writeGenerated(
  File file,
  String content,
  String label, {
  required bool refresh,
}) async {
  if (!file.existsSync()) {
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return _Result(_Action.wrote, label);
  }
  final existing = await file.readAsString();
  if (existing == content) return _Result(_Action.unchanged, label);
  if (refresh) {
    await file.writeAsString(content);
    return _Result(_Action.updated, label);
  }
  return _Result(_Action.kept, label, switch (guideVersionOf(existing)) {
    final was? when guideIsOlder(was) => 'from $was, not $pinpointVersion',
    _ => 'it differs from the generated text',
  });
}

/// The JSON object in [file] (empty when there is no file), or the reason
/// it cannot be used.
Future<({Map<String, Object?>? json, String? error})> _readJsonObject(
  File file,
  String label,
) async {
  if (!file.existsSync()) return (json: <String, Object?>{}, error: null);
  try {
    return switch (jsonDecode(await file.readAsString())) {
      final Map<String, Object?> json => (json: json, error: null),
      _ => (json: null, error: '$label is not a JSON object.'),
    };
  } on FormatException catch (error) {
    return (
      json: null,
      error:
          '$label is not valid JSON (${error.message}). Fix it, then run '
          'setup again, or add the pinpoint server by hand.',
    );
  }
}

/// Adds `pinpoint` to the servers of the JSON [file] (under [key]) and
/// keeps everything else. A file it cannot use is not touched; the second
/// value says why.
Future<(_Result, String?)> _mergeMcp(
  File file,
  String label,
  String key,
  Map<String, Object?> entry, {
  required bool refresh,
}) async {
  final existed = file.existsSync();
  final (:json, :error) = await _readJsonObject(file, label);
  if (json == null) return (_Result(_Action.skipped, label, 'unusable'), error);
  final servers = json[key];
  if (servers != null && servers is! Map<String, Object?>) {
    return (
      _Result(_Action.skipped, label, '"$key" is not an object'),
      '$label: "$key" is not an object.',
    );
  }
  final merged = <String, Object?>{...?servers as Map<String, Object?>?};
  final had = merged.containsKey('pinpoint');
  if (had && jsonEncode(merged['pinpoint']) == jsonEncode(entry)) {
    return (_Result(_Action.unchanged, label, 'has the pinpoint server'), null);
  }
  if (had && !refresh) {
    final differs =
        'its pinpoint server differs: ${jsonEncode(merged['pinpoint'])}';
    return (_Result(_Action.kept, label, differs), null);
  }
  merged['pinpoint'] = entry;
  json[key] = merged;
  await file.parent.create(recursive: true);
  await file.writeAsString(_pretty(json));
  final others = merged.keys.where((k) => k != 'pinpoint');
  return (
    _Result(
      had
          ? _Action.updated
          : existed
          ? _Action.merged
          : _Action.wrote,
      label,
      '${had ? 'pinpoint server updated' : 'pinpoint server added'}'
      '${others.isEmpty ? '' : '; kept ${others.join(', ')}'}',
    ),
    null,
  );
}

String _pretty(Object? json) =>
    '${const JsonEncoder.withIndent('  ').convert(json)}\n';

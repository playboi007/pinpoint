// Plain Dart with `dart:io`: `dart run pinpoint:setup` runs this. No `args`
// package, so setup adds no dependency.

import 'dart:convert';
import 'dart:io';

import 'agent_instructions.dart';
import 'bridge_protocol.dart';

/// How to run `dart run pinpoint:setup`.
const String setupUsage =
    '''
Usage: dart run pinpoint:setup [options]

Writes the agent instructions and an example MCP config into <dir>/, and
prints what to add where. Edits your agent files only with --write.

Options:
  --dir <path>      Folder for the notes (default .pinpoint).
  --port <n>        The bridge's port (default $defaultBridgePort).
  --write           Also add the section to CLAUDE.md (or AGENTS.md) and the
                    pinpoint server to .mcp.json in this folder.
  -h, --help        Show this text.
''';

/// The setup's flags.
class SetupOptions {
  const SetupOptions({
    this.dir = '.pinpoint',
    this.port = defaultBridgePort,
    this.write = false,
    this.help = false,
  });

  final String dir;
  final int port;

  /// Edit the agent files, not only print what to add.
  final bool write;

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
      case '--write' when equals < 0:
        write = true;
      case '-h' || '--help' when equals < 0:
        help = true;
      default:
        throw FormatException('Unknown option: $arg');
    }
  }
  return SetupOptions(dir: dir, port: port, write: write, help: help);
}

/// The MCP server entry for the bridge on [port], as `.mcp.json` holds it.
Map<String, Object?> mcpServerEntry(int port) => {
  'type': 'http',
  'url': 'http://127.0.0.1:$port$mcpPath',
};

/// Runs the setup in [project] (the app's folder) and returns what to
/// print, line by line.
///
/// Always writes `<dir>/agent-instructions.md` and `<dir>/mcp.json`. With
/// [SetupOptions.write], also appends the agent section to `CLAUDE.md`
/// (or `AGENTS.md` when only that exists), unless its heading is there,
/// and adds the `pinpoint` server to `.mcp.json`, keeping every other
/// server. Throws a [SetupException] for a `.mcp.json` it cannot read;
/// that file is then left as it is.
Future<List<String>> runSetup(SetupOptions options, Directory project) async {
  final out = <String>[];
  final notes = Directory(
    Directory(options.dir).isAbsolute
        ? options.dir
        : '${project.path}/${options.dir}',
  );
  await notes.create(recursive: true);
  final ignore = File('${notes.path}/.gitignore');
  if (!ignore.existsSync()) await ignore.writeAsString('*\n');

  final dirName = notes.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  final section = agentInstructions(dir: dirName);
  final entry = mcpServerEntry(options.port);
  final url = entry['url']! as String;
  final example = _pretty({
    'mcpServers': {'pinpoint': entry},
  });

  await File('${notes.path}/agent-instructions.md').writeAsString(section);
  await File('${notes.path}/mcp.json').writeAsString(example);
  out
    ..add('Wrote ${notes.path}/agent-instructions.md')
    ..add('Wrote ${notes.path}/mcp.json');

  final claude = File('${project.path}/CLAUDE.md');
  final agents = File('${project.path}/AGENTS.md');
  final agentFile = claude.existsSync() || !agents.existsSync()
      ? claude
      : agents;
  final mcpFile = File('${project.path}/.mcp.json');

  if (!options.write) {
    out
      ..add('')
      ..add('Add this section to ${agentFile.path}:')
      ..add('')
      ..add(section)
      ..add('Connect the agent to the bridge (run `dart run pinpoint:bridge`')
      ..add('first). Claude Code:')
      ..add('  claude mcp add --transport http pinpoint $url')
      ..add('or merge ${notes.path}/mcp.json into ${mcpFile.path}.')
      ..add('')
      ..add('Run again with --write to make both edits.');
    return out;
  }

  // The agent file: append the section once.
  final existing = agentFile.existsSync() ? await agentFile.readAsString() : '';
  if (existing.contains(agentSectionHeading)) {
    out.add('${agentFile.path} already has "$agentSectionHeading".');
  } else {
    final gap = existing.isEmpty
        ? ''
        : existing.endsWith('\n\n')
        ? ''
        : existing.endsWith('\n')
        ? '\n'
        : '\n\n';
    await agentFile.writeAsString('$existing$gap$section');
    out.add('Added "$agentSectionHeading" to ${agentFile.path}.');
  }

  // .mcp.json: add or replace the pinpoint server, keep the others.
  var config = <String, Object?>{};
  if (mcpFile.existsSync()) {
    final Object? decoded;
    try {
      decoded = jsonDecode(await mcpFile.readAsString());
    } on FormatException catch (error) {
      throw SetupException(
        '${mcpFile.path} is not valid JSON (${error.message}); left it as '
        'it is. Fix it, or add the server with: '
        'claude mcp add --transport http pinpoint $url',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw SetupException('${mcpFile.path} is not a JSON object; left it.');
    }
    config = decoded;
  }
  final servers = config['mcpServers'];
  if (servers != null && servers is! Map<String, Object?>) {
    throw SetupException(
      '${mcpFile.path}: "mcpServers" is not an object; left it.',
    );
  }
  final merged = <String, Object?>{...?servers as Map<String, Object?>?};
  if (jsonEncode(merged['pinpoint']) == jsonEncode(entry)) {
    out.add('${mcpFile.path} already has the pinpoint server.');
  } else {
    merged['pinpoint'] = entry;
    config['mcpServers'] = merged;
    await mcpFile.writeAsString(_pretty(config));
    out.add('Added the pinpoint server ($url) to ${mcpFile.path}.');
  }
  out.add('Start the bridge with `dart run pinpoint:bridge`.');
  return out;
}

String _pretty(Object? json) =>
    '${const JsonEncoder.withIndent('  ').convert(json)}\n';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/agent_instructions.dart';
import 'package:pinpoint/src/bridge/setup.dart';

/// Milestone 8, build step 4 (last part): `dart run pinpoint:setup` writes
/// the instructions and an example MCP config, and edits the agent's files
/// only with --write.
void main() {
  late Directory project;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('pinpoint_setup_');
  });
  tearDown(() => project.delete(recursive: true));

  File file(String name) => File('${project.path}/$name');
  Map<String, Object?> json(String name) =>
      jsonDecode(file(name).readAsStringSync()) as Map<String, Object?>;

  test('flags', () {
    final options = parseSetupArgs([
      '--dir',
      'notes',
      '--port=4800',
      '--write',
    ]);
    expect(options.dir, 'notes');
    expect(options.port, 4800);
    expect(options.write, isTrue);
    expect(() => parseSetupArgs(['--port', '0']), throwsFormatException);
    expect(() => parseSetupArgs(['--force']), throwsFormatException);
    for (final flag in ['--dir', '--port', '--write', '--help']) {
      expect(setupUsage, contains(flag));
    }
  });

  test(
    'without --write: writes into .pinpoint/ only and prints the rest',
    () async {
      file('CLAUDE.md').writeAsStringSync('# App\n');
      final out = (await runSetup(const SetupOptions(), project)).join('\n');

      expect(
        file('.pinpoint/agent-instructions.md').readAsStringSync(),
        agentInstructions(),
      );
      expect(json('.pinpoint/mcp.json'), {
        'mcpServers': {
          'pinpoint': {'type': 'http', 'url': 'http://127.0.0.1:4747/mcp'},
        },
      });
      expect(file('.pinpoint/.gitignore').readAsStringSync(), '*\n');
      expect(file('CLAUDE.md').readAsStringSync(), '# App\n');
      expect(file('.mcp.json').existsSync(), isFalse);
      expect(
        out,
        contains(
          'claude mcp add --transport http pinpoint '
          'http://127.0.0.1:4747/mcp',
        ),
      );
      expect(out, contains(agentSectionHeading));
      expect(out, contains('--write'));
    },
  );

  test('--write appends the section once and adds the server, keeping '
      'the others', () async {
    file('CLAUDE.md').writeAsStringSync('# App\nRules.');
    file('.mcp.json').writeAsStringSync(
      jsonEncode({
        'mcpServers': {
          'dart': {
            'command': 'dart',
            'args': ['mcp-server'],
          },
        },
      }),
    );
    const options = SetupOptions(write: true, port: 4800);
    await runSetup(options, project);

    final claude = file('CLAUDE.md').readAsStringSync();
    expect(claude, startsWith('# App\nRules.\n\n$agentSectionHeading'));
    final servers = json('.mcp.json')['mcpServers']! as Map<String, Object?>;
    expect(servers.keys, ['dart', 'pinpoint']);
    expect(servers['pinpoint'], {
      'type': 'http',
      'url': 'http://127.0.0.1:4800/mcp',
    });

    // Again: nothing is added twice.
    final out = (await runSetup(options, project)).join('\n');
    expect(file('CLAUDE.md').readAsStringSync(), claude);
    expect(out, contains('already has'));
  });

  test('--write uses AGENTS.md when only that exists, else creates '
      'CLAUDE.md', () async {
    file('AGENTS.md').writeAsStringSync('# Agents\n');
    await runSetup(const SetupOptions(write: true), project);
    expect(file('AGENTS.md').readAsStringSync(), contains(agentSectionHeading));
    expect(file('CLAUDE.md').existsSync(), isFalse);

    file('AGENTS.md').deleteSync();
    await runSetup(const SetupOptions(write: true), project);
    expect(file('CLAUDE.md').readAsStringSync(), agentInstructions());
  });

  test('a .mcp.json it cannot read is left as it is', () async {
    file('.mcp.json').writeAsStringSync('{ not json');
    await expectLater(
      runSetup(const SetupOptions(write: true), project),
      throwsA(isA<SetupException>()),
    );
    expect(file('.mcp.json').readAsStringSync(), '{ not json');
  });
}

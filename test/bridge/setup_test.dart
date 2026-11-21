import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/agent_guide.dart';
import 'package:pinpoint/src/bridge/agent_instructions.dart';
import 'package:pinpoint/src/bridge/package_version.dart';
import 'package:pinpoint/src/bridge/setup.dart';

/// Milestone 8, build step 4 (last part) and Milestone 22: `dart run
/// pinpoint:setup` writes the guide into `.pinpoint/`, and edits the agents'
/// files only with --write.
void main() {
  late Directory project;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('pinpoint_setup_');
  });
  tearDown(() => project.delete(recursive: true));

  File file(String name) => File('${project.path}/$name');
  Map<String, Object?> json(String name) =>
      jsonDecode(file(name).readAsStringSync()) as Map<String, Object?>;
  Map<String, Object?> servers(String name, [String key = 'mcpServers']) =>
      json(name)[key]! as Map<String, Object?>;

  const guide = [
    'README.md',
    'SKILL.md',
    'commands/pinpoint-fix-notes.md',
    'commands/pinpoint-check.md',
    'commands/pinpoint-state.md',
    'tools.md',
  ];
  const copies = [
    '.claude/skills/pinpoint/SKILL.md',
    '.claude/commands/pinpoint-fix-notes.md',
    '.claude/commands/pinpoint-check.md',
    '.claude/commands/pinpoint-state.md',
    '.cursor/rules/pinpoint.mdc',
    '.mcp.json',
    '.cursor/mcp.json',
    '.vscode/mcp.json',
  ];

  test('flags', () {
    final options = parseSetupArgs([
      '--dir',
      'notes',
      '--port=4800',
      '--write',
      '--refresh',
      '--agents',
      'claude, Cursor',
    ]);
    expect(options.dir, 'notes');
    expect(options.port, 4800);
    expect(options.write, isTrue);
    expect(options.refresh, isTrue);
    expect(options.agents, {AgentKind.claude, AgentKind.cursor});
    expect(parseSetupArgs(['--agents=agents']).agents, {AgentKind.agents});
    expect(parseSetupArgs([]).agents, AgentKind.values.toSet());
    expect(parseSetupArgs([]).refresh, isFalse);
    expect(() => parseSetupArgs(['--port', '0']), throwsFormatException);
    expect(() => parseSetupArgs(['--force']), throwsFormatException);
    expect(() => parseSetupArgs(['--agents']), throwsFormatException);
    expect(() => parseSetupArgs(['--agents', 'zed']), throwsFormatException);
    expect(() => parseSetupArgs(['--refresh=1']), throwsFormatException);
    for (final flag in [
      '--dir',
      '--port',
      '--write',
      '--refresh',
      '--agents',
      '--help',
      'claude',
      'cursor',
      'vscode',
      'agents',
    ]) {
      expect(setupUsage, contains(flag));
    }
  });

  test(
    'without --write: writes into .pinpoint/ only and prints the rest',
    () async {
      file('CLAUDE.md').writeAsStringSync('# App\n');
      final out = (await runSetup(const SetupOptions(), project)).join('\n');

      for (final name in guide) {
        final text = file('.pinpoint/$name').readAsStringSync();
        expect(
          guideVersionOf(text),
          pinpointVersion,
          reason: '$name has the generated stamp',
        );
      }
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
      for (final path in copies) {
        expect(file(path).existsSync(), isFalse, reason: path);
      }
      expect(
        out,
        contains(
          'claude mcp add --transport http pinpoint http://127.0.0.1:4747/mcp',
        ),
      );
      expect(out, contains(agentSectionHeading));
      expect(out, contains('--write'));
      expect(out, contains('.cursor/rules/pinpoint.mdc'));
      expect(out, contains('wrote     .pinpoint/SKILL.md'));
    },
  );

  test('--write writes every copy for every agent, and the section', () async {
    final out = (await runSetup(
      const SetupOptions(write: true),
      project,
    )).join('\n');

    for (final path in copies) {
      expect(file(path).existsSync(), isTrue, reason: path);
      expect(out, contains(path));
    }
    // Copies, not links, and equal to what the guide renders.
    for (final copy in guideCopies(AgentKind.values.toSet())) {
      expect(
        FileSystemEntity.isLinkSync('${project.path}/${copy.path}'),
        isFalse,
      );
      expect(file(copy.path).readAsStringSync(), copy.content);
      expect(
        guideVersionOf(file(copy.path).readAsStringSync()),
        pinpointVersion,
      );
    }
    expect(
      file('.cursor/rules/pinpoint.mdc').readAsStringSync(),
      contains('alwaysApply: false'),
    );
    // MCP files, each in the agent's own form.
    expect(servers('.mcp.json')['pinpoint'], {
      'type': 'http',
      'url': 'http://127.0.0.1:4747/mcp',
    });
    expect(servers('.cursor/mcp.json')['pinpoint'], {
      'url': 'http://127.0.0.1:4747/mcp',
    });
    expect(servers('.vscode/mcp.json', 'servers')['pinpoint'], {
      'type': 'http',
      'url': 'http://127.0.0.1:4747/mcp',
    });
    expect(file('CLAUDE.md').readAsStringSync(), agentInstructions());
    expect(file('AGENTS.md').existsSync(), isFalse);
    expect(out, contains('Claude Code, Cursor, VS Code, AGENTS.md'));
  });

  test('--agents limits the copies', () async {
    await runSetup(
      SetupOptions(write: true, agents: {AgentKind.cursor}),
      project,
    );
    expect(file('.cursor/rules/pinpoint.mdc').existsSync(), isTrue);
    expect(file('.cursor/mcp.json').existsSync(), isTrue);
    for (final path in [
      '.claude/skills/pinpoint/SKILL.md',
      '.claude/commands/pinpoint-check.md',
      '.mcp.json',
      '.vscode/mcp.json',
      'CLAUDE.md',
      'AGENTS.md',
    ]) {
      expect(file(path).existsSync(), isFalse, reason: path);
    }
    // The guide in .pinpoint/ is always written.
    expect(file('.pinpoint/SKILL.md').existsSync(), isTrue);
  });

  test('--agents vscode writes only .vscode/mcp.json', () async {
    await runSetup(
      SetupOptions(write: true, agents: {AgentKind.vscode}),
      project,
    );
    expect(file('.vscode/mcp.json').existsSync(), isTrue);
    expect(file('.cursor').existsSync(), isFalse);
    expect(file('.claude').existsSync(), isFalse);
    expect(file('CLAUDE.md').existsSync(), isFalse);
  });

  test(
    '--agents claude uses CLAUDE.md; --agents agents uses AGENTS.md',
    () async {
      await runSetup(
        SetupOptions(write: true, agents: {AgentKind.claude}),
        project,
      );
      expect(
        file('CLAUDE.md').readAsStringSync(),
        contains(agentSectionHeading),
      );
      expect(file('AGENTS.md').existsSync(), isFalse);
      file('CLAUDE.md').deleteSync();
      file('.mcp.json').deleteSync();

      await runSetup(
        SetupOptions(write: true, agents: {AgentKind.agents}),
        project,
      );
      expect(
        file('AGENTS.md').readAsStringSync(),
        contains(agentSectionHeading),
      );
      expect(file('CLAUDE.md').existsSync(), isFalse);
      expect(file('.mcp.json').existsSync(), isFalse);
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
    expect(servers('.mcp.json').keys, ['dart', 'pinpoint']);
    expect(servers('.mcp.json')['pinpoint'], {
      'type': 'http',
      'url': 'http://127.0.0.1:4800/mcp',
    });
    // Pretty, 2 spaces, newline at the end.
    expect(
      file('.mcp.json').readAsStringSync(),
      startsWith('{\n  "mcpServers": {\n    "dart": {'),
    );
    expect(file('.mcp.json').readAsStringSync(), endsWith('}\n'));

    // Again: nothing is added twice.
    final out = (await runSetup(options, project)).join('\n');
    expect(file('CLAUDE.md').readAsStringSync(), claude);
    expect(out, contains('already has'));
    expect(out, contains('unchanged'));
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

  group('MCP files are merged', () {
    const others = {
      'mcpServers': {
        'dart': {'command': 'dart'},
      },
      'other': 1,
    };

    test('each file keeps its other servers and keys', () async {
      for (final (path, key) in [
        ('.mcp.json', 'mcpServers'),
        ('.cursor/mcp.json', 'mcpServers'),
        ('.vscode/mcp.json', 'servers'),
      ]) {
        file(path).parent.createSync(recursive: true);
        file(path).writeAsStringSync(
          jsonEncode({
            key: {
              'dart': {'command': 'dart'},
            },
            'other': 1,
            'inputs': <Object?>[],
          }),
        );
      }
      await runSetup(const SetupOptions(write: true), project);
      for (final (path, key) in [
        ('.mcp.json', 'mcpServers'),
        ('.cursor/mcp.json', 'mcpServers'),
        ('.vscode/mcp.json', 'servers'),
      ]) {
        expect(json(path)['other'], 1, reason: path);
        expect(json(path)['inputs'], isEmpty, reason: path);
        expect(servers(path, key).keys, ['dart', 'pinpoint'], reason: path);
      }
    });

    test('an existing pinpoint entry is kept without --refresh', () async {
      file('.mcp.json').writeAsStringSync(
        jsonEncode({
          ...others,
          'mcpServers': {
            'pinpoint': {'type': 'http', 'url': 'http://127.0.0.1:9999/mcp'},
          },
        }),
      );
      final out = (await runSetup(
        const SetupOptions(write: true),
        project,
      )).join('\n');
      expect(servers('.mcp.json')['pinpoint'], {
        'type': 'http',
        'url': 'http://127.0.0.1:9999/mcp',
      });
      expect(out, contains('kept      .mcp.json'));
      expect(out, contains('--refresh'));
    });

    test('and replaced with --refresh', () async {
      file('.mcp.json').writeAsStringSync(
        jsonEncode({
          'mcpServers': {
            'dart': {'command': 'dart'},
            'pinpoint': {'type': 'http', 'url': 'http://127.0.0.1:9999/mcp'},
          },
        }),
      );
      final out = (await runSetup(
        const SetupOptions(write: true, refresh: true),
        project,
      )).join('\n');
      expect(servers('.mcp.json').keys, ['dart', 'pinpoint']);
      expect(servers('.mcp.json')['pinpoint'], {
        'type': 'http',
        'url': 'http://127.0.0.1:4747/mcp',
      });
      expect(out, contains('updated   .mcp.json'));
    });

    test(
      'a file that is not valid JSON is not touched; the rest goes on',
      () async {
        file('.mcp.json').writeAsStringSync('{ not json');
        file('.cursor').createSync();
        file('.cursor').deleteSync();
        file('.vscode').createSync();
        file('.vscode').deleteSync();
        file('.vscode/mcp.json')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('[1, 2]');
        Object? error;
        try {
          await runSetup(const SetupOptions(write: true), project);
        } on SetupException catch (e) {
          error = e;
        }
        expect(error, isA<SetupException>());
        final message = '$error';
        expect(message, contains('.mcp.json is not valid JSON'));
        expect(message, contains('.vscode/mcp.json is not a JSON object'));
        expect(file('.mcp.json').readAsStringSync(), '{ not json');
        expect(file('.vscode/mcp.json').readAsStringSync(), '[1, 2]');
        // The others were written.
        expect(file('.cursor/mcp.json').existsSync(), isTrue);
        expect(file('.claude/skills/pinpoint/SKILL.md').existsSync(), isTrue);
        expect(
          file('CLAUDE.md').readAsStringSync(),
          contains(agentSectionHeading),
        );
      },
    );

    test('"mcpServers" that is not an object is left alone', () async {
      file('.mcp.json').writeAsStringSync('{"mcpServers": []}');
      await expectLater(
        runSetup(const SetupOptions(write: true), project),
        throwsA(isA<SetupException>()),
      );
      expect(file('.mcp.json').readAsStringSync(), '{"mcpServers": []}');
    });
  });

  group('existing generated files', () {
    test('an edited copy is not overwritten without --refresh', () async {
      await runSetup(const SetupOptions(write: true), project);
      for (final path in [
        '.claude/skills/pinpoint/SKILL.md',
        '.claude/commands/pinpoint-check.md',
        '.cursor/rules/pinpoint.mdc',
        '.pinpoint/SKILL.md',
      ]) {
        file(
          path,
        ).writeAsStringSync('${file(path).readAsStringSync()}\nMy rule.\n');
      }
      final out = (await runSetup(
        const SetupOptions(write: true),
        project,
      )).join('\n');
      for (final path in [
        '.claude/skills/pinpoint/SKILL.md',
        '.claude/commands/pinpoint-check.md',
        '.cursor/rules/pinpoint.mdc',
        '.pinpoint/SKILL.md',
      ]) {
        expect(
          file(path).readAsStringSync(),
          endsWith('My rule.\n'),
          reason: path,
        );
        expect(out, contains('kept      $path'));
      }
      expect(out, contains('--refresh'));

      // An untouched copy is "unchanged", not rewritten.
      expect(out, contains('unchanged .claude/commands/pinpoint-state.md'));
    });

    test('--refresh rewrites them', () async {
      await runSetup(const SetupOptions(write: true), project);
      file('.claude/skills/pinpoint/SKILL.md').writeAsStringSync('mine');
      file('.pinpoint/tools.md').writeAsStringSync('mine');
      final out = (await runSetup(
        const SetupOptions(write: true, refresh: true),
        project,
      )).join('\n');
      expect(
        file('.claude/skills/pinpoint/SKILL.md').readAsStringSync(),
        renderSkill(source: '.pinpoint/SKILL.md'),
      );
      expect(file('.pinpoint/tools.md').readAsStringSync(), renderToolsDoc());
      expect(out, contains('updated   .claude/skills/pinpoint/SKILL.md'));
      expect(out, isNot(contains('kept')));
    });

    test('a file from an older version says so', () async {
      await runSetup(const SetupOptions(), project);
      final skill = file('.pinpoint/SKILL.md');
      skill.writeAsStringSync(
        skill.readAsStringSync().replaceFirst(
          'setup` $pinpointVersion;',
          'setup` 0.0.0;',
        ),
      );
      final out = (await runSetup(const SetupOptions(), project)).join('\n');
      expect(
        out,
        contains(
          'kept      .pinpoint/SKILL.md (from 0.0.0, not $pinpointVersion)',
        ),
      );
    });
  });

  test('--dir names the folder in the guide', () async {
    await runSetup(const SetupOptions(dir: 'notes'), project);
    expect(
      file('notes/SKILL.md').readAsStringSync(),
      contains('`notes/tools.md`'),
    );
    expect(
      file('notes/commands/pinpoint-check.md').readAsStringSync(),
      contains('notes/config.json'),
    );
    expect(file('.pinpoint').existsSync(), isFalse);
  });

  test('.gitignore stays "*" and is not rewritten', () async {
    file('.pinpoint/.gitignore')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('custom\n');
    await runSetup(const SetupOptions(refresh: true), project);
    expect(file('.pinpoint/.gitignore').readAsStringSync(), 'custom\n');
    expect(renderGuideReadme(), contains('`*`'));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/agent_instructions.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';

/// Milestone 7, build step 3 (last part): the section that tells a coding
/// agent how to work the notes.
void main() {
  late Directory project;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('pinpoint_project_');
  });
  tearDown(() => project.delete(recursive: true));

  Future<List<String>> startOnce() async {
    final log = <String>[];
    final bridge = await PinPointBridge.start(
      dir: '${project.path}/.pinpoint',
      port: 0,
      log: log.add,
    );
    await bridge.close();
    return log;
  }

  test('the section names the folder, the steps and where notes go after', () {
    final text = agentInstructions();
    expect(text, startsWith('## Pinpoint notes\n'));
    for (final part in [
      '.pinpoint/open/*.md',
      'work the pinpoint notes',
      'Source',
      'PNG',
      'flutter analyze',
      '.pinpoint/resolved/',
    ]) {
      expect(text, contains(part));
    }
    expect(agentInstructions(dir: 'notes'), contains('notes/open/*.md'));
  });

  test('the bridge prints the section when no agent file has it', () async {
    final log = await startOnce();
    expect(log.join('\n'), contains(agentInstructions()));
    expect(log.join('\n'), contains('CLAUDE.md'));
  });

  test('and stays quiet once CLAUDE.md or AGENTS.md has it', () async {
    for (final name in ['CLAUDE.md', 'AGENTS.md']) {
      final file = File('${project.path}/$name')
        ..writeAsStringSync('# App\n\n${agentInstructions()}');
      final log = await startOnce();
      expect(
        log.join('\n'),
        isNot(contains('## Pinpoint notes')),
        reason: name,
      );
      file.deleteSync();
    }
  });

  test('the bridge never edits the agent file', () async {
    final file = File('${project.path}/CLAUDE.md')
      ..writeAsStringSync('# App\n');
    await startOnce();
    expect(file.readAsStringSync(), '# App\n');
  });
}

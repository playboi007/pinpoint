import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/agent_guide.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/bridge/package_version.dart';
import 'package:pinpoint/src/model/annotation.dart' show annotationSchema;

/// `.pinpoint/config.json` (the bridge's live status) and the stale-guide
/// line. Plain `test`: `testWidgets` replaces `HttpClient`.
void main() {
  late Directory project;
  late String dir;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('pinpoint_config_');
    dir = '${project.path}/.pinpoint';
  });
  tearDown(() => project.delete(recursive: true));

  File configFile() => File('$dir/config.json');
  Map<String, Object?> config() =>
      jsonDecode(configFile().readAsStringSync()) as Map<String, Object?>;

  test('the bridge writes config.json at start and stopped at close', () async {
    final before = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    final bridge = await PinPointBridge.start(dir: dir, port: 0);
    final running = config();

    expect(running['status'], 'running');
    expect(running['version'], pinpointVersion);
    expect(running['noteSchema'], annotationSchema);
    expect(running['port'], bridge.port);
    expect(running['pid'], pid);
    expect(running['root'], Directory(project.path).absolute.path);
    expect(running['stoppedAt'], isNull);
    expect(
      DateTime.parse(running['startedAt']! as String).isAfter(before),
      isTrue,
    );
    expect(running['endpoints'], {
      'mcp': 'http://127.0.0.1:${bridge.port}/mcp',
      'health': 'http://127.0.0.1:${bridge.port}/health',
    });

    await bridge.close();
    final stopped = config();
    expect(stopped['status'], 'stopped');
    expect(stopped['stoppedAt'], isA<String>());
    expect(DateTime.tryParse(stopped['stoppedAt']! as String), isNotNull);
    // The rest stays, so a reader still learns the last port and version.
    expect(stopped['port'], running['port']);
    expect(stopped['startedAt'], running['startedAt']);
    expect(stopped['version'], pinpointVersion);
    // No half-written temporary file stays behind.
    expect(File('$dir/.config.json.tmp').existsSync(), isFalse);
  });

  test('it is valid JSON, pretty, and the endpoints answer', () async {
    final bridge = await PinPointBridge.start(dir: dir, port: 0);
    addTearDown(bridge.close);
    expect(
      configFile().readAsStringSync(),
      startsWith('{\n  "name": "pinpoint"'),
    );
    final health = (config()['endpoints']! as Map<String, Object?>)['health'];
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$health'));
      final response = await request.close();
      expect(response.statusCode, 200);
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  test('a later bridge in the same folder keeps its own config', () async {
    final first = await PinPointBridge.start(dir: dir, port: 0);
    final second = await PinPointBridge.start(dir: dir, port: 0);
    addTearDown(second.close);
    expect(config()['port'], second.port);

    // The first stops: the file is the second's, so it is left as it is.
    await first.close();
    expect(config()['status'], 'running');
    expect(config()['port'], second.port);
  });

  test('closing after the folder is gone does not throw', () async {
    final bridge = await PinPointBridge.start(dir: dir, port: 0);
    await Directory(dir).delete(recursive: true);
    await bridge.close();
  });

  group('stale guide', () {
    Future<List<String>> startOnce() async {
      final log = <String>[];
      final bridge = await PinPointBridge.start(
        dir: dir,
        port: 0,
        log: log.add,
      );
      await bridge.close();
      return log;
    }

    void writeSkill(String text) => File('$dir/SKILL.md')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);

    test('an older stamp gets one line', () async {
      writeSkill(
        renderSkill().replaceFirst('setup` $pinpointVersion;', 'setup` 0.0.0;'),
      );
      final log = await startOnce();
      expect(log.where((l) => l.contains('agent guide files')).toList(), [
        'pinpoint: agent guide files are from 0.0.0; '
            'run dart run pinpoint:setup --refresh',
      ]);
    });

    test(
      'a current guide, no guide and a hand-written file say nothing',
      () async {
        expect((await startOnce()).join('\n'), isNot(contains('agent guide')));
        writeSkill(renderSkill());
        expect((await startOnce()).join('\n'), isNot(contains('agent guide')));
        writeSkill('# my own skill\n');
        expect((await startOnce()).join('\n'), isNot(contains('agent guide')));
      },
    );
  });
}

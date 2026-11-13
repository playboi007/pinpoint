import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_options.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/model/annotation.dart' show NoteStatus;
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';

/// `--ttl`: notes, screenshots, tapes and replay runs do not live forever.
/// Age is the time since a file's last change; the test sets file times
/// back instead of waiting.
///
/// Plain `test`: the widget binding fakes `HttpClient`.
void main() {
  late Directory root;
  late PinPointBridge bridge;
  var started = false;

  String dir(String folder) => '${root.path}/.pinpoint/$folder';

  Map<String, Object?> note(String id, String status) {
    final json = jsonDecode(
      File('test/fixtures/note.json').readAsStringSync(),
    ) as Map<String, Object?>;
    return {...json, 'id': id, 'status': status};
  }

  /// Makes every file of [prefix] in [folder] [age] old.
  void age(String folder, String prefix, Duration age) {
    final at = DateTime.now().subtract(age);
    for (final entry in Directory(dir(folder)).listSync()) {
      if (entry is File && entry.uri.pathSegments.last.startsWith(prefix)) {
        entry.setLastModifiedSync(at);
      }
    }
  }

  Set<String> filesIn(String folder) => {
    for (final f in Directory(dir(folder)).listSync())
      f.path.split(Platform.pathSeparator).last,
  };

  Future<void> start({Duration? ttl}) async {
    root = await Directory.systemTemp.createTemp('pinpoint_ttl_');
    bridge = await PinPointBridge.start(
      dir: '${root.path}/.pinpoint',
      port: 0,
      ttl: ttl,
    );
    started = true;
  }

  tearDown(() async {
    if (!started) return;
    started = false;
    await bridge.close();
    await root.delete(recursive: true);
  });

  Future<void> fill() async {
    final png = Uint8List.fromList(const [137, 80, 78, 71]);
    await bridge.store.save(note('pp_20261101_000000_old1', 'submitted'), png);
    await bridge.store.save(note('pp_20261101_000000_old2', 'draft'), png);
    await bridge.store.save(note('pp_20261101_000000_new1', 'submitted'), png);
    for (final id in ['tp_old_0000', 'tp_new_0000']) {
      await bridge.tapes.save(
        Tape(
          id: id,
          kind: TapeKind.full,
          start: const TapeStart(t: 0, seq: 1, wallTime: 'w'),
          bodies: {0: Uint8List.fromList(utf8.encode('{}'))},
        ).toJson(),
        {'0': base64Encode(utf8.encode('{}'))},
      );
    }
    await bridge.runs.setStatus('run_old_0001', {'state': 'done'});
    await bridge.runs.addEvents('run_old_0001', const []);
    await bridge.runs.setStatus('run_new_0001', {'state': 'done'});

    const old = Duration(hours: 25);
    age('open', 'pp_20261101_000000_old1', old);
    age('drafts', 'pp_20261101_000000_old2', old);
    age('tapes', 'tp_old_0000', old);
    age('runs', 'run_old_0001', old);
  }

  test('with --ttl 24h, what is older goes: notes in every folder with '
      'their screenshots, tapes with their bodies, and runs', () async {
    await start(ttl: const Duration(hours: 24));
    await fill();
    final app = BridgeClient(Uri.parse('http://127.0.0.1:${bridge.port}'));
    final cursor = (await app.load()).cursor;

    expect(await bridge.expire(), {'notes': 2, 'tapes': 1, 'runs': 1});

    expect(filesIn('open'), {
      'pp_20261101_000000_new1.json',
      'pp_20261101_000000_new1.md',
      'pp_20261101_000000_new1.png',
    });
    expect(filesIn('drafts'), isEmpty);
    expect(filesIn('tapes'), {'tp_new_0000.json', 'tp_new_0000'});
    expect(filesIn('runs'), {'run_new_0001.json'});
    // The app hears of each, so the pins go too.
    final changes = await app.changes(cursor);
    expect(changes.deleted.toSet(), {
      'pp_20261101_000000_old1',
      'pp_20261101_000000_old2',
    });
    // Nothing left to delete.
    expect(await bridge.expire(), {'notes': 0, 'tapes': 0, 'runs': 0});
  });

  test('a note changed recently stays, whenever it was made', () async {
    await start(ttl: const Duration(hours: 24));
    await fill();
    await bridge.store.update(
      'pp_20261101_000000_old1',
      status: NoteStatus.inProgress,
      from: 'agent',
      message: 'Looking at it.',
    );
    await bridge.expire();
    expect(filesIn('open'), contains('pp_20261101_000000_old1.json'));
  });

  test('without --ttl nothing is deleted', () async {
    await start();
    await fill();
    expect(await bridge.expire(), isEmpty);
    expect(filesIn('drafts'), hasLength(2));
    expect(filesIn('tapes'), hasLength(4));
  });

  group('--ttl', () {
    test('takes minutes, hours and days', () {
      expect(parseBridgeArgs(const ['--ttl', '24h']).ttl, Duration(hours: 24));
      expect(parseBridgeArgs(const ['--ttl=30m']).ttl, Duration(minutes: 30));
      expect(parseBridgeArgs(const ['--ttl', '7d']).ttl, Duration(days: 7));
      expect(parseBridgeArgs(const []).ttl, isNull);
    });

    test('refuses other forms and zero', () {
      for (final bad in ['24', '1w', '-1h', '0h', 'h']) {
        expect(
          () => parseBridgeArgs(['--ttl', bad]),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });
}

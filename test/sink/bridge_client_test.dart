import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';

/// Milestone 8, build step 3 (second part): the app's bridge client against
/// a real bridge over loopback.
///
/// Plain `test`, never `testWidgets`: the widget binding replaces
/// `HttpClient` with one that answers 400 to everything.
void main() {
  late Directory root;
  late PinPointBridge bridge;
  late BridgeClient client;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_client_');
    bridge = await PinPointBridge.start(dir: '${root.path}/.pinpoint', port: 0);
    client = BridgeClient(Uri.parse('http://127.0.0.1:${bridge.port}'));
  });

  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  Annotation note(String id, {NoteStatus status = NoteStatus.draft}) =>
      Annotation(
        id: id,
        createdAt: DateTime.utc(2026, 11, 10, 14),
        intent: AnnotationIntent.bug,
        comment: 'Fix $id',
        app: const AppInfo(
          buildMode: 'debug',
          platform: 'web',
          origin: 'http://localhost:5000',
        ),
        page: const PageInfo(),
        target: const TargetInfo(widget: 'Text', sourceUnavailable: true),
        anchor: const NoteAnchor(
          file: 'lib/main.dart',
          line: 3,
          widget: 'Text',
        ),
        status: status,
      );

  test('find: the bridge of the first HttpSink.bridge(), or bridgeUrl', () {
    expect(BridgeClient.find(), isNull);
    expect(
      BridgeClient.find(sinks: [HttpSink.bridge(port: 4800)])!.base,
      Uri.parse('http://127.0.0.1:4800'),
    );
    expect(
      BridgeClient.find(
        url: Uri.parse('http://127.0.0.1:4900/'),
        sinks: [HttpSink.bridge(port: 4800)],
      )!.base.port,
      4900,
    );
    expect(
      BridgeClient.find(sinks: [HttpSink(Uri.parse('http://x.test/hook'))]),
      isNull,
      reason: 'a sink that is not a bridge',
    );
  });

  test('save, load, update, changes, delete', () async {
    await client.save(note('pp_a'));
    await client.save(note('pp_b', status: NoteStatus.submitted));
    final loaded = await client.load(origin: 'http://localhost:5000');
    expect([for (final n in loaded.notes) n.id], ['pp_a', 'pp_b']);
    expect(loaded.notes.first.anchor!.line, 3);
    expect((await client.load(origin: 'http://localhost:6000')).notes, isEmpty);

    final updated = await client.update(
      'pp_b',
      status: NoteStatus.resolved,
      message: 'Done',
    );
    expect(updated!.status, NoteStatus.resolved);
    expect(updated.messages.single.from, 'user');

    final changes = await client.changes(loaded.cursor);
    expect([for (final n in changes.notes) n.id], ['pp_b']);
    expect(changes.reset, isFalse);

    await client.delete('pp_a');
    await client.delete('pp_a'); // a second time is fine
    final after = await client.changes(changes.cursor);
    expect(after.deleted, ['pp_a']);
  });

  test('a stopped bridge throws an HttpSinkException', () async {
    await bridge.close();
    await expectLater(client.load(), throwsA(isA<HttpSinkException>()));
  });
}

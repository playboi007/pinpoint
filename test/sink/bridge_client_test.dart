import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/bridge/note_rounds.dart';
import 'package:pinpoint/src/model/note_round.dart';
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

  test('changes: client leaves out the tab\'s own writes, wait holds the '
      'answer', () async {
    final start = (await client.load()).cursor;
    await client.save(note('pp_a'), client: 'tab_a');
    await client.update('pp_a', comment: 'Edited', client: 'tab_a');
    expect((await client.changes(start, client: 'tab_a')).notes, isEmpty);
    expect(
      [
        for (final n in (await client.changes(start, client: 'tab_b')).notes)
          n.id,
      ],
      ['pp_a'],
    );

    // Held: an empty answer after the wait.
    final clock = Stopwatch()..start();
    final held = await client.changes(
      start,
      client: 'tab_a',
      wait: const Duration(seconds: 1),
    );
    expect(held.notes, isEmpty);
    expect(
      clock.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 900)),
    );

    await client.delete('pp_a', client: 'tab_a');
    expect((await client.changes(start, client: 'tab_a')).deleted, isEmpty);
    expect((await client.changes(start)).deleted, ['pp_a']);
  });

  test('undo: with no git the bridge asks the agent, and the answer carries '
      'the note (PLAN-v3 Milestone 20)', () async {
    await client.save(note('pp_a', status: NoteStatus.submitted));
    await client.update('pp_a', status: NoteStatus.inProgress);
    // The agent closes round 1 through MCP-like store calls.
    await bridge.store.update('pp_a', status: NoteStatus.fixed);
    await bridge.store.update(
      'pp_a',
      status: NoteStatus.fixed,
      changes: [
        ChangeLabel('Spacing', ['lib/a.dart']),
      ],
      from: 'agent',
    );
    final fixed = (await client.load()).notes.single;
    final round = fixed.roundViews.single;
    expect(round.isOpen, isFalse);
    expect(round.hasCheckpoints, isFalse);
    expect(round.changes.single.id, 'c1');

    final since = (await client.load()).cursor;
    final result = await client.undo(
      'pp_a',
      round.n,
      ['c1'],
      reason: 'No',
      client: 'tab_a',
    );
    expect(result.undo, 'requested');
    expect(result.isRequested, isTrue);
    expect(result.reverted, isEmpty);
    expect(result.conflicts, isEmpty);
    expect(result.reloaded, isFalse);
    expect(result.note!.status, NoteStatus.submitted);
    expect(result.note!.roundViews.single.isUndone('c1'), isTrue);
    expect(result.note!.roundViews.single.undo, RoundUndo.requested);
    expect(result.note!.messages.last.text, contains('Reason: No'));
    // The writer's own /changes leaves it out; another tab gets it.
    expect((await client.changes(since, client: 'tab_a')).notes, isEmpty);
    expect((await client.changes(since, client: 'tab_b')).notes, hasLength(1));

    // A refusal throws with the status.
    await expectLater(
      client.undo('pp_a', 1, ['c1']),
      throwsA(
        isA<HttpSinkException>().having((e) => e.statusCode, 'status', 409),
      ),
    );
    await expectLater(
      client.undo('pp_none', 1, ['c1']),
      throwsA(
        isA<HttpSinkException>().having((e) => e.statusCode, 'status', 404),
      ),
    );
  });

  test('source and declaration: the app asks the bridge for code', () async {
    File('${root.path}/pubspec.yaml').writeAsStringSync('name: my_app\n');
    Directory('${root.path}/lib').createSync();
    File('${root.path}/lib/model.dart').writeAsStringSync(
      'class Foo {\n'
      '  void go() {\n'
      '    notifyListeners();\n'
      '  }\n'
      '}\n',
    );

    final source = await client.source('package:my_app/model.dart', 3);
    expect(source, isNotNull);
    expect(source!.file, 'lib/model.dart');
    expect((source.start, source.end), (2, 3));
    expect(source.text, '  void go() {\n    notifyListeners();');
    expect(await client.source('lib/none.dart', 1), isNull);
    expect(await client.source('../outside.dart', 1), isNull);

    final found = await client.declaration('Foo<T>');
    expect(found, (file: 'lib/model.dart', line: 1));
    expect(await client.declaration('Nope'), isNull);
  });

  test('a stopped bridge throws an HttpSinkException', () async {
    await bridge.close();
    await expectLater(client.load(), throwsA(isA<HttpSinkException>()));
  });
}

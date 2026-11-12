import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/model/annotation.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';

/// The whole life of a note, end to end through a real bridge: the app's
/// side through [BridgeClient] (the client the app uses), the agent's
/// through MCP over HTTP, and the app's command poll for `verify_note`.
///
/// draft -> sent -> in progress -> fixed and verified -> reopened with a
/// reason -> in progress -> fixed and verified again -> accepted.
///
/// Plain `test`: the widget binding fakes `HttpClient`.
void main() {
  late Directory root;
  late PinPointBridge bridge;
  late BridgeClient app;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pinpoint_lifecycle_');
    bridge = await PinPointBridge.start(dir: '${root.path}/.pinpoint', port: 0);
    app = BridgeClient(Uri.parse('http://127.0.0.1:${bridge.port}'));
  });
  tearDown(() async {
    await bridge.close();
    await root.delete(recursive: true);
  });

  Set<String> filesIn(String folder) => {
    for (final f in Directory('${root.path}/.pinpoint/$folder').listSync())
      f.uri.pathSegments.last,
  };

  /// An MCP tool call, as the agent makes it. Returns the text.
  Future<String> agent(String tool, Map<String, Object?> args) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${bridge.port}/mcp'),
      );
      request.headers
        ..contentType = ContentType.json
        ..set('accept', 'application/json, text/event-stream');
      request.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': tool, 'arguments': args},
        }),
      );
      final response = await request.close();
      final body =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, Object?>;
      final result = body['result']! as Map<String, Object?>;
      final content = result['content']! as List<Object?>;
      return (content.first! as Map<String, Object?>)['text']! as String;
    } finally {
      client.close(force: true);
    }
  }

  /// `verify_note`, with the app answering its command as the app's
  /// long poll does.
  Future<String> verify(String id, {required bool passed}) async {
    final answer = () async {
      final command = (await app.nextCommand(
        wait: const Duration(seconds: 5),
      ))!;
      expect(command['tool'], 'verify_note');
      await app.postCommandResult(command['id']! as String, {
        'ok': true,
        'result': {
          'id': id,
          'passed': passed,
          'found': 'lib/form.dart:12',
          'checks': [
            {'type': 'visible', 'passed': passed},
          ],
        },
      });
    }();
    while (!bridge.commands.connected) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final text = await agent('verify_note', {'id': id});
    await answer;
    return text;
  }

  test('acceptance: draft, send, fix, verify, reopen with a reason, fix and '
      'verify again, accept', () async {
    final fixture = Annotation.fromJson(
      jsonDecode(File('test/fixtures/note.json').readAsStringSync())
          as Map<String, Object?>,
    )!;
    final id = fixture.id;
    var cursor = (await app.load()).cursor;
    Future<Annotation> seenByApp() async {
      final changes = await app.changes(cursor);
      cursor = changes.cursor;
      return changes.notes.singleWhere((n) => n.id == id);
    }

    // Draft: the bridge keeps it, no agent sees it.
    await app.save(fixture.withStatus(NoteStatus.draft));
    expect(filesIn('drafts'), contains('$id.json'));
    expect(await agent('list_notes', {}), 'No open notes.');

    // Send: the agent sees it.
    await app.save(fixture.withStatus(NoteStatus.submitted));
    expect(filesIn('open'), containsAll(['$id.json', '$id.md']));
    expect(await agent('list_notes', {}), contains('$id ('));

    // First pass.
    await agent('update_note', {
      'id': id,
      'status': 'inProgress',
      'message': 'Looking at it.',
    });
    expect((await seenByApp()).status, NoteStatus.inProgress);
    await agent('update_note', {
      'id': id,
      'status': 'fixed',
      'message': 'Made it 36 px.',
    });
    expect(await verify(id, passed: true), contains('Checks passed'));
    var note = await seenByApp();
    expect(note.status, NoteStatus.fixed);
    expect(note.verification?['passed'], isTrue);

    // The user reopens it, saying why: the agent sees it as work again,
    // with the reason, and the old check result is gone.
    await app.update(
      id,
      status: NoteStatus.submitted,
      message: 'Reopened: not yet, you shortened it',
    );
    note = await seenByApp();
    expect(note.status, NoteStatus.submitted);
    expect(note.verification, isNull);
    expect(filesIn('open'), contains('$id.md'));
    final listed = await agent('list_notes', {});
    expect(listed, contains('submitted, reopened'));
    expect(listed, contains('- user: Reopened: not yet, you shortened it'));
    expect(
      await agent('list_notes', {'detail': 'compact'}),
      contains('User: Reopened: not yet, you shortened it'),
    );
    expect(
      File('${root.path}/.pinpoint/open/$id.md').readAsStringSync(),
      contains('Reopened by the user'),
    );

    // Second pass: the same calls work again.
    await agent('update_note', {'id': id, 'status': 'inProgress'});
    await agent('update_note', {
      'id': id,
      'status': 'fixed',
      'message': 'Kept the width; set the height to 36 px.',
    });
    expect(await verify(id, passed: true), contains('Checks passed'));
    note = await seenByApp();
    expect(note.status, NoteStatus.fixed);
    expect(note.verification?['passed'], isTrue);
    expect(note.messages.map((m) => m.from), [
      'agent',
      'agent',
      'pinpoint',
      'user',
      'agent',
      'pinpoint',
    ]);

    // Accept: done for the agent, kept with the resolved notes.
    await app.update(id, status: NoteStatus.verified);
    expect((await seenByApp()).status, NoteStatus.verified);
    expect(filesIn('resolved'), contains('$id.json'));
    expect(filesIn('open'), isNot(contains('$id.json')));
    expect(await agent('list_notes', {}), 'No open notes.');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/bridge_server.dart';
import 'package:pinpoint/src/model/annotation.dart' show annotationSchema;

import '../support/fake_debug_service.dart';
import '../support/temp_git.dart';

/// PLAN-v3 Milestone 20, steps 2 to 5: the rounds of a note, the labels of
/// the agent, the undo route, `get_note_diff`.
///
/// A real bridge over loopback, in a temporary repository (or a temporary
/// folder with no git). Plain `test`: the widget binding fakes
/// `HttpClient`. Nothing here runs git in this project.
void main() {
  final skip = gitAvailable ? null : 'git is not on the PATH';
  late Directory temp;
  PinPointBridge? bridge;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pinpoint_rounds_');
  });
  tearDown(() async {
    await bridge?.close();
    bridge = null;
    await temp.delete(recursive: true);
  });

  File file(String path) => File('${temp.path}/$path');
  void write(String path, String text) {
    file(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  void seed() {
    write('lib/a.dart', 'one\ntwo\nthree\nfour\nfive\n');
    write('lib/b.dart', 'alpha\nbeta\n');
    write('lib/x.dart', 'x1\nx2\nx3\n');
    write('lib/y.dart', 'y1\n');
  }

  /// Starts the bridge in [dir] (the folder that holds `.pinpoint/`).
  Future<void> startIn(Directory dir) async {
    bridge = await PinPointBridge.start(dir: '${dir.path}/.pinpoint', port: 0);
  }

  Uri url(String path) => Uri.parse('http://127.0.0.1:${bridge!.port}$path');

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, [
    Object? body,
  ]) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, url(path));
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (
        response.statusCode,
        text.isEmpty
            ? <String, Object?>{}
            : jsonDecode(text) as Map<String, Object?>,
      );
    } finally {
      client.close(force: true);
    }
  }

  Map<String, Object?> noteJson(String id) => {
    'schema': annotationSchema,
    'id': id,
    'createdAt': '2026-11-10T14:00:00Z',
    'status': 'submitted',
    'intent': 'bug',
    'comment': 'Fix it',
    'app': {'buildMode': 'debug', 'platform': 'web', 'origin': null},
    'page': {'route': '/'},
    'target': {
      'widget': 'Text',
      'source': {'file': 'lib/main.dart', 'line': 12, 'column': 5},
      'sourceUnavailable': false,
      'rect': {'x': 10, 'y': 20, 'w': 100, 'h': 30},
    },
    'messages': const <Object?>[],
    'ancestors': const <Object?>[],
  };

  Future<void> send(String id) async {
    final (status, _) = await call('POST', '/annotations', noteJson(id));
    expect(status, 201);
    // The base checkpoint is queued after the answer; an agent reads the
    // note before it edits, so wait as it would.
    await bridge!.store.settled();
  }

  /// An MCP tool call. Returns the text.
  Future<String> agent(String tool, Map<String, Object?> args) async {
    final (_, body) = await call('POST', '/mcp', {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': tool, 'arguments': args},
    });
    final result = body['result']! as Map<String, Object?>;
    final content = result['content']! as List<Object?>;
    return (content.first! as Map<String, Object?>)['text']! as String;
  }

  Future<Map<String, Object?>> stored(String id) async {
    final note = await bridge!.store.read(id);
    return note!;
  }

  List<Map<String, Object?>> roundsOf(Map<String, Object?> note) => [
    for (final r in note['rounds']! as List<Object?>)
      r! as Map<String, Object?>,
  ];

  Map<String, Object?> change(Map<String, Object?> round, String id) => [
    for (final c in round['changes']! as List<Object?>)
      c! as Map<String, Object?>,
  ].singleWhere((c) => c['id'] == id);

  List<String> pathsOf(Map<String, Object?> change) => [
    for (final f in change['files']! as List<Object?>)
      (f! as Map<String, Object?>)['path']! as String,
  ];

  /// A repository with one commit, and a bridge in it. Returns the user's
  /// state to compare with.
  Future<RepoState> gitProject() async {
    write('.gitignore', 'build/\n');
    seed();
    initRepo(temp);
    await startIn(temp);
    return RepoState.of(temp);
  }

  group('rounds', () {
    test('open on inProgress, close on fixed; labels split the files, '
        'the rest is "other", a missing file is dropped', () async {
      final user = await gitProject();
      await send('pp_a');
      expect(
        runGit(temp, ['rev-parse', '--verify', 'refs/pinpoint/pp_a/base']),
        isNotEmpty,
      );

      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      var rounds = roundsOf(await stored('pp_a'));
      expect(rounds, hasLength(1));
      expect(rounds.single['n'], 1);
      expect(rounds.single['start'], isNotNull);
      expect(rounds.single['endedAt'], isNull);
      expect(rounds.single['end'], isNull);

      write('lib/a.dart', 'one\nTWO\nthree\nfour\nfive\n');
      write('lib/b.dart', 'alpha\nBETA\n');
      write('lib/c.dart', 'new\n');
      write('build/out.txt', 'ignored\n');
      final answer = await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'message': 'Done.',
        'changes': [
          {
            'summary': 'Spacing',
            'files': ['lib/a.dart'],
          },
          {
            'summary': 'Colour',
            'files': ['lib/b.dart', 'lib/ghost.dart'],
          },
        ],
      });
      expect(answer, contains('Round 1:'));
      expect(answer, contains('c1: Spacing (1 file)'));
      expect(answer, contains('other: Not labelled by the agent (1 file)'));
      expect(answer, contains('Dropped lib/ghost.dart'));

      rounds = roundsOf(await stored('pp_a'));
      final round = rounds.single;
      expect(round['endedAt'], isNotNull);
      expect(round['start'], isNotNull);
      expect(round['end'], isNotNull);
      expect(round['undone'], isEmpty);
      expect(round['undo'], isNull);
      expect(pathsOf(change(round, 'c1')), ['lib/a.dart']);
      expect(change(round, 'c1')['summary'], 'Spacing');
      expect(pathsOf(change(round, 'c2')), ['lib/b.dart']);
      expect(pathsOf(change(round, 'other')), ['lib/c.dart']);
      final file =
          (change(round, 'c1')['files']! as List<Object?>).single!
              as Map<String, Object?>;
      expect([file['added'], file['removed']], [1, 1]);

      // Standard text: one short line.
      final text = await agent('get_note', {'id': 'pp_a'});
      expect(text, contains('Round 1 (changed: c1, c2, other)'));
      // The user's side did not move.
      expect(RepoState.of(temp).differsFrom(user), isNull);
    }, skip: skip);

    test(
      'a note set fixed without inProgress gets a round from base',
      () async {
        await gitProject();
        await send('pp_a');
        write('lib/a.dart', 'changed\n');
        await agent('update_note', {'id': 'pp_a', 'status': 'fixed'});
        final round = roundsOf(await stored('pp_a')).single;
        expect(round['start'], isNotNull);
        expect(round['end'], isNotNull);
        expect(pathsOf(change(round, 'other')), ['lib/a.dart']);
        // Set fixed again, or resolved: no second round.
        await agent('update_note', {'id': 'pp_a', 'status': 'resolved'});
        expect(roundsOf(await stored('pp_a')), hasLength(1));
      },
      skip: skip,
    );

    test('a second pass after a reopen is round 2, from a new base', () async {
      await gitProject();
      await send('pp_a');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      write('lib/a.dart', 'one\n');
      await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Trim',
            'files': ['lib/a.dart'],
          },
        ],
      });
      final (status, _) = await call('PATCH', '/annotations/pp_a', {
        'status': 'submitted',
        'message': 'Again',
      });
      expect(status, 200);
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      write('lib/b.dart', 'two\n');
      await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Second',
            'files': ['lib/b.dart'],
          },
        ],
      });
      final rounds = roundsOf(await stored('pp_a'));
      expect([for (final r in rounds) r['n']], [1, 2]);
      expect(pathsOf(change(rounds[0], 'c1')), ['lib/a.dart']);
      expect(pathsOf(change(rounds[1], 'c1')), ['lib/b.dart']);
      expect(change(rounds[1], 'c1').containsKey('other'), isFalse);
    }, skip: skip);

    test('a file changed in another note\'s open round is shared', () async {
      await gitProject();
      await send('pp_a');
      await send('pp_b');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      write('lib/x.dart', 'x1\nA\nx3\n');
      await agent('update_note', {'id': 'pp_b', 'status': 'inProgress'});
      write('lib/x.dart', 'x1\nA\nB\n');
      write('lib/y.dart', 'y2\n');
      await agent('update_note', {'id': 'pp_b', 'status': 'fixed'});

      final round = roundsOf(await stored('pp_b')).single;
      final files = {
        for (final f in change(round, 'other')['files']! as List<Object?>)
          (f! as Map<String, Object?>)['path']: f,
      };
      expect((files['lib/x.dart']! as Map)['shared'], isTrue);
      expect((files['lib/y.dart']! as Map).containsKey('shared'), isFalse);
    }, skip: skip);

    test('with no git the round has no trees, and changes come from the '
        'labels alone', () async {
      await startIn(temp);
      await send('pp_a');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      final answer = await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Spacing',
            'files': ['./lib/a.dart', 'lib/a.dart'],
          },
          {'summary': 'Nothing to name'},
        ],
      });
      expect(answer, contains('c1: Spacing (1 file)'));
      final round = roundsOf(await stored('pp_a')).single;
      expect(round['start'], isNull);
      expect(round['end'], isNull);
      expect(round['endedAt'], isNotNull);
      expect(pathsOf(change(round, 'c1')), ['lib/a.dart']);
      expect(change(round, 'c2')['files'], isEmpty);
      expect(
        (await agent('get_note', {'id': 'pp_a'})),
        contains('Round 1 (changed: c1, c2)'),
      );
    });

    test('a bridge folder below the git top level: label paths relative to '
        'it match, and the stored paths are repo-relative', () async {
      write('README.md', 'top\n');
      write('app/lib/main.dart', 'void main() {}\n');
      initRepo(temp);
      await startIn(Directory('${temp.path}/app'));
      await send('pp_a');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      write('app/lib/main.dart', 'void main() { run(); }\n');
      write('README.md', 'top changed\n');
      await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Run it',
            'files': ['lib/main.dart'],
          },
        ],
      });
      final round = roundsOf(await stored('pp_a')).single;
      expect(pathsOf(change(round, 'c1')), ['app/lib/main.dart']);
      expect(pathsOf(change(round, 'other')), ['README.md']);

      final (status, answer) = await call('POST', '/annotations/pp_a/undo', {
        'round': 1,
        'changes': ['c1'],
        'reason': 'no',
      });
      expect(status, 200);
      expect(answer['undo'], 'done');
      expect(answer['reverted'], ['app/lib/main.dart']);
      expect(file('app/lib/main.dart').readAsStringSync(), 'void main() {}\n');
      expect(file('README.md').readAsStringSync(), 'top changed\n');
    }, skip: skip);

    test('deleting a note deletes its checkpoint refs', () async {
      await gitProject();
      await send('pp_a');
      await send('pp_b');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      expect(runGit(temp, ['for-each-ref', 'refs/pinpoint/pp_a/']), isNotEmpty);
      final (status, _) = await call('DELETE', '/annotations/pp_a');
      expect(status, 200);
      expect(runGit(temp, ['for-each-ref', 'refs/pinpoint/pp_a/']), isEmpty);
      expect(runGit(temp, ['for-each-ref', 'refs/pinpoint/pp_b/']), isNotEmpty);
    }, skip: skip);
  });

  group('POST /annotations/<id>/undo', () {
    /// A note with round 1: c1 (a.dart), c2 (b.dart), other (c.dart).
    Future<RepoState> fixedNote() async {
      final user = await gitProject();
      await send('pp_a');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      write('lib/a.dart', 'one\nTWO\nthree\nfour\nfive\n');
      write('lib/b.dart', 'alpha\nBETA\n');
      write('lib/c.dart', 'new\n');
      await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Spacing',
            'files': ['lib/a.dart'],
          },
          {
            'summary': 'Colour',
            'files': ['lib/b.dart'],
          },
        ],
      });
      return user;
    }

    test('done: the files go back, the note is submitted again with the '
        'user\'s message', () async {
      final user = await fixedNote();
      final (status, answer) = await call('POST', '/annotations/pp_a/undo', {
        'round': 1,
        'changes': ['c1'],
        'reason': 'Too tight',
      });
      expect(status, 200);
      expect(answer['undo'], 'done');
      expect(answer['reverted'], ['lib/a.dart']);
      expect(answer['conflicts'], isEmpty);
      expect(answer['reloaded'], isFalse, reason: 'no debug service known');
      expect((answer['note']! as Map)['status'], 'submitted');

      expect(file('lib/a.dart').readAsStringSync(), contains('two\n'));
      expect(file('lib/b.dart').readAsStringSync(), 'alpha\nBETA\n');
      expect(file('lib/c.dart').existsSync(), isTrue);
      expect(RepoState.of(temp).differsFrom(user), isNull);

      final note = await stored('pp_a');
      expect(note['status'], 'submitted');
      expect(note['reopened'], 1);
      final messages = note['messages']! as List<Object?>;
      final last = messages.last! as Map<String, Object?>;
      expect(last['from'], 'user');
      expect(
        last['text'],
        'Undone by the bridge: Spacing. '
        'Kept: Colour; Not labelled by the agent. '
        'Do not make the undone changes again. Reason: Too tight',
      );
      final round = roundsOf(note).single;
      expect(round['undone'], ['c1']);
      expect(round['undo'], 'done');
      expect(
        File('${temp.path}/.pinpoint/open/pp_a.md').readAsStringSync(),
        contains('Round 1 (undone by user: c1; kept: c2, other)'),
      );
      expect(
        await agent('get_note', {'id': 'pp_a'}),
        contains('Round 1 (undone by user: c1; kept: c2, other)'),
      );

      // The same change again is refused; another one goes.
      final (again, _) = await call('POST', '/annotations/pp_a/undo', {
        'round': 1,
        'changes': ['c1'],
      });
      expect(again, HttpStatus.conflict);
    }, skip: skip);

    test('done: the app is hot reloaded when a debug service is known; a '
        'reload that did not apply says false', () async {
      final service = FakeDebugService();
      await service.start();
      addTearDown(service.stop);
      await fixedNote();
      File(
        '${temp.path}/.pinpoint/vm-service.txt',
      ).writeAsStringSync(service.wsUri);
      final (_, answer) = await call('POST', '/annotations/pp_a/undo', {
        'round': 1,
        'changes': ['c1'],
      });
      expect(answer['undo'], 'done');
      expect(answer['reloaded'], isTrue);
      expect(service.reloadedIsolates, ['isolates/1']);

      // The code does not compile: the files are back all the same.
      service.applies = false;
      await agent('update_note', {'id': 'pp_a', 'status': 'fixed'});
      final (_, second) = await call('POST', '/annotations/pp_a/undo', {
        'round': 1,
        'changes': ['c2'],
      });
      expect(second['undo'], 'done');
      expect(second['reloaded'], isFalse);
    }, skip: skip);

    test('requested: no reload, since no file changed', () async {
      final service = FakeDebugService();
      await service.start();
      addTearDown(service.stop);
      await fixedNote();
      File(
        '${temp.path}/.pinpoint/vm-service.txt',
      ).writeAsStringSync(service.wsUri);
      write('lib/a.dart', 'one\nTWO and more\nthree\nfour\nfive\n');
      final (_, answer) = await call('POST', '/annotations/pp_a/undo', {
        'round': 1,
        'changes': ['c1'],
      });
      expect(answer['undo'], 'requested');
      expect(answer['reloaded'], isFalse);
      expect(service.reloadedIsolates, isEmpty);
    }, skip: skip);

    test('requested: a file changed since, so no file changes', () async {
      final user = await fixedNote();
      // The user edits the lines the agent changed.
      write('lib/a.dart', 'one\nTWO and more\nthree\nfour\nfive\n');
      final (status, answer) = await call('POST', '/annotations/pp_a/undo', {
        'round': 1,
        'changes': ['c1', 'c2'],
        'reason': 'Not this',
      });
      expect(status, 200);
      expect(answer['undo'], 'requested');
      expect(answer['reverted'], isEmpty);
      expect(answer['conflicts'], ['lib/a.dart']);
      expect(answer['reloaded'], isFalse);
      // b.dart would have gone back alone; nothing changed.
      expect(file('lib/b.dart').readAsStringSync(), 'alpha\nBETA\n');
      expect(file('lib/a.dart').readAsStringSync(), contains('TWO and more'));
      expect(RepoState.of(temp).differsFrom(user), isNull);

      final note = await stored('pp_a');
      expect(note['status'], 'submitted');
      final last =
          (note['messages']! as List<Object?>).last! as Map<String, Object?>;
      expect(
        last['text'],
        'Undo these changes yourself: Spacing; Colour '
        '(lib/a.dart, lib/b.dart). Keep: Not labelled by the agent. '
        'Then continue. Reason: Not this. get_note_diff gives the patch.',
      );
      final round = roundsOf(note).single;
      expect(round['undone'], ['c1', 'c2']);
      expect(round['undo'], 'requested');
      expect(
        await agent('get_note', {'id': 'pp_a'}),
        contains('Round 1 (undo requested of: c1, c2; kept: other)'),
      );
    }, skip: skip);

    test('requested: with no git the bridge only asks the agent', () async {
      await startIn(temp);
      write('lib/a.dart', 'one\n');
      await send('pp_a');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Spacing',
            'files': ['lib/a.dart'],
          },
          {
            'summary': 'Colour',
            'files': ['lib/b.dart'],
          },
        ],
      });
      final (status, answer) = await call('POST', '/annotations/pp_a/undo', {
        'round': 1,
        'changes': ['c1'],
        'reason': 'No',
      });
      expect(status, 200);
      expect(answer['undo'], 'requested');
      expect(answer['reverted'], isEmpty);
      expect(answer['conflicts'], isEmpty);
      expect(answer['reloaded'], isFalse);
      expect(file('lib/a.dart').readAsStringSync(), 'one\n');
      final last =
          ((await stored('pp_a'))['messages']! as List<Object?>).last!
              as Map<String, Object?>;
      expect(
        last['text'],
        'Undo these changes yourself: Spacing (lib/a.dart). Keep: Colour. '
        'Then continue. Reason: No. get_note_diff gives the patch.',
      );
    });

    test('"*" undoes every change of the round', () async {
      await fixedNote();
      final (status, answer) = await call('POST', '/annotations/pp_a/undo', {
        'round': 1,
        'changes': ['*'],
      });
      expect(status, 200);
      expect(answer['undo'], 'done');
      expect((answer['reverted']! as List<Object?>).toSet(), {
        'lib/a.dart',
        'lib/b.dart',
        'lib/c.dart',
      });
      expect(file('lib/c.dart').existsSync(), isFalse);
      final note = await stored('pp_a');
      expect(roundsOf(note).single['undone'], ['*']);
      final last =
          (note['messages']! as List<Object?>).last! as Map<String, Object?>;
      expect(
        last['text'],
        'Undone by the bridge: Spacing; Colour; Not labelled by the agent. '
        'Kept: none. Do not make the undone changes again. '
        'Reason: none given',
      );
    }, skip: skip);

    test('refuses what cannot be undone', () async {
      await fixedNote();
      Future<int> undo(Object? body, [String id = 'pp_a']) async =>
          (await call('POST', '/annotations/$id/undo', body)).$1;
      expect(
        await undo({
          'round': 1,
          'changes': ['c9'],
        }),
        400,
      );
      expect(await undo({'round': 1, 'changes': <String>[]}), 400);
      expect(
        await undo({
          'round': 'one',
          'changes': ['c1'],
        }),
        400,
      );
      expect(
        await undo({
          'round': 1,
          'changes': ['c1'],
          'reason': 3,
        }),
        400,
      );
      expect(
        await undo({
          'round': 7,
          'changes': ['c1'],
        }),
        404,
      );
      expect(
        await undo({
          'round': 1,
          'changes': ['c1'],
        }, 'pp_nope'),
        404,
      );
      expect(
        await undo({
          'round': 1,
          'changes': ['c1'],
        }, 'Bad..Id'),
        400,
      );
      expect((await call('GET', '/annotations/pp_a/undo')).$1, 405);
      // Nothing changed.
      expect((await stored('pp_a'))['status'], 'fixed');
      expect(roundsOf(await stored('pp_a')).single['undone'], isEmpty);

      // The agent has the note: no undo.
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      expect(
        await undo({
          'round': 1,
          'changes': ['c1'],
        }),
        409,
      );
      // Round 2 is open now.
      await agent('update_note', {'id': 'pp_a', 'status': 'fixed'});
      expect(
        await undo({
          'round': 2,
          'changes': ['*'],
        }),
        409,
      );
    }, skip: skip);

    test(
      'a request from the tab that undoes is left out of its /changes',
      () async {
        await fixedNote();
        final since = (await bridge!.store.changes(null)).cursor;
        await call('POST', '/annotations/pp_a/undo?client=c1', {
          'round': 1,
          'changes': ['c1'],
        });
        final own = await bridge!.store.changes(since, client: 'c1');
        expect(own.changes, isEmpty);
        final other = await bridge!.store.changes(since, client: 'c2');
        expect(other.changes.single['status'], 'submitted');
      },
      skip: skip,
    );
  });

  group('get_note_diff', () {
    test('gives the patch of the latest round, or of one change', () async {
      await gitProject();
      await send('pp_a');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      write('lib/a.dart', 'one\nTWO\nthree\nfour\nfive\n');
      write('lib/b.dart', 'alpha\nBETA\n');
      await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Spacing',
            'files': ['lib/a.dart'],
          },
          {
            'summary': 'Colour',
            'files': ['lib/b.dart'],
          },
        ],
      });
      final all = await agent('get_note_diff', {'id': 'pp_a'});
      expect(all, contains('Round 1 of pp_a'));
      expect(all, contains('lib/a.dart +1 -1'));
      expect(all, contains('+TWO'));
      expect(all, contains('+BETA'));

      final one = await agent('get_note_diff', {
        'id': 'pp_a',
        'round': 1,
        'change': 'c2',
      });
      expect(one, contains('+BETA'));
      expect(one, isNot(contains('+TWO')));

      expect(
        await agent('get_note_diff', {'id': 'pp_a', 'round': 5}),
        contains('no round 5'),
      );
      expect(
        await agent('get_note_diff', {'id': 'pp_a', 'change': 'c7'}),
        contains('no change c7'),
      );
      expect(
        await agent('get_note_diff', {'id': 'pp_none'}),
        contains('No note pp_none'),
      );
    }, skip: skip);

    test('a patch over 40 KB gives the file list only', () async {
      await gitProject();
      await send('pp_a');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      write(
        'lib/big.dart',
        [for (var i = 0; i < 3000; i++) 'line number $i'].join('\n'),
      );
      write('lib/b.dart', 'alpha\nBETA\n');
      await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Big',
            'files': ['lib/big.dart'],
          },
          {
            'summary': 'Small',
            'files': ['lib/b.dart'],
          },
        ],
      });
      final text = await agent('get_note_diff', {'id': 'pp_a'});
      expect(text, contains('over the 40 KB limit: files only'));
      expect(text, contains('lib/big.dart +3000 -0'));
      expect(text, isNot(contains('+line number 5')));
      final small = await agent('get_note_diff', {
        'id': 'pp_a',
        'change': 'c2',
      });
      expect(small, contains('+BETA'));
    }, skip: skip);

    test('with no git it lists the files the agent named', () async {
      await startIn(temp);
      await send('pp_a');
      expect(
        await agent('get_note_diff', {'id': 'pp_a'}),
        contains('no finished round yet'),
      );
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      expect(
        await agent('get_note_diff', {'id': 'pp_a'}),
        contains('no finished round yet'),
      );
      await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Spacing',
            'files': ['lib/a.dart'],
          },
        ],
      });
      final text = await agent('get_note_diff', {'id': 'pp_a'});
      expect(text, contains('lib/a.dart'));
      expect(text, contains('no git checkpoints'));
    });
  });

  group('update_note changes', () {
    test('a bad changes argument is refused', () async {
      await startIn(temp);
      await send('pp_a');
      for (final bad in <Object?>[
        'x',
        [1],
        [
          {'files': <String>[]},
        ],
        [
          {'summary': 'a', 'files': 'lib/a.dart'},
        ],
      ]) {
        final (_, body) = await call('POST', '/mcp', {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {
            'name': 'update_note',
            'arguments': {'id': 'pp_a', 'status': 'fixed', 'changes': bad},
          },
        });
        expect((body['error']! as Map)['code'], -32602, reason: '$bad');
      }
      expect((await stored('pp_a'))['status'], 'submitted');
    });

    test('the answer asks for labels when a fixed round has none', () async {
      await gitProject();
      await send('pp_a');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      write('lib/a.dart', 'changed\n');
      final answer = await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
      });
      expect(answer, contains('other: Not labelled by the agent (1 file)'));
      expect(answer, contains('give changes: [{summary, files}]'));
    }, skip: skip);

    test('a second fixed call with labels labels the closed round', () async {
      await gitProject();
      await send('pp_a');
      await agent('update_note', {'id': 'pp_a', 'status': 'inProgress'});
      write('lib/a.dart', 'changed\n');
      await agent('update_note', {'id': 'pp_a', 'status': 'fixed'});
      await agent('update_note', {
        'id': 'pp_a',
        'status': 'fixed',
        'changes': [
          {
            'summary': 'Late label',
            'files': ['lib/a.dart'],
          },
        ],
      });
      final rounds = roundsOf(await stored('pp_a'));
      expect(rounds, hasLength(1));
      expect(change(rounds.single, 'c1')['summary'], 'Late label');
    }, skip: skip);
  });
}

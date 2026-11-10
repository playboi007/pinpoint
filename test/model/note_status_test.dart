import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/annotation.dart';
import 'package:pinpoint/src/sink/markdown_formatter.dart';

/// Milestone 8, build step 2: statuses, anchors and replies in the model.
void main() {
  Map<String, Object?> fixture() =>
      jsonDecode(File('test/fixtures/note.json').readAsStringSync())
          as Map<String, Object?>;

  Annotation minimal({NoteStatus? status}) => Annotation(
    id: 'pp_1',
    createdAt: DateTime.utc(2026, 11, 10),
    intent: AnnotationIntent.bug,
    comment: 'x',
    app: const AppInfo(buildMode: 'debug', platform: 'web'),
    page: const PageInfo(),
    target: const TargetInfo(widget: 'Text', sourceUnavailable: true),
    status: status ?? NoteStatus.draft,
  );

  test('a new note is a draft', () {
    expect(minimal().status, NoteStatus.draft);
    expect(minimal().toJson()['status'], 'draft');
  });

  test('the seven statuses and their JSON names', () {
    expect(
      [for (final s in NoteStatus.values) s.name],
      [
        'draft',
        'submitted',
        'inProgress',
        'fixed',
        'verified',
        'resolved',
        'rejected',
      ],
    );
    expect(NoteStatus.byName('inProgress'), NoteStatus.inProgress);
    expect(NoteStatus.byName('done'), isNull);
    expect(NoteStatus.byName(3), isNull);
    // Drafts are in neither list: the agent never sees them.
    expect(NoteStatus.open, isNot(contains(NoteStatus.draft)));
    expect(NoteStatus.closed, isNot(contains(NoteStatus.draft)));
  });

  test('withStatus and copyWith keep everything else', () {
    final sent = minimal().withStatus(NoteStatus.submitted);
    expect(sent.status, NoteStatus.submitted);
    expect(sent.id, 'pp_1');
    expect(sent.comment, 'x');
  });

  group('fromJson', () {
    test('reads back what toJson wrote, part for part', () {
      final json = fixture();
      final note = Annotation.fromJson(json)!;
      // The image data stays out: the bridge keeps the PNG beside the JSON.
      (json['screenshot']! as Map<String, Object?>).remove('data');
      expect(jsonDecode(jsonEncode(note.toJson())), json);
    });

    test('reads an anchor and replies', () {
      final json = fixture()
        ..['anchor'] = const NoteAnchor(
          file: 'lib/a.dart',
          line: 3,
          column: 5,
          widget: 'Text',
          key: "[<'k'>]",
          ordinal: 2,
          itemIndex: 7,
          route: '/x',
        ).toJson()
        ..['messages'] = [
          {'at': '2026-11-10T15:00:00Z', 'from': 'agent', 'text': 'Done.'},
        ];
      final note = Annotation.fromJson(json)!;
      expect(note.anchor!.itemIndex, 7);
      expect(note.anchor!.ordinal, 2);
      expect(note.anchor!.key, "[<'k'>]");
      expect(note.messages.single.text, 'Done.');
      expect(note.messages.single.at, DateTime.utc(2026, 11, 10, 15));
    });

    test('a schema 1 note was sent, so it reads as submitted', () {
      final json = fixture()
        ..['schema'] = 1
        ..remove('status');
      expect(Annotation.fromJson(json)!.status, NoteStatus.submitted);
    });

    test('wrong types are left empty, never thrown on', () {
      final note = Annotation.fromJson({
        'id': 'pp_2',
        'status': 7,
        'target': 'nope',
        'anchor': [1],
        'messages': 'x',
        'ancestors': [
          {'widget': 3},
        ],
        'screenshot': {'width': 'wide'},
      })!;
      expect(note.status, NoteStatus.draft);
      expect(note.target.widget, '?');
      expect(note.anchor, isNull);
      expect(note.messages, isEmpty);
      expect(note.ancestors, isEmpty);
      expect(note.screenshot!.width, 0);
      expect(Annotation.fromJson({'comment': 'no id'}), isNull);
    });

    test('never reads the screenshot data', () {
      final json = fixture()
        ..['screenshot'] = {
          'file': 'pp_1.png',
          'pixelRatio': 2,
          'width': 2,
          'height': 2,
          'crop': null,
          'hasPlatformViews': false,
          'debugPaint': <String>[],
          'data': 'iVBORw0KGgo=',
        };
      expect(Annotation.fromJson(json)!.screenshot!.png, isNull);
    });
  });

  group('Markdown', () {
    test('a submitted note has no status line', () {
      expect(markdownFromJson(fixture()), isNot(contains('Status:')));
      expect(markdownFor(minimal()), isNot(contains('Status:')));
    });

    test('the status shows once the agent moved the note on', () {
      final json = fixture()..['status'] = 'inProgress';
      expect(markdownFromJson(json), contains('Status: inProgress\n'));
    });

    test('replies come after the fields, one per line', () {
      final json = fixture()
        ..['messages'] = [
          {
            'at': '2026-11-10T15:00:00Z',
            'from': 'agent',
            'text': 'Wrapped the label.\n# not a heading',
          },
        ];
      final md = markdownFromJson(json);
      expect(
        md,
        contains(
          'Replies:\n'
          '- agent (2026-11-10T15:00:00Z): Wrapped the label.\n'
          '  # not a heading\n',
        ),
      );
    });
  });
}

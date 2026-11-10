import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/note_detail.dart';

/// Milestone 8, build step 4: how much of a note each detail level shows.
void main() {
  Map<String, Object?> fixture() =>
      jsonDecode(File('test/fixtures/note.json').readAsStringSync())
          as Map<String, Object?>;

  test('acceptance: compact is under 600 characters for a typical note', () {
    final text = noteText(fixture(), NoteDetail.compact);
    // ignore: avoid_print
    print('compact: ${text.length} characters');
    expect(text.length, lessThan(600));
    expect(
      text,
      'pp_20261110_143205_a1f3 (improve, submitted)\n'
      'Comment: Label truncates at narrow widths\n'
      'Target: Text("Save changes")\n'
      'Source: lib/widgets/save_bar.dart:42:18\n'
      'Rect: 912,648 96x20',
    );
  });

  test('compact cuts a long comment, never the source', () {
    final note = fixture()..['comment'] = 'word ' * 400;
    final text = noteText(note, NoteDetail.compact);
    expect(text.length, lessThanOrEqualTo(maxCompactChars));
    expect(text, contains('…'));
    expect(text, contains('Source: lib/widgets/save_bar.dart:42:18'));
  });

  test('standard adds layout, enclosing widgets, page and screenshot', () {
    final text = noteText(fixture(), NoteDetail.standard);
    for (final part in [
      'Enclosing: ElevatedButton (lib/widgets/save_bar.dart:40:14)',
      'Layout: constraints 0<=w<=96',
      'parent Row, child 2 of 3',
      'Page: /orders/:id  viewport 1280x720  dark',
      'Screenshot: pp_20261110_143205_a1f3.png (attached',
    ]) {
      expect(text, contains(part));
    }
    expect(text, isNot(contains('Subtree')));
    expect(text, isNot(contains('Properties')));
  });

  test('full adds properties, subtree and environment', () {
    final text = noteText(fixture(), NoteDetail.full);
    expect(text, contains('Properties: maxLines=1, overflow=ellipsis'));
    expect(text, contains('Subtree:'));
    expect(text, contains('Environment: debug, web, dpr 2'));
    expect(
      text.length,
      greaterThan(noteText(fixture(), NoteDetail.standard).length),
    );
  });

  test('replies show from standard up', () {
    final note = fixture()
      ..['messages'] = [
        {'at': '2026-11-10T15:00:00Z', 'from': 'agent', 'text': 'Wrapped it.'},
      ];
    expect(noteText(note, NoteDetail.compact), isNot(contains('Wrapped')));
    expect(
      noteText(note, NoteDetail.standard),
      contains('Replies:\n- agent: Wrapped it.'),
    );
  });

  test('detail names', () {
    expect(NoteDetail.byName(null), NoteDetail.standard);
    expect(NoteDetail.byName('full'), NoteDetail.full);
    expect(NoteDetail.byName('huge'), isNull);
  });
}

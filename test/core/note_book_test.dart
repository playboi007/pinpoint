import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/core/note_book.dart';

import '../support/fake_pick.dart';

/// Milestone 8, build step 2: the notes the app shows as pins, and the
/// controller's pin transitions.
void main() {
  Annotation note(String id, int minute, {NoteStatus? status}) => Annotation(
    id: id,
    createdAt: DateTime.utc(2026, 11, 10, 14, minute),
    intent: AnnotationIntent.improve,
    comment: id,
    app: const AppInfo(buildMode: 'debug', platform: 'web'),
    page: const PageInfo(),
    target: const TargetInfo(widget: 'Text', sourceUnavailable: true),
    status: status ?? NoteStatus.draft,
  );

  group('NoteBook', () {
    test('keeps notes in creation order, so pin numbers are stable', () {
      final book = NoteBook()
        ..put(note('b', 2))
        ..put(note('a', 1))
        ..putAll([note('c', 3)]);
      expect([for (final n in book.notes) n.id], ['a', 'b', 'c']);
      expect(book.numberOf('c'), 3);
    });

    test('put replaces by id; verified notes leave the pins', () {
      final book = NoteBook()
        ..put(note('a', 1))
        ..put(note('b', 2));
      book.put(note('a', 1, status: NoteStatus.verified));
      expect(book.notes, hasLength(2));
      expect([for (final n in book.pinned) n.id], ['b']);
      expect(book.numberOf('a'), isNull);
      expect(book.numberOf('b'), 1);
    });

    test('drafts, remove, and moveAnchor without a notification', () {
      var notified = 0;
      final book = NoteBook()
        ..put(note('a', 1))
        ..put(note('b', 2, status: NoteStatus.submitted))
        ..addListener(() => notified++);
      expect([for (final n in book.drafts) n.id], ['a']);
      book.moveAnchor('a', const NoteAnchor(file: 'f.dart', line: 9));
      expect(book.byId('a')!.anchor!.line, 9);
      expect(notified, 0);
      expect(book.remove('a'), isTrue);
      expect(book.remove('a'), isFalse);
      expect(notified, 1);
    });
  });

  group('controller', () {
    late PinPointController controller;
    setUp(() => controller = PinPointController());
    tearDown(() => controller.dispose());

    test('openPin goes from idle to commenting with the note open', () {
      controller.notes.put(note('a', 1));
      expect(controller.openPin('a', fakePick()), isTrue);
      expect(controller.mode, PinPointMode.commenting);
      expect(controller.openNote.value, 'a');
      expect(controller.openPin('missing', fakePick()), isFalse);
    });

    test('a click on another widget closes the note, even with a comment '
        'typed', () {
      controller.notes.put(note('a', 1));
      controller.draft.text.text = 'half written';
      controller.openPin('a', fakePick());
      expect(controller.select(fakePick()), isTrue);
      expect(controller.openNote.value, isNull);
      expect(controller.draft.text.text, 'half written');
    });

    test('draftSaved goes from sending back to picking', () {
      controller
        ..startPicking()
        ..select(fakePick())
        ..submit();
      expect(controller.draftSaved(), isTrue);
      expect(controller.mode, PinPointMode.picking);
      expect(controller.selection.value, isNull);
      expect(controller.draftSaved(), isFalse);
    });

    test('stop closes the open note', () {
      controller.notes.put(note('a', 1));
      controller.openPin('a', fakePick());
      controller.stop();
      expect(controller.openNote.value, isNull);
    });
  });
}

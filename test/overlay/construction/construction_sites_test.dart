import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/annotation.dart';
import 'package:pinpoint/src/overlay/construction/construction_boxes.dart';
import 'package:pinpoint/src/overlay/construction/construction_sites.dart';
import 'package:pinpoint/src/overlay/construction/construction_stage.dart';
import 'package:pinpoint/src/overlay/pin_tracker.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

import '../../support/fake_construction_stage.dart';

/// The controller of the construction sites, with a fake stage: which
/// notes get a site, and when each one is lifted or taken away. The real
/// DOM is in `web/construction_stage_web_test.dart`.
void main() {
  late FakeConstructionStage stage;
  late ValueNotifier<List<PinPlacement>> placements;
  late ValueNotifier<PinPointPalette> palette;
  late ConstructionSites sites;
  late List<Rect> captured;
  Future<Uint8List?> Function(Rect) capture = (_) async => null;

  final png = Uint8List.fromList([1, 2, 3]);
  const rectA = Rect.fromLTWH(10, 20, 200, 60);

  PinPlacement pin(
    String id,
    NoteStatus status, {
    Rect rect = rectA,
    int number = 1,
    bool accepted = false,
  }) => PinPlacement(
    id: id,
    number: number,
    status: status,
    rect: rect,
    accepted: accepted,
  );

  void show(List<PinPlacement> next) => placements.value = next;

  setUp(() {
    stage = FakeConstructionStage();
    placements = ValueNotifier<List<PinPlacement>>(const <PinPlacement>[]);
    palette = ValueNotifier<PinPointPalette>(PinPointPalette.redline);
    captured = <Rect>[];
    capture = (rect) async {
      captured.add(rect);
      return png;
    };
    sites = ConstructionSites(stage: stage, capture: (rect) => capture(rect))
      ..follow(placements: placements, palette: palette);
  });

  tearDown(() {
    sites.dispose();
    placements.dispose();
    palette.dispose();
  });

  group('a note in progress', () {
    test('gets a site at its widget\'s rect', () {
      show([pin('a', NoteStatus.inProgress)]);
      expect(stage.sites, {'a': rectA});
      expect(stage.calls, ['add:a']);
    });

    test('draft, submitted, fixed and the rest get none', () {
      show([
        pin('a', NoteStatus.draft),
        pin('b', NoteStatus.submitted),
        pin('c', NoteStatus.resolved),
        pin('d', NoteStatus.rejected),
        pin('e', NoteStatus.fixed),
      ]);
      expect(stage.calls, isEmpty);
    });

    test('is at the rect already there when the overlay starts', () {
      sites.dispose();
      placements.value = [pin('a', NoteStatus.inProgress)];
      stage = FakeConstructionStage();
      sites = ConstructionSites(stage: stage, capture: (rect) => capture(rect))
        ..follow(placements: placements, palette: palette);
      expect(stage.sites.keys, ['a']);
    });

    test('follows its widget when it moves or is scrolled', () {
      show([pin('a', NoteStatus.inProgress)]);
      const moved = Rect.fromLTWH(10, 5, 200, 45);
      show([pin('a', NoteStatus.inProgress, rect: moved)]);
      expect(stage.sites['a'], moved);
      expect(stage.calls, ['add:a', 'move:a']);
      // The same rect again: nothing to say.
      show([pin('a', NoteStatus.inProgress, rect: moved)]);
      expect(stage.calls, ['add:a', 'move:a']);
    });

    test('keeps one site when other pins change', () {
      show([pin('a', NoteStatus.inProgress)]);
      show([
        pin('a', NoteStatus.inProgress),
        pin('b', NoteStatus.submitted, number: 2),
      ]);
      expect(stage.calls, ['add:a']);
    });
  });

  group('the site goes away', () {
    for (final status in [
      NoteStatus.submitted,
      NoteStatus.draft,
      NoteStatus.resolved,
      NoteStatus.rejected,
    ]) {
      test('with a fade when the note is ${status.name}', () {
        show([pin('a', NoteStatus.inProgress)]);
        show([pin('a', status)]);
        expect(stage.sites, isEmpty);
        expect(stage.fades, [true]);
        expect(stage.reveals, isEmpty);
        expect(captured, isEmpty);
      });
    }

    test('with a fade when the note is deleted or its widget is gone', () {
      show([pin('a', NoteStatus.inProgress)]);
      show(const []);
      expect(stage.sites, isEmpty);
      expect(stage.fades, [true]);
      expect(captured, isEmpty);
    });

    test('with a fade when the note is accepted', () {
      show([pin('a', NoteStatus.inProgress)]);
      show([pin('a', NoteStatus.verified, accepted: true)]);
      expect(stage.fades, [true]);
    });

    test('and comes back when the widget does', () {
      show([pin('a', NoteStatus.inProgress)]);
      show(const []);
      show([pin('a', NoteStatus.inProgress)]);
      expect(stage.sites.keys, ['a']);
    });
  });

  group('a note that becomes fixed', () {
    testWidgets('takes one picture of the widget, reveals it, then removes', (
      tester,
    ) async {
      show([pin('a', NoteStatus.inProgress)]);
      show([pin('a', NoteStatus.fixed)]);
      expect(captured, [rectA]);
      // The picture is awaited.
      await tester.pump();
      expect(stage.reveals, {'a': png});
      expect(stage.calls, ['add:a', 'reveal:a']);
      expect(stage.sites, isNotEmpty, reason: 'the finish is playing');

      await tester.pump(ConstructionSites.revealDuration * 0.9);
      expect(stage.count('remove'), 0);
      await tester.pump(ConstructionSites.revealDuration * 0.2);
      expect(stage.calls.last, 'remove:a');
      expect(stage.fades, [false], reason: 'the finish ends without a fade');
      expect(stage.sites, isEmpty);
    });

    testWidgets('reveals without a picture when the capture fails', (
      tester,
    ) async {
      capture = (_) async => throw StateError('no boundary');
      show([pin('a', NoteStatus.inProgress)]);
      show([pin('a', NoteStatus.fixed)]);
      await tester.pump();
      expect(stage.reveals.containsKey('a'), isTrue);
      expect(stage.reveals['a'], isNull);
      await tester.pump(ConstructionSites.revealDuration);
      expect(stage.sites, isEmpty);
    });

    testWidgets('reveals without a picture when it takes too long', (
      tester,
    ) async {
      capture = (_) => Completer<Uint8List?>().future;
      show([pin('a', NoteStatus.inProgress)]);
      show([pin('a', NoteStatus.fixed)]);
      await tester.pump(sites.captureTimeout + const Duration(seconds: 1));
      expect(stage.reveals.containsKey('a'), isTrue);
      expect(stage.reveals['a'], isNull);
      await tester.pump(ConstructionSites.revealDuration);
    });

    testWidgets('is only faded when it changes again during the capture', (
      tester,
    ) async {
      final done = Completer<Uint8List?>();
      capture = (_) => done.future;
      show([pin('a', NoteStatus.inProgress)]);
      show([pin('a', NoteStatus.fixed)]);
      show([pin('a', NoteStatus.submitted)]);
      expect(stage.sites, isEmpty);
      expect(stage.fades, [true]);
      done.complete(png);
      await tester.pump();
      expect(stage.reveals, isEmpty, reason: 'the note is no longer fixed');
    });

    testWidgets('and back in progress while the finish plays: a new site', (
      tester,
    ) async {
      show([pin('a', NoteStatus.inProgress)]);
      show([pin('a', NoteStatus.fixed)]);
      await tester.pump();
      show([pin('a', NoteStatus.inProgress)]);
      expect(stage.calls, ['add:a', 'reveal:a', 'remove:a', 'add:a']);
      expect(stage.fades, [false]);
      expect(stage.sites.keys, ['a']);
      // The old finish's timer is gone: nothing is removed later.
      await tester.pump(ConstructionSites.revealDuration * 2);
      expect(stage.count('remove'), 1);
      expect(stage.sites.keys, ['a']);
    });
  });

  group('the blueprint', () {
    const read = [
      ConstructionBox(4, 4, 40, 20),
      ConstructionBox(50, 4, 60, 30),
    ];

    ConstructionSites withReader(
      BlueprintReader reader, {
      ConstructionStage? on,
    }) {
      sites.dispose();
      stage = on is FakeConstructionStage ? on : FakeConstructionStage();
      return sites = ConstructionSites(
        stage: stage,
        capture: (rect) => capture(rect),
        blueprint: reader,
      )..follow(placements: placements, palette: palette);
    }

    test('is read once, with the id and rect, and given to the stage', () {
      final asked = <(String, Rect)>[];
      withReader((id, rect) {
        asked.add((id, rect));
        return read;
      });
      show([pin('a', NoteStatus.inProgress)]);
      expect(asked, [('a', rectA)]);
      expect(stage.boxes['a'], read);
      // Not again when the widget moves, or when other pins change.
      show([
        pin(
          'a',
          NoteStatus.inProgress,
          rect: const Rect.fromLTWH(0, 0, 200, 60),
        ),
      ]);
      show([
        pin(
          'a',
          NoteStatus.inProgress,
          rect: const Rect.fromLTWH(0, 0, 200, 60),
        ),
        pin('b', NoteStatus.submitted, number: 2),
      ]);
      expect(asked, hasLength(1));
    });

    test('is read for each site, as it goes up', () {
      final asked = <String>[];
      withReader((id, rect) {
        asked.add(id);
        return read;
      });
      show([
        pin('a', NoteStatus.inProgress),
        pin('b', NoteStatus.inProgress, number: 2),
      ]);
      expect(asked, ['a', 'b']);
    });

    test('is generic, from the widget\'s size, when none can be read', () {
      withReader((id, rect) => const []);
      show([pin('a', NoteStatus.inProgress)]);
      expect(stage.boxes['a'], ConstructionBoxes.generic(200, 60));
      expect(stage.boxes['a'], isNotEmpty);
    });

    test('is generic without a reader, or when the reader throws', () {
      show([pin('a', NoteStatus.inProgress)]);
      expect(stage.boxes['a'], ConstructionBoxes.generic(200, 60));
      withReader((id, rect) => throw StateError('no render object'));
      show(const []);
      show([pin('b', NoteStatus.inProgress)]);
      expect(stage.boxes['b'], ConstructionBoxes.generic(200, 60));
    });

    test('a widget that comes back is read again', () {
      var reads = 0;
      withReader((id, rect) {
        reads++;
        return read;
      });
      show([pin('a', NoteStatus.inProgress)]);
      show(const []);
      show([pin('a', NoteStatus.inProgress)]);
      expect(reads, 2);
    });
  });

  group('at most three sites', () {
    testWidgets('the fourth waits for a free place', (tester) async {
      PinPlacement w(String id, int n) =>
          pin(id, NoteStatus.inProgress, number: n);
      show([w('a', 1), w('b', 2), w('c', 3), w('d', 4)]);
      expect(stage.sites.keys, ['a', 'b', 'c']);

      // One goes away: the next change puts the fourth up.
      show([pin('a', NoteStatus.submitted), w('b', 2), w('c', 3), w('d', 4)]);
      expect(stage.sites.keys.toSet(), {'b', 'c', 'd'});
    });

    testWidgets('a finished site gives its place to the one that waited', (
      tester,
    ) async {
      PinPlacement w(String id, int n) =>
          pin(id, NoteStatus.inProgress, number: n);
      show([w('a', 1), w('b', 2), w('c', 3), w('d', 4)]);
      show([pin('a', NoteStatus.fixed), w('b', 2), w('c', 3), w('d', 4)]);
      await tester.pump();
      // The finish still takes its place.
      expect(stage.sites.keys.toSet(), {'a', 'b', 'c'});
      await tester.pump(ConstructionSites.revealDuration);
      expect(stage.sites.keys.toSet(), {'b', 'c', 'd'});
    });
  });

  group('reduced motion', () {
    test('passes the flag to the stage', () {
      expect(stage.reduced, isFalse);
      sites.reduced = true;
      expect(stage.reduced, isTrue);
      sites.reduced = false;
      expect(stage.reduced, isFalse);
    });

    test('a fixed note\'s site is simply removed: no picture, no reveal', () {
      sites.reduced = true;
      show([pin('a', NoteStatus.inProgress)]);
      expect(stage.sites.keys, ['a'], reason: 'it shows still');
      show([pin('a', NoteStatus.fixed)]);
      expect(stage.sites, isEmpty);
      expect(stage.fades, [false]);
      expect(stage.reveals, isEmpty);
      expect(captured, isEmpty);
    });
  });

  group('the palette', () {
    test('gives the stage the colours of the palette, and each switch', () {
      expect(
        stage.colors,
        ConstructionColors.of(PinPointPalette.redline.tokens),
      );
      palette.value = PinPointPalette.ember;
      expect(stage.colors, ConstructionColors.of(PinPointPalette.ember.tokens));
      expect(
        stage.colors,
        isNot(ConstructionColors.of(PinPointTokens.redline)),
      );
    });

    test('writes colours as CSS', () {
      expect(
        ConstructionColors.css(const Color(0xFFFF0000)),
        'rgba(255,0,0,1)',
      );
      expect(
        ConstructionColors.css(const Color(0x80000000)),
        matches(RegExp(r'^rgba\(0,0,0,0\.50\d\)$')),
      );
    });
  });

  group('lifetime', () {
    test('dispose takes the stage down and stops following', () {
      show([pin('a', NoteStatus.inProgress)]);
      sites.dispose();
      expect(stage.disposed, isTrue);
      final before = stage.calls.length;
      show([pin('b', NoteStatus.inProgress)]);
      expect(stage.calls.length, before);
    });

    testWidgets('dispose during a finish leaves no timer', (tester) async {
      show([pin('a', NoteStatus.inProgress)]);
      show([pin('a', NoteStatus.fixed)]);
      await tester.pump();
      sites.dispose();
      // The test fails on a pending timer; and nothing is removed later.
      await tester.pump(ConstructionSites.revealDuration * 2);
      expect(stage.count('remove'), 0);
    });

    test('a stage that is not available is never called', () {
      final none = FakeConstructionStage(available: false);
      final other = ConstructionSites(stage: none, capture: (_) async => null)
        ..follow(placements: placements, palette: palette);
      show([pin('a', NoteStatus.inProgress)]);
      expect(none.calls, isEmpty);
      expect(none.colors, isNull);
      other.dispose();
    });
  });
}

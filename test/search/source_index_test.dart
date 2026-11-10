import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/annotation.dart';
import 'package:pinpoint/src/search/source_index.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../fixtures/pin_fixture.dart';
import '../support/markers.dart';

/// Milestone 8, build step 1: `SourceIndex` finds a note's widget again
/// from its anchor. Pins, tweak re-anchoring and agent verification all
/// depend on it, so it is tested alone first.
void main() {
  const fixture = 'test/fixtures/pin_fixture.dart';

  Element root(WidgetTester tester) => tester.element(find.byType(Scaffold));

  Element textElement(WidgetTester tester, String data) => tester.element(
    find.byWidgetPredicate((w) => w is Text && w.data == data),
  );

  SourceIndex newIndex() => SourceIndex(resolver: const SourceResolver());

  group('anchorFor', () {
    testWidgets('names the file, line, type and ordinal of a list row', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();

      final anchor = index.anchorFor(
        textElement(tester, 'row 1'),
        root: root(tester),
        route: '/home',
      )!;
      expect(anchor.file, endsWith(fixture));
      expect(anchor.line, markerLine(fixture, 'row'));
      expect(anchor.column, greaterThan(0));
      expect(anchor.widget, 'Text');
      expect(anchor.key, isNull);
      expect(anchor.ordinal, 1);
      expect(anchor.itemIndex, isNull);
      expect(anchor.route, '/home');
    });

    testWidgets('records the key, and counts the ordinal among equal keys', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final anchor = newIndex().anchorFor(
        tester.element(find.byKey(const ValueKey<String>('b'))),
        root: root(tester),
      )!;
      expect(anchor.widget, 'SizedBox');
      expect(anchor.key, "[<'b'>]");
      expect(anchor.line, markerLine(fixture, 'keyed'));
      expect(anchor.ordinal, 0);
    });

    testWidgets('records the lazy-list item index', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PinListFixture()));
      final anchor = newIndex().anchorFor(
        textElement(tester, 'Item 4'),
        root: root(tester),
      )!;
      expect(anchor.line, markerLine(fixture, 'item'));
      expect(anchor.itemIndex, 4);
      expect(anchor.ordinal, 0);
    });

    testWidgets('has no file outside debug (no creation locations)', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = SourceIndex(resolver: const SourceResolver(tracked: false));
      final anchor = index.anchorFor(
        textElement(tester, 'Title'),
        root: root(tester),
      )!;
      expect(anchor.resolvable, isFalse);
      expect(anchor.widget, 'Text');
      expect(index.resolve(anchor, root: root(tester)), isNull);
    });
  });

  group('find and resolve', () {
    testWidgets('an anchor resolves to the same element', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();
      for (final data in ['Title', 'row 0', 'row 1', 'row 2']) {
        final element = textElement(tester, data);
        final anchor = index.anchorFor(element, root: root(tester))!;
        expect(
          index.resolve(anchor, root: root(tester)),
          same(element),
          reason: data,
        );
      }
    });

    testWidgets('matches come in tree order', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();
      final anchor = index.anchorFor(
        textElement(tester, 'row 0'),
        root: root(tester),
      )!;
      final matches = index.find(anchor, root: root(tester));
      expect(
        [for (final e in matches) (e.widget as Text).data],
        ['row 0', 'row 1', 'row 2'],
      );
    });

    testWidgets('a keyed widget resolves by its key', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();
      final anchor = index.anchorFor(
        tester.element(find.byKey(const ValueKey<String>('b'))),
        root: root(tester),
      )!;
      expect(
        index.resolve(anchor, root: root(tester))!.widget.key,
        const ValueKey<String>('b'),
      );
    });

    testWidgets('an ordinal past the matches resolves to nothing', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();
      final anchor = index.anchorFor(
        textElement(tester, 'row 2'),
        root: root(tester),
      )!;
      await tester.pumpWidget(const MaterialApp(home: PinFixture(rows: 2)));
      expect(index.resolve(anchor, root: root(tester)), isNull);
    });

    // Acceptance: "After the agent inserts ten lines above the widget, the
    // pin still resolves." After a restart there is no element to follow;
    // the anchor's line is ten lines off.
    testWidgets('ten lines inserted above: the nearest line of the same type '
        'in the same file', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();
      final star = tester.element(find.byType(Icon));
      final anchor = index.anchorFor(star, root: root(tester))!;
      final before = anchor.movedTo(line: anchor.line! - 10);

      expect(index.resolve(before, root: root(tester)), same(star));
      // And a fresh index (a restarted app) finds it too.
      expect(newIndex().resolve(before, root: root(tester)), same(star));
    });

    testWidgets('the exact line wins over a nearer type match', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();
      final title = index.anchorFor(
        textElement(tester, 'Title'),
        root: root(tester),
      )!;
      expect(
        (index.resolve(title, root: root(tester))!.widget as Text).data,
        'Title',
      );
    });

    testWidgets('another file or another type does not match', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();
      final anchor = index.anchorFor(
        textElement(tester, 'Title'),
        root: root(tester),
      )!;
      final elsewhere = NoteAnchor(
        file: 'lib/other.dart',
        line: anchor.line,
        widget: 'Text',
      );
      expect(index.find(elsewhere, root: root(tester)), isEmpty);
      final otherType = NoteAnchor(
        file: anchor.file,
        line: anchor.line,
        widget: 'Checkbox',
      );
      expect(index.find(otherType, root: root(tester)), isEmpty);
    });

    testWidgets('a lazy-list pin stays on its item through a scroll', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(home: PinListFixture(controller: scroll)),
      );
      final index = newIndex();
      final anchor = index.anchorFor(
        textElement(tester, 'Item 6'),
        root: root(tester),
      )!;

      // Four rows scroll away: by tree order alone, the pin would move to
      // another row.
      scroll.jumpTo(160);
      await tester.pump();
      final after = index.resolve(anchor, root: root(tester));
      expect((after!.widget as Text).data, 'Item 6');

      // Scrolled far away, the item is not built and the pin has nothing.
      scroll.jumpTo(20000);
      await tester.pump();
      expect(index.resolve(anchor, root: root(tester)), isNull);
    });
  });

  group('cost', () {
    // PLAN.md, Milestone 8, watch out: resolving a location costs a
    // diagnostics serialization per element. With a widget type in the
    // anchor, only elements of that type are resolved.
    testWidgets('only elements of the anchor type are resolved', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();
      final anchor = index.anchorFor(
        textElement(tester, 'Title'),
        root: root(tester),
      )!;
      final texts = find
          .descendant(of: find.byType(Scaffold), matching: find.byType(Text))
          .evaluate()
          .length;

      SourceIndex.debugLocationReads = 0;
      index.find(anchor, root: root(tester));
      expect(SourceIndex.debugLocationReads, texts);

      SourceIndex.debugLocationReads = 0;
      index.find(
        NoteAnchor(file: anchor.file, line: anchor.line),
        root: root(tester),
      );
      expect(SourceIndex.debugLocationReads, greaterThan(texts * 3));
    });

    testWidgets('one walk serves many anchors', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PinFixture()));
      final index = newIndex();
      final anchors = [
        for (final data in ['Title', 'row 0', 'row 2'])
          index.anchorFor(textElement(tester, data), root: root(tester))!,
        index.anchorFor(tester.element(find.byType(Icon)), root: root(tester))!,
      ];
      SourceIndex.debugWalks = 0;
      final found = index.resolveAll(anchors, root: root(tester));
      expect(SourceIndex.debugWalks, 1);
      expect(
        [for (final a in anchors) found[a]?.widget.runtimeType],
        [Text, Text, Text, Icon],
      );
    });

    // PLAN.md, Milestone 8, how to verify: budget 300 ms cold, 20 ms warm
    // on the long list. The VM is about 20 times faster than DDC; the
    // browser numbers are a manual check.
    testWidgets('long list: cold and warm lookups stay in budget', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: PinListFixture()));
      final anchor = newIndex().anchorFor(
        textElement(tester, 'Item 3'),
        root: root(tester),
      )!;
      // New widget instances: nothing is in the location cache.
      await tester.pumpWidget(
        MaterialApp(home: PinListFixture(key: UniqueKey())),
      );
      final index = newIndex();
      final cold = Stopwatch()..start();
      expect(index.resolve(anchor, root: root(tester)), isNotNull);
      cold.stop();
      final warm = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        index.resolve(anchor, root: root(tester));
      }
      warm.stop();
      final warmMs = warm.elapsedMicroseconds / 10 / 1000;
      // ignore: avoid_print
      print(
        'SourceIndex long list: cold ${cold.elapsedMicroseconds / 1000} ms, '
        'warm $warmMs ms',
      );
      expect(cold.elapsedMilliseconds, lessThan(300));
      expect(warmMs, lessThan(20));
    });
  });
}

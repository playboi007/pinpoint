import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/markers.dart';

/// Milestone 3, build step 1: reading creation locations through the
/// inspector serializer (engineering rule 8: a known file and line).
void main() {
  Future<void> pumpFixture(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: FixturePage()));

  Element elementOf(WidgetTester tester, Finder finder) =>
      tester.element(finder);

  group('locationOf', () {
    testWidgets('a Text written in the fixture names its file and line', (
      tester,
    ) async {
      await pumpFixture(tester);
      const resolver = SourceResolver();

      final text = resolver.locationOf(
        elementOf(
          tester,
          find.byWidgetPredicate((w) => w is Text && w.data == 'Save'),
        ),
      )!;
      expect(Uri.parse(text.uri).path, endsWith(saveBarFixture));
      expect(text.line, markerLine(saveBarFixture, 'save_text'));
      expect(text.column, greaterThan(0));
      expect(text.name, 'Text');
    });

    testWidgets('the button and the custom widget have their own lines', (
      tester,
    ) async {
      await pumpFixture(tester);
      const resolver = SourceResolver();

      final button = resolver.locationOf(
        elementOf(tester, find.byType(ElevatedButton)),
      )!;
      final bar = resolver.locationOf(elementOf(tester, find.byType(SaveBar)))!;

      expect(button.line, markerLine(saveBarFixture, 'save_button'));
      expect(bar.line, markerLine(saveBarFixture, 'save_bar'));
    });

    // PLAN.md, Milestone 3, watch out: the location is the call site, so a
    // widget built in a helper method points at the helper.
    testWidgets('a widget built in a helper method points at the helper', (
      tester,
    ) async {
      await pumpFixture(tester);
      const resolver = SourceResolver();

      final hint = resolver.locationOf(
        elementOf(
          tester,
          find.byWidgetPredicate((w) => w is Text && w.data == 'hint'),
        ),
      )!;
      expect(hint.line, markerLine(saveBarFixture, 'helper_text'));
    });

    testWidgets('a framework-built widget points into the Flutter SDK', (
      tester,
    ) async {
      await pumpFixture(tester);
      const resolver = SourceResolver();

      // The RichText that the fixture's Text builds.
      final richText = resolver.locationOf(
        elementOf(
          tester,
          find.descendant(
            of: find.byWidgetPredicate((w) => w is Text && w.data == 'Save'),
            matching: find.byType(RichText),
          ),
        ),
      )!;
      expect(richText.uri, contains('/packages/flutter/'));
    });

    testWidgets('locations are cached per widget instance', (tester) async {
      await pumpFixture(tester);
      const resolver = SourceResolver();
      final element = elementOf(tester, find.byType(ElevatedButton));

      final first = resolver.locationOf(element);
      expect(identical(resolver.locationOf(element), first), isTrue);
      // Another resolver shares the cache: a location belongs to the widget.
      expect(
        identical(const SourceResolver().locationOf(element), first),
        isTrue,
      );
    });

    testWidgets('untracked creation (profile mode) reads nothing', (
      tester,
    ) async {
      await pumpFixture(tester);
      const resolver = SourceResolver(tracked: false);

      expect(resolver.available, isFalse);
      expect(
        resolver.locationOf(elementOf(tester, find.byType(ElevatedButton))),
        isNull,
      );
    });

    // PLAN.md, Milestone 3: do not set the inspector's global selection to
    // read a location; that changes what DevTools shows as selected.
    testWidgets('reading a location leaves the inspector selection alone', (
      tester,
    ) async {
      await pumpFixture(tester);
      final selection = WidgetInspectorService.instance.selection;
      final before = selection.current;

      const SourceResolver().locationOf(
        elementOf(tester, find.byType(ElevatedButton)),
      );

      expect(selection.current, before);
    });
  });
}

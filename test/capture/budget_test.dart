import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/capture/context_collector.dart';
import 'package:pinpoint/src/model/annotation.dart' show maxPayloadBytes;
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/search/pick_result.dart';

/// Milestone 4 acceptance: the payload for one item in a 1,000-child list
/// stays under 8 KB.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host(Widget body) => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(controller: controller, child: child),
    home: Scaffold(body: body),
  );

  int bytesOf(Annotation note) => utf8.encode(jsonEncode(note.toJson())).length;

  Annotation collectAt(WidgetTester tester, PickResult pick) =>
      ContextCollector().collect(
        pick,
        'The subtitle wraps on narrow screens',
        AnnotationIntent.bug,
        context: tester.element(find.byType(InspectorOverlay)),
      );

  Future<PickResult> select(WidgetTester tester, String text) async {
    controller.startPicking();
    await tester.pump();
    final target = find
        .descendant(of: find.byType(Scaffold), matching: find.text(text))
        .first;
    await tester.tapAt(tester.getCenter(target));
    await tester.pump();
    return controller.selection.value!;
  }

  Widget tile(int i) => ListTile(
    key: ValueKey<String>('order-$i'),
    leading: CircleAvatar(child: Text('${i + 1}')),
    title: Text('Item ${i + 1}'),
    subtitle: const Text('A subtitle that may wrap on narrow viewports.'),
    trailing: const Icon(Icons.more_vert),
  );

  testWidgets('one item in a 1,000-item ListView.builder', (tester) async {
    await tester.pumpWidget(
      host(ListView.builder(itemCount: 1000, itemBuilder: (_, i) => tile(i))),
    );
    // The label, then up the local chain to the ListTile and beyond.
    var pick = await select(tester, 'Item 3');
    for (var step = 0; step < 4; step++) {
      final note = collectAt(tester, pick);
      expect(bytesOf(note), lessThanOrEqualTo(maxPayloadBytes));
      expect(note.errors, isEmpty);
      pick = pick.stepped(up: true);
    }
  });

  testWidgets('one item in a Column with 1,000 children', (tester) async {
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: Column(children: [for (var i = 0; i < 1000; i++) tile(i)]),
        ),
      ),
    );
    final pick = await select(tester, 'Item 3');
    // Up to the ListTile, whose parent is the Column.
    final tilePick = pick.stepped(up: true);
    expect(tilePick.element.widget, isA<ListTile>());

    final note = collectAt(tester, tilePick);
    expect(bytesOf(note), lessThanOrEqualTo(maxPayloadBytes));
    expect(note.siblings!.count, 1000);
    // And the Column itself: 1,000 children in its subtree.
    final column = collectAt(
      tester,
      PickResult.forElement(
        tester.element(find.byType(Column).first),
        rootElement: tester.binding.rootElement!,
      )!,
    );
    expect(bytesOf(column), lessThanOrEqualTo(maxPayloadBytes));
  });

  testWidgets('a huge comment still leaves a note under budget', (
    tester,
  ) async {
    await tester.pumpWidget(host(const Center(child: Text('x'))));
    final pick = await select(tester, 'x');
    final note = ContextCollector().collect(
      pick,
      'long ' * 5000,
      AnnotationIntent.question,
      context: tester.element(find.byType(InspectorOverlay)),
    );
    expect(bytesOf(note), lessThanOrEqualTo(maxPayloadBytes));
    expect(note.truncated, contains('comment'));
  });
}

// The sweep needs the collector and the overlay, which are not public.
// ignore_for_file: implementation_imports

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/capture/context_collector.dart';
import 'package:pinpoint/src/model/annotation.dart' show maxPayloadBytes;
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/search/pick_result.dart';
import 'package:pinpoint/src/search/source_resolver.dart';
import 'package:pinpoint_example/main.dart';

/// Milestone 4 "How to verify": run the collector on every element of
/// every example screen. No collection throws or records an error, every
/// payload is under 8 KB, and the slowest collection is printed.
void main() {
  testWidgets('every element on every example screen', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    final collector = ContextCollector();
    final resolver = SourceResolver.forConfig(const PinPointConfig());
    var count = 0;
    var largest = 0;
    var slowest = Duration.zero;
    var slowestAt = '';

    Future<void> sweep(String screen) async {
      final boundary = tester.element(
        find.byWidgetPredicate(
          (w) =>
              w is KeyedSubtree &&
              w.key.toString().contains('pinpoint app content'),
        ),
      );
      final overlay = tester.element(find.byType(InspectorOverlay));
      final elements = <Element>[];
      final stack = <Element>[];
      boundary.visitChildren(stack.add);
      while (stack.isNotEmpty) {
        final element = stack.removeLast();
        elements.add(element);
        element.visitChildren(stack.add);
      }
      for (final element in elements) {
        final pick = PickResult.forElement(
          element,
          rootElement: tester.binding.rootElement!,
          chainBoundary: boundary,
          resolver: resolver,
        );
        if (pick == null) continue;
        final where = '$screen: ${element.widget.runtimeType}';
        final note = collector.collect(
          pick,
          'Sweep',
          AnnotationIntent.bug,
          context: overlay,
        );
        count++;
        final bytes = utf8.encode(jsonEncode(note.toJson())).length;
        expect(bytes, lessThanOrEqualTo(maxPayloadBytes), reason: where);
        expect(note.errors, isEmpty, reason: where);
        if (bytes > largest) largest = bytes;
        final elapsed = collector.lastElapsed!;
        if (elapsed > slowest) {
          slowest = elapsed;
          slowestAt = where;
        }
      }
    }

    await sweep('Home');
    for (final screen in HomeScreen.screens) {
      await tester.tap(find.text(screen.title));
      // Not pumpAndSettle: the counter screen's spinner never settles.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await sweep(screen.title);
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    debugPrint(
      'pinpoint sweep: $count notes, largest $largest bytes, slowest '
      '${slowest.inMicroseconds / 1000} ms ($slowestAt).',
    );
    expect(count, greaterThan(500));
  });
}

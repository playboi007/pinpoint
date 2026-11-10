import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/info/widget_info.dart';
import 'package:pinpoint/src/overlay/highlight_painter.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';
import 'package:pinpoint/src/search/pick_result.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/markers.dart';

/// Milestone 3, build step 3: the breadcrumb and the project-relative
/// location in the label and the info panel.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host({PinPointConfig config = const PinPointConfig()}) => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(controller: controller, config: config, child: child),
    home: const FixturePage(),
  );

  Finder appText(String text) =>
      find.descendant(of: find.byType(Scaffold), matching: find.text(text));

  Future<PickResult> selectSave(
    WidgetTester tester, {
    PinPointConfig config = const PinPointConfig(),
  }) async {
    await tester.pumpWidget(host(config: config));
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText('Save')));
    await tester.pump();
    return controller.selection.value!;
  }

  final rooted = PinPointConfig(projectRoot: Directory.current.path);
  final saveLine = markerLine(saveBarFixture, 'save_text');

  group('breadcrumb', () {
    testWidgets('the selected widget and the local widgets above it', (
      tester,
    ) async {
      final pick = await selectSave(tester);
      expect(breadcrumbLabel(pick), 'Row > ElevatedButton > Text');
    });

    testWidgets('follows the selection up the chain', (tester) async {
      await selectSave(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        breadcrumbLabel(controller.selection.value!),
        'SaveBar > Padding > Row',
      );
    });

    testWidgets('a framework widget reached with Alt ends the crumbs', (
      tester,
    ) async {
      final text = await selectSave(tester);
      final inner = text.stepped(up: false, localOnly: false);
      expect(inner.element.widget, isA<RichText>());
      expect(breadcrumbLabel(inner), 'ElevatedButton > Text > RichText');
    });

    testWidgets('source unavailable: the widget name alone', (tester) async {
      SourceResolver.debugTrackedOverride = false;
      addTearDown(() => SourceResolver.debugTrackedOverride = null);
      final pick = await selectSave(tester);
      expect(breadcrumbLabel(pick), 'RichText');
      expect(locationLabel(pick), isNull);
    });
  });

  group('location', () {
    testWidgets('relative to the project root', (tester) async {
      final pick = await selectSave(tester, config: rooted);
      expect(locationLabel(pick), '$saveBarFixture:$saveLine');
    });

    testWidgets('without a root, shortened from the package directory', (
      tester,
    ) async {
      final pick = await selectSave(tester);
      final package = Directory.current.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last;
      expect(locationLabel(pick), '$package/$saveBarFixture:$saveLine');
    });
  });

  testWidgets('the outline label shows crumbs, size and location', (
    tester,
  ) async {
    final pick = await selectSave(tester, config: rooted);
    expect(
      highlightLabel(pick),
      'Row > ElevatedButton > Text  '
      '${formatSize(pick.globalRect.size)}  '
      '$saveBarFixture:$saveLine',
    );
  });

  group('info panel', () {
    Finder inPanel(String text) => find.descendant(
      of: find.byKey(InfoPanel.panelKey),
      matching: find.text(text),
    );

    testWidgets('header: widget name and location; body: the crumbs', (
      tester,
    ) async {
      await selectSave(tester, config: rooted);
      expect(inPanel('$saveBarFixture:$saveLine'), findsOneWidget);
      expect(inPanel('Row > ElevatedButton > Text'), findsOneWidget);
      expect(inPanel('RenderParagraph'), findsOneWidget);
    });

    testWidgets('says so when the source is unavailable', (tester) async {
      SourceResolver.debugTrackedOverride = false;
      addTearDown(() => SourceResolver.debugTrackedOverride = null);
      await selectSave(tester, config: rooted);
      expect(inPanel('source unavailable'), findsOneWidget);
    });
  });
}

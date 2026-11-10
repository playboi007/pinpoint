import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/model/source_location.dart';
import 'package:pinpoint/src/search/pick_result.dart';
import 'package:pinpoint/src/search/render_search.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../fixtures/save_bar_fixture.dart';
import '../support/markers.dart';

/// Milestone 3, build step 3: the chain from the picked widget up to the
/// app, and the default selection.
void main() {
  late PinPointController controller;
  Widget? appChild;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host({PinPointConfig config = const PinPointConfig()}) => MaterialApp(
    builder: (context, child) {
      appChild = child;
      return PinPointWrapper(
        controller: controller,
        config: config,
        child: child,
      );
    },
    home: const FixturePage(),
  );

  // The info panel repeats the text, so look in the app only.
  Finder appText(String text) =>
      find.descendant(of: find.byType(Scaffold), matching: find.text(text));

  Future<PickResult> select(WidgetTester tester, String text) async {
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText(text)));
    await tester.pump();
    return controller.selection.value!;
  }

  bool isSdk(SourceLocation? location) =>
      location != null && location.uri.contains('/packages/flutter/');

  group('acceptance', () {
    testWidgets(
      "clicking a button's label selects the Text, with its file and line",
      (tester) async {
        await tester.pumpWidget(host());
        final pick = await select(tester, 'Save');

        expect(pick.element.widget, isA<Text>());
        expect(pick.pickedElement.widget, isA<RichText>());
        expect(pick.sourceUnavailable, isFalse);
        final location = pick.entry.location!;
        expect(Uri.parse(location.uri).path, endsWith(saveBarFixture));
        expect(location.line, markerLine(saveBarFixture, 'save_text'));
        // The outline is the Text's own box.
        expect(pick.globalRect, tester.getRect(appText('Save')));
      },
    );

    testWidgets('no SDK or pub-cache entry appears in the local chain', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      final pick = await select(tester, 'Save');

      final chain = pick.chain;
      final all = [for (var i = 0; i < chain.length; i++) chain[i]];
      final local = chain.localEntries;
      // The full chain holds framework widgets; the local one none of them.
      expect(all.where((e) => isSdk(e.location)), isNotEmpty);
      expect(local, isNotEmpty);
      for (final entry in local) {
        expect(entry.isLocal, isTrue);
        expect(isSdk(entry.location), isFalse, reason: '${entry.location}');
        expect(entry.location!.uri, isNot(contains('.pub-cache')));
      }
      expect(
        local.map((e) => e.name),
        containsAllInOrder(<String>[
          'Text',
          'ElevatedButton',
          'Row',
          'Padding',
          'SaveBar',
          'Column',
          'Center',
          'Scaffold',
        ]),
      );
    });

    testWidgets('without PINPOINT_ROOT the exclusion rule classifies', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      expect(const PinPointConfig().projectRoot, isEmpty);
      final pick = await select(tester, 'Save');
      expect(pick.element.widget, isA<Text>());
      expect(pick.chain.localEntries.map((e) => e.name), contains('SaveBar'));
    });

    testWidgets('with a project root, paths under it are local', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(config: PinPointConfig(projectRoot: Directory.current.path)),
      );
      final pick = await select(tester, 'Save');
      expect(pick.element.widget, isA<Text>());
      expect(pick.sourceUnavailable, isFalse);
    });

    // Profile mode has no creation locations. The resolver is told so; the
    // real profile build is a manual check.
    testWidgets('untracked (profile): selection works, source unavailable', (
      tester,
    ) async {
      SourceResolver.debugTrackedOverride = false;
      addTearDown(() => SourceResolver.debugTrackedOverride = null);
      await tester.pumpWidget(host());

      final pick = await select(tester, 'Save');
      expect(controller.mode, PinPointMode.commenting);
      expect(pick.sourceUnavailable, isTrue);
      expect(pick.element, same(pick.pickedElement));
      expect(pick.element.widget, isA<RichText>());
      expect(pick.entry.location, isNull);
    });
  });

  testWidgets('no local entry: keep the picked widget, source unavailable', (
    tester,
  ) async {
    // A root that holds none of these files.
    await tester.pumpWidget(
      host(config: const PinPointConfig(projectRoot: '/nowhere/app')),
    );
    final pick = await select(tester, 'Save');
    expect(pick.sourceUnavailable, isTrue);
    expect(pick.element.widget, isA<RichText>());
    expect(pick.chain.localEntries, isEmpty);
  });

  // PLAN.md, Milestone 3, watch out: generated files count as local, but
  // the default selection passes over them.
  testWidgets('the default selection skips generated files', (tester) async {
    await tester.pumpWidget(host());
    final pick = await select(tester, 'generated');

    final local = pick.chain.localEntries;
    expect(local.first.name, 'Text');
    expect(local.first.isGenerated, isTrue);
    expect(
      local.first.location!.line,
      markerLine(generatedFixture, 'generated_text'),
    );
    // Selected: the SizedBox around it in the fixture.
    expect(pick.element.widget, isA<SizedBox>());
    expect(pick.entry.isGenerated, isFalse);
  });

  testWidgets('the chain stops at the app, below Pinpoint\'s own wrappers', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final pick = await select(tester, 'Save');
    expect(pick.chain.elements.last.widget, same(appChild));
  });

  testWidgets('entries sharing one render object are all kept', (tester) async {
    await tester.pumpWidget(host());
    final pick = await select(tester, 'Save');
    final local = pick.chain.localEntries;
    final padding = local.firstWhere((e) => e.name == 'Padding');
    final bar = local.firstWhere((e) => e.name == 'SaveBar');
    expect(padding.element.renderObject, same(bar.element.renderObject));
    expect(
      padding.location!.line,
      markerLine(saveBarFixture, 'save_bar_padding'),
    );
    expect(bar.location!.line, markerLine(saveBarFixture, 'save_bar'));
  });

  testWidgets('rulers measure to the nearest local ancestor', (tester) async {
    await tester.pumpWidget(host());
    final pick = await select(tester, 'Save');
    // The next local entry above the Text is the button.
    expect(pick.ancestorRect, tester.getRect(find.byType(ElevatedButton)));
  });

  testWidgets('hover shows what a click would select', (tester) async {
    await tester.pumpWidget(host());
    controller.startPicking();
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(appText('Save')));
    await tester.pump();

    final hovered = controller.hovered.value!;
    expect(hovered.element.widget, isA<Text>());
    expect(hovered.renderObject, isA<RenderParagraph>());
  });

  testWidgets('clicking the same spot again climbs to other widgets', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final first = await select(tester, 'Save');
    await tester.tapAt(tester.getCenter(appText('Save')));
    await tester.pump();
    final second = controller.selection.value!;
    // Every candidate inside the button refines to the button; the next
    // click skips those and lands on the button once.
    expect(second.element.widget, isA<ElevatedButton>());
    expect(second.element, isNot(same(first.element)));
  });

  // Refinement adds to every hover pick: the chain, then entries up to the
  // first local one. Locations are cached per widget, so a cold pick (new
  // widgets under the pointer) costs more than a warm one.
  testWidgets('refining a pick stays well under the 8 ms pick budget', (
    tester,
  ) async {
    const rootKey = Key('root');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            RepaintBoundary(key: rootKey, child: child),
        home: Scaffold(
          appBar: AppBar(title: const Text('Long list')),
          body: ListView.builder(
            itemCount: 500,
            itemBuilder: (context, index) => ListTile(
              leading: CircleAvatar(child: Text('${index + 1}')),
              title: Text('Item ${index + 1}'),
              subtitle: const Text('A subtitle that may wrap.'),
              trailing: const Icon(Icons.more_vert),
            ),
          ),
        ),
      ),
    );
    final root = tester.element(find.byKey(rootKey));
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final random = math.Random(7);
    Offset next() => Offset(
      random.nextDouble() * size.width,
      random.nextDouble() * size.height,
    );
    final searches = [
      for (var i = 0; i < 220; i++)
        RenderSearch.find(root.renderObject!, next()),
    ];

    List<int> time() {
      final micros = <int>[];
      for (final search in searches) {
        final watch = Stopwatch()..start();
        PickResult.fromSearch(search, position: Offset.zero, rootElement: root);
        micros.add(watch.elapsedMicroseconds);
      }
      return micros.sublist(20)..sort();
    }

    final cold = time(); // the first 20 warm up the JIT
    final warm = time();
    debugPrint(
      'pinpoint refine, 200 picks: cold p50 ${cold[100] / 1000} ms, '
      'p95 ${cold[190] / 1000} ms; warm p50 ${warm[100] / 1000} ms, '
      'p95 ${warm[190] / 1000} ms',
    );
    // VM debug. The browser (DDC) is about 20 times slower; a manual check.
    expect(warm[190] / 1000, lessThan(0.5));
  });
}

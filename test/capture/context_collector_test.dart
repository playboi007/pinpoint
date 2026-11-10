import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/capture/context_collector.dart';
import 'package:pinpoint/src/model/source_location.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/search/pick_result.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../fixtures/annotation_fixture.dart';
import '../support/markers.dart';

/// Milestone 4, build step 2: one collector per payload field, each wrapped
/// so a failure is recorded and the note is still built.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() {
    controller.dispose();
    ContextCollector.debugFailFields = const {};
  });

  final root = Directory.current.path;

  Widget host({
    Widget home = const OrderPage(),
    PinPointConfig? config,
    ThemeMode themeMode = ThemeMode.light,
    TransitionBuilder? around,
  }) => MaterialApp(
    theme: ThemeData(),
    darkTheme: ThemeData(brightness: Brightness.dark),
    themeMode: themeMode,
    builder: (context, child) => PinPointWrapper(
      controller: controller,
      config: config ?? PinPointConfig(projectRoot: root),
      child: around == null ? child : around(context, child),
    ),
    home: home,
  );

  ContextCollector collector({Uri? url}) => ContextCollector(
    clock: () => DateTime.utc(2026, 11, 10, 14, 32, 5),
    random: math.Random(7),
    pageUrl: () => url,
  );

  // The info panel repeats the text, so look in the app only.
  Finder appText(String text) => find
      .descendant(
        of: find.byKey(const ValueKey<String>('pinpoint.app')),
        matching: find.text(text),
      )
      .first;

  Future<PickResult> select(WidgetTester tester, String text) async {
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText(text)));
    await tester.pump();
    return controller.selection.value!;
  }

  Future<PickResult> selectUp(
    WidgetTester tester,
    String text,
    int steps,
  ) async {
    await select(tester, text);
    for (var i = 0; i < steps; i++) {
      controller.stepSelection(up: true);
    }
    return controller.selection.value!;
  }

  BuildContext overlayContext(WidgetTester tester) =>
      tester.element(find.byType(InspectorOverlay));

  Annotation collect(
    WidgetTester tester,
    PickResult pick, {
    Uri? url,
    String comment = 'Label truncates',
  }) => collector(url: url).collect(
    pick,
    comment,
    AnnotationIntent.improve,
    context: overlayContext(tester),
  );

  Widget keyed(Widget child) =>
      KeyedSubtree(key: const ValueKey<String>('pinpoint.app'), child: child);

  group('acceptance', () {
    testWidgets('every source.file is project-relative when the root is set', (
      tester,
    ) async {
      await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
      final note = collect(tester, await select(tester, 'Save changes'));

      final source = note.target.source!;
      expect(source.file, annotationFixture);
      expect(source.line, markerLine(annotationFixture, 'bar_text'));
      final files = [
        source.file,
        for (final a in note.ancestors) ?a.source?.file,
      ];
      expect(files.length, greaterThan(3));
      for (final file in files) {
        expect(file, isNot(startsWith('/')), reason: file);
        expect(file, isNot(contains('file:')), reason: file);
        expect(file, isNot(contains(root)), reason: file);
      }
      expect(note.subtree, contains('$annotationFixture:'));
      expect(note.subtree, isNot(contains(root)));
      expect(note.app.projectRoot, root);
    });

    testWidgets('without a root, paths are absolute with file:// stripped', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          config: const PinPointConfig(projectRoot: ''),
          around: (_, child) => keyed(child!),
        ),
      );
      final note = collect(tester, await select(tester, 'Save changes'));

      final file = note.target.source!.file;
      expect(file, startsWith('/'));
      expect(file, endsWith(annotationFixture));
      expect(file, isNot(contains('file:')));
      expect(note.app.projectRoot, isNull);
    });

    testWidgets('collecting does not rebuild the target', (tester) async {
      await tester.pumpWidget(
        host(
          home: const Scaffold(
            body: Center(child: BuildCounter(child: Text('counted'))),
          ),
          themeMode: ThemeMode.system,
          around: (_, child) => keyed(child!),
        ),
      );
      // Text, then the BuildCounter around it.
      final pick = await selectUp(tester, 'counted', 1);
      expect(pick.element.widget, isA<BuildCounter>());
      final before = BuildCounter.builds;

      final note = collect(tester, pick);
      await tester.pump();
      expect(note.target.widget, 'BuildCounter');
      expect(BuildCounter.builds, before);

      // Change everything the collector read. A subscribed target would
      // rebuild now.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      addTearDown(tester.view.reset);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(BuildCounter.builds, before);
    });
  });

  group('page', () {
    testWidgets('records the viewport, scale, brightness, locale and route', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
      final note = collect(tester, await select(tester, 'Save changes'));

      final page = note.page.toJson();
      expect(page['viewport'], {'width': 800, 'height': 600});
      expect(page['devicePixelRatio'], 3);
      expect(page['textScale'], 1.5);
      expect(page['brightness'], 'dark');
      expect(page['locale'], 'en_US');
      expect(page['route'], '/');
      // Not on web: no URL.
      expect(page['url'], isNull);
    });

    testWidgets('a widget above the Navigator takes its route from the URL', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          around: (_, child) => keyed(
            Column(
              children: [
                const Text('banner'),
                Expanded(child: child!),
              ],
            ),
          ),
        ),
      );
      final pick = await select(tester, 'banner');

      final hash = collect(
        tester,
        pick,
        url: Uri.parse('http://localhost:5000/#/orders/12'),
      );
      expect(hash.page.url, 'http://localhost:5000/#/orders/12');
      expect(hash.page.route, '/orders/12');

      final path = collect(
        tester,
        pick,
        url: Uri.parse('http://localhost:5000/orders/12?tab=2'),
      );
      expect(path.page.route, '/orders/12');

      expect(collect(tester, pick).page.route, isNull);
      expect(collect(tester, pick).errors, isEmpty);
    });
  });

  testWidgets('the route is read safely for any element, the route\'s own '
      'inherited element included', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) =>
            PinPointWrapper(controller: controller, child: child),
        home: const OrderPage(),
      ),
    );
    // Every element between the app and the page's label, the route's
    // own `_ModalScopeStatus` among them.
    final label = tester.element(find.text('Save changes'));
    final elements = <Element>[label];
    label.visitAncestorElements((e) {
      elements.add(e);
      return e.widget is! Navigator;
    });
    expect(
      elements.map((e) => e.widget.runtimeType.toString()),
      contains('_ModalScopeStatus'),
    );
    for (final element in elements) {
      final pick = PickResult.forElement(
        element,
        rootElement: tester.binding.rootElement!,
      );
      if (pick == null) continue;
      collect(tester, pick);
    }
    final route = collect(
      tester,
      PickResult.forElement(
        elements.firstWhere(
          (e) => e.widget.runtimeType.toString() == '_ModalScopeStatus',
        ),
        rootElement: tester.binding.rootElement!,
      )!,
    ).page.route;
    expect(route, '/');

    // A new route changes the old route's status, which notifies its
    // dependents. A self-dependency would assert here.
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('next')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('inherited values are read without subscribing', (tester) async {
    await tester.pumpWidget(
      host(
        themeMode: ThemeMode.dark,
        home: const Directionality(
          textDirection: TextDirection.rtl,
          child: OrderPage(),
        ),
        around: (_, child) => keyed(child!),
      ),
    );
    final note = collect(tester, await select(tester, 'Save changes'));

    expect(note.inherited!.toJson(), {
      'themeBrightness': 'dark',
      'useMaterial3': true,
      'textDirection': 'rtl',
    });
  });

  group('chains', () {
    testWidgets('ancestors are the local chain above the target, nearest '
        'first', (tester) async {
      await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
      final note = collect(tester, await select(tester, 'Save changes'));

      final names = [for (final a in note.ancestors) a.widget];
      expect(names.take(4), [
        'ElevatedButton',
        'Row',
        'Padding',
        'SaveChangesBar',
      ]);
      expect(names, isNot(contains('Text')));
      expect(
        note.ancestors.first.source!.line,
        markerLine(annotationFixture, 'bar_button'),
      );
      expect(
        note.ancestors[3].source!.line,
        markerLine(annotationFixture, 'order_save_bar'),
      );
    });

    testWidgets('frameworkChain holds plain type names from the picked '
        'widget up', (tester) async {
      await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
      final note = collect(tester, await select(tester, 'Save changes'));

      final chain = note.frameworkChain;
      expect(chain.first, 'RichText');
      expect(chain[1], 'Text');
      // A button's own widgets fill the 40 names before SaveChangesBar.
      expect(chain, hasLength(ContextCollector.maxFrameworkChain));
      for (final name in chain) {
        expect(name, matches(RegExp(r'^[A-Za-z0-9_<>, ]+$')), reason: name);
      }
      // Never past the app's own widgets into Pinpoint's.
      expect(chain, isNot(contains('PinPointWrapper')));
      expect(chain, isNot(contains('RepaintBoundary')));
    });

    testWidgets('ancestors stop at 12 and frameworkChain at 40', (
      tester,
    ) async {
      Widget nest(int depth, Widget child) => depth == 0
          ? child
          : Padding(padding: EdgeInsets.zero, child: nest(depth - 1, child));
      await tester.pumpWidget(
        host(
          home: Scaffold(body: nest(60, const Text('deep'))),
          around: (_, child) => keyed(child!),
        ),
      );
      final note = collect(tester, await select(tester, 'deep'));

      expect(note.ancestors, hasLength(12));
      expect(note.frameworkChain, hasLength(40));
    });
  });

  group('siblings', () {
    testWidgets('lists the nearest multi-child parent and the target branch', (
      tester,
    ) async {
      await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
      // Text, then the ElevatedButton in the Row.
      final note = collect(tester, await selectUp(tester, 'Save changes', 1));

      expect(note.target.widget, 'ElevatedButton');
      expect(note.siblings!.toJson(), {
        'parent': 'Row',
        'index': 1,
        'count': 3,
        'firstIndex': 0,
        'children': ['Icon', 'ElevatedButton', 'SizedBox'],
      });
    });

    testWidgets('a long parent gives a window of 12 around the target', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < 1000; i++)
                    SizedBox(height: 1, child: Text('row $i')),
                ],
              ),
            ),
          ),
          around: (_, child) => keyed(child!),
        ),
      );
      final pick = await select(tester, 'row 300');
      // Text, then its SizedBox, which is the Column's child.
      final note = collect(tester, pick);
      final siblings = note.siblings!;

      expect(siblings.parent, 'Column');
      expect(siblings.count, 1000);
      expect(siblings.index, 300);
      expect(siblings.children, hasLength(12));
      expect(siblings.firstIndex, lessThanOrEqualTo(300));
      expect(siblings.firstIndex + 12, greaterThan(300));
    });
  });

  group('subtree', () {
    testWidgets('is indented, at most 4 levels, with file:line on local '
        'widgets', (tester) async {
      await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
      // Text, ElevatedButton, Row, Padding, then SaveChangesBar.
      final note = collect(tester, await selectUp(tester, 'Save changes', 4));
      expect(note.target.widget, 'SaveChangesBar');

      final lines = note.subtree!.split('\n');
      final barLine = markerLine(annotationFixture, 'order_save_bar');
      final paddingLine = markerLine(annotationFixture, 'bar_padding');
      final rowLine = markerLine(annotationFixture, 'bar_row');
      expect(lines.take(3), [
        'SaveChangesBar  $annotationFixture:$barLine',
        '  Padding  $annotationFixture:$paddingLine',
        '    Row  $annotationFixture:$rowLine',
      ]);
      // Level 4 is the deepest; a node there with children ends in "…".
      final depths = [
        for (final l in lines) (l.length - l.trimLeft().length) ~/ 2,
      ];
      expect(depths.reduce(math.max), 3);
      expect(
        lines,
        contains(
          '      ElevatedButton  $annotationFixture:'
          '${markerLine(annotationFixture, 'bar_button')} …',
        ),
      );
    });

    testWidgets('stops at 40 nodes', (tester) async {
      await tester.pumpWidget(
        host(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < 100; i++)
                    SizedBox(height: 1, child: Text('row $i')),
                ],
              ),
            ),
          ),
          around: (_, child) => keyed(child!),
        ),
      );
      // Text, SizedBox, Column.
      final note = collect(tester, await selectUp(tester, 'row 3', 2));
      expect(note.target.widget, 'Column');

      final lines = note.subtree!.split('\n');
      expect(lines, hasLength(41));
      expect(lines.last, '…');
    });
  });

  testWidgets('a field that fails is recorded and the note is still built', (
    tester,
  ) async {
    await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
    final pick = await select(tester, 'Save changes');
    ContextCollector.debugFailFields = const {'siblings', 'page'};

    final note = collect(tester, pick);
    expect(note.errors, ['page', 'siblings']);
    expect(note.siblings, isNull);
    expect(note.page.toJson().values, everyElement(isNull));
    expect(note.target.source, isNotNull);
    expect(note.subtree, isNotNull);
    expect(note.toJson()['errors'], ['page', 'siblings']);
  });

  testWidgets('id, time, intent, comment and app', (tester) async {
    await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
    final note = collect(tester, await select(tester, 'Save changes'));

    expect(note.id, matches(RegExp(r'^pp_20261110_143205_[0-9a-f]{4}$')));
    expect(note.createdAt, DateTime.utc(2026, 11, 10, 14, 32, 5));
    expect(note.intent, AnnotationIntent.improve);
    expect(note.comment, 'Label truncates');
    expect(note.app.toJson(), {
      'buildMode': 'debug',
      'platform': 'android',
      'projectRoot': root,
      'origin': null,
    });
    expect(note.errors, isEmpty);
  });

  testWidgets('PickResult.forElement selects the element itself', (
    tester,
  ) async {
    await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
    final element = tester.element(find.byType(SaveChangesBar));
    final pick = PickResult.forElement(
      element,
      rootElement: tester.binding.rootElement!,
      chainBoundary: tester.element(
        find.byKey(const ValueKey<String>('pinpoint.app')),
      ),
      resolver: SourceResolver(paths: SourcePaths(projectRoot: root)),
    )!;

    expect(pick.element, same(element));
    expect(pick.pickedElement, same(element));
    expect(pick.globalRect, tester.getRect(find.byType(SaveChangesBar)));
    expect(pick.sourceUnavailable, isFalse);
    final note = collect(tester, pick);
    expect(note.target.widget, 'SaveChangesBar');
    expect(note.frameworkChain.first, 'SaveChangesBar');
  });
}

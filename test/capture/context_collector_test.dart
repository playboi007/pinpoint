import 'dart:async';

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
      expect(path.page.url, 'http://localhost:5000/orders/12?tab=***');

      expect(collect(tester, pick).page.route, isNull);
      expect(collect(tester, pick).errors, isEmpty);
    });
  });

  // PLAN-v3 Milestone 19, step 3: a page URL often holds a session token.
  testWidgets('page.url has every query value masked, names kept', (
    tester,
  ) async {
    await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
    final pick = await select(tester, 'Save changes');
    String? urlOf(String url) =>
        collect(tester, pick, url: Uri.parse(url)).page.url;

    expect(
      urlOf('http://localhost:5000/orders?token=eyJfaketoken.part2&tab=2'),
      'http://localhost:5000/orders?token=***&tab=***',
    );
    // Hash routing: the query inside the fragment.
    expect(
      urlOf('http://localhost:5000/#/orders/12?token=eyJfake&view=full'),
      'http://localhost:5000/#/orders/12?token=***&view=***',
    );
    // A fragment that is only a query (an implicit OAuth answer).
    expect(
      urlOf('http://localhost:5000/#access_token=eyJfake&state=abc'),
      'http://localhost:5000/#access_token=***&state=***',
    );
    // Nothing to mask: unchanged.
    expect(
      urlOf('http://localhost:5000/#/orders/12'),
      'http://localhost:5000/#/orders/12',
    );
    // The route is still read from the real URL.
    expect(
      ContextCollector.routeFromUrl(
        Uri.parse('http://localhost:5000/#/orders/12?token=eyJfake'),
      ),
      '/orders/12',
    );
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
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('next')),
      ),
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

    // PLAN-v3 Milestone 19, step 5.
    testWidgets('wrappers that explain nothing are skipped, layout widgets '
        'and the others kept', (tester) async {
      await tester.pumpWidget(
        host(
          home: Scaffold(
            body: Semantics(
              container: true,
              child: Builder(
                builder: (_) => Padding(
                  padding: EdgeInsets.zero,
                  child: MergeSemantics(
                    child: Container(
                      color: Colors.transparent,
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: RepaintBoundary(
                          child: _Marker(child: Text('wrapped')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          around: (_, child) => keyed(child!),
        ),
      );
      final note = collect(tester, await select(tester, 'wrapped'));

      final names = [for (final a in note.ancestors) a.widget];
      expect(names.take(3), ['_Marker', 'Container', 'Padding']);
      for (final skipped in ContextCollector.skippedAncestors) {
        expect(names, isNot(contains(skipped)));
      }
      expect(
        names,
        isNot(contains('NotificationListener<ScrollNotification>')),
      );
    });

    testWidgets('ancestors stop at 8, after the skip', (tester) async {
      Widget nest(int depth, Widget child) => depth == 0
          ? child
          : Semantics(
              child: Padding(
                padding: EdgeInsets.zero,
                child: nest(depth - 1, child),
              ),
            );
      await tester.pumpWidget(
        host(
          home: Scaffold(body: nest(30, const Text('deep'))),
          around: (_, child) => keyed(child!),
        ),
      );
      final note = collect(tester, await select(tester, 'deep'));

      expect(ContextCollector.maxAncestors, 8);
      expect(note.ancestors, hasLength(8));
      expect(
        [for (final a in note.ancestors) a.widget],
        everyElement('Padding'),
        reason: 'the Semantics between them were skipped',
      );
    });

    // PLAN-v3 Milestone 19, step 4.
    testWidgets('frameworkChain is gone from the note', (tester) async {
      await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
      final note = collect(tester, await select(tester, 'Save changes'));
      expect(note.toJson().containsKey('frameworkChain'), isFalse);
    });

    testWidgets('stateOwners: a local State and a provider-like scope, '
        'nearest first', (tester) async {
      await tester.pumpWidget(
        host(
          home: const Scaffold(
            body: _InheritedProviderScope<_Model?>(
              child: _Counter(child: Text('owned')),
            ),
          ),
          around: (_, child) => keyed(child!),
        ),
      );
      final note = collect(tester, await select(tester, 'owned'));

      expect(
        [for (final o in note.stateOwners) (o.kind, o.type)],
        [('state', '_CounterState'), ('provider', '_Model')],
      );
      expect(
        note.stateOwners.first.source!.file,
        contains('context_collector_test.dart'),
      );
      expect(note.stateOwners.last.source, isNotNull);
      // Framework State objects (Scaffold, MaterialApp...) are not listed.
      expect([
        for (final o in note.stateOwners) o.type,
      ], isNot(contains('ScaffoldState')));
      expect(note.toJson()['stateOwners'], hasLength(2));
    });

    testWidgets('stateOwners: a local widget that reads a scope is a reader '
        'with its dependencies; a State with none has none', (tester) async {
      await tester.pumpWidget(
        host(
          home: const Scaffold(
            body: _InheritedProviderScope<_Model?>(
              child: _Counter(child: _Reads(child: Text('reads'))),
            ),
          ),
          around: (_, child) => keyed(child!),
        ),
      );
      final note = collect(tester, await select(tester, 'reads'));

      expect(
        [for (final o in note.stateOwners) (o.kind, o.type)],
        [
          ('reader', '_Reads'),
          ('state', '_CounterState'),
          ('provider', '_Model'),
        ],
      );
      final reads = note.stateOwners.first.dependencies.single;
      expect((reads.kind, reads.type), ('provider', '_Model'));
      expect(reads.tag, matches(RegExp(r'^#a\d+$')));
      expect(reads.source!.file, contains('context_collector_test.dart'));
      // MediaQuery and Theme are read by the same widget, and left out.
      expect(note.stateOwners[1].dependencies, isEmpty);
      final json = note.toJson()['stateOwners']! as List<Object?>;
      expect((json.first! as Map)['dependencies'], hasLength(1));
      expect((json[1]! as Map).containsKey('dependencies'), isFalse);
    });

    testWidgets('stateOwners stop at 4', (tester) async {
      await tester.pumpWidget(
        host(
          home: const Scaffold(
            body: _Counter(
              child: _Counter(
                child: _Counter(
                  child: _Counter(
                    child: _Counter(child: _Counter(child: Text('many'))),
                  ),
                ),
              ),
            ),
          ),
          around: (_, child) => keyed(child!),
        ),
      );
      final note = collect(tester, await select(tester, 'many'));
      expect(note.stateOwners, hasLength(ContextCollector.maxStateOwners));
    });

    testWidgets('a note with no state owner has none', (tester) async {
      await tester.pumpWidget(host(around: (_, child) => keyed(child!)));
      final note = collect(tester, await select(tester, 'Save changes'));
      expect(note.stateOwners, isEmpty);
      expect(note.toJson().containsKey('stateOwners'), isFalse);
    });
  });

  // PLAN-v3 Milestone 19, step 8.
  group('lean properties', () {
    testWidgets('no hash codes, no null parts', (tester) async {
      await tester.pumpWidget(
        host(
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                style: ButtonStyle(
                  textStyle: const WidgetStatePropertyAll<TextStyle?>(null),
                  padding: WidgetStatePropertyAll(const EdgeInsets.all(8)),
                ),
                onPressed: () {},
                child: const Text('Go'),
              ),
            ),
          ),
          around: (_, child) => keyed(child!),
        ),
      );
      final note = collect(tester, await selectUp(tester, 'Go', 1));
      expect(note.target.widget, 'ElevatedButton');

      final style = note.target.properties['style'];
      expect(style, isNotNull);
      expect(style, isNot(matches(RegExp(r'#[0-9a-f]{5}'))));
      expect(style, isNot(contains('null')));
      expect(style, contains('padding'));
      for (final value in note.target.properties.values) {
        expect(value, isNot(matches(RegExp(r'[A-Za-z]#[0-9a-f]{5}'))));
        expect(value, isNot(contains(': null')));
      }
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

    // PLAN-v3 Milestone 19, step 7.
    testWidgets('leaves out rows with no source location and shows their '
        'local children at their depth', (tester) async {
      await tester.pumpWidget(
        host(
          home: Scaffold(
            body: Container(
              padding: const EdgeInsets.all(4),
              color: Colors.white,
              child: const _Marker(child: Text('inside')),
            ),
          ),
          around: (_, child) => keyed(child!),
        ),
      );
      // Text, _Marker, then the Container.
      final note = collect(tester, await selectUp(tester, 'inside', 2));
      expect(note.target.widget, 'Container');

      final lines = note.subtree!.split('\n');
      // The Container builds a Padding and a ColoredBox inside the
      // framework. They have no location: no row of their own.
      expect(
        [for (final l in lines) l.trim().split(' ').first],
        ['Container', '_Marker', 'Text'],
      );
      expect(
        lines.map((l) => (l.length - l.trimLeft().length) ~/ 2),
        [0, 1, 2],
        reason: '_Marker is a child of Container once the Padding is left out',
      );
      for (final line in lines) {
        expect(line, contains('context_collector_test.dart:'));
      }
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
  });
}

/// A widget the project made, for the ancestor list: it explains the code.
class _Marker extends StatelessWidget {
  const _Marker({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// A widget with a State the project made.
class _Counter extends StatefulWidget {
  const _Counter({required this.child});

  final Widget child;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  Widget build(BuildContext context) => widget.child;
}

class _Model {}

/// A stateless widget that reads the scope in `build`, as `context.watch`
/// does, and `MediaQuery` too.
class _Reads extends StatelessWidget {
  const _Reads({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    context
        .dependOnInheritedWidgetOfExactType<_InheritedProviderScope<_Model?>>();
    MediaQuery.of(context);
    return child;
  }
}

/// Named like the `provider` package's scope: the collector reads the
/// name, and the value type from its generic argument.
class _InheritedProviderScope<T> extends InheritedWidget {
  const _InheritedProviderScope({required super.child});

  @override
  bool updateShouldNotify(_InheritedProviderScope<T> oldWidget) => false;
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/agent/synthetic_input.dart';

import '../support/agent_host.dart';

/// Milestone 12, build step 4: `wait_idle`, then the driving tools: `tap`,
/// `long_press`, `scroll`, `scroll_to`, `enter_text`, `navigate`, `back`.
void main() {
  late PinPointController controller;
  late AgentBridge bridge;
  late _Log log;

  setUp(() {
    controller = PinPointController();
    bridge = AgentBridge();
    log = _Log();
  });
  tearDown(() => controller.dispose());

  Future<void> pumpApp(
    WidgetTester tester,
    Widget home, {
    Map<String, WidgetBuilder> routes = const {},
  }) async {
    await tester.pumpWidget(
      agentApp(controller: controller, home: home, routes: routes),
    );
    await tester.pump();
    controller.agent.enabled = true;
    await tester.pump();
  }

  // Navigation answers through the platform channel's own zone, outside
  // the test's fake clock: those calls need real time to finish.
  Future<Map<String, Object?>> run(
    WidgetTester tester,
    String tool, [
    Map<String, Object?> args = const {},
  ]) => drive(
    tester,
    controller.agent.run(tool, args),
    realTime: tool == 'navigate' || tool == 'back',
  );

  Future<Map<String, Object?>> ok(
    WidgetTester tester,
    String tool, [
    Map<String, Object?> args = const {},
  ]) async {
    final answer = await run(tester, tool, args);
    expect(answer['ok'], isTrue, reason: '$tool: $answer');
    return answer['result']! as Map<String, Object?>;
  }

  Future<String> handle(WidgetTester tester, Map<String, Object?> query) async {
    final result = await ok(tester, 'find_widgets', query);
    final widgets = result['widgets']! as List<Object?>;
    return (widgets.first! as Map)['handle']! as String;
  }

  group('tap', () {
    testWidgets('acceptance: tap on a button fires onPressed', (tester) async {
      await pumpApp(tester, _Buttons(log: log));
      final save = await handle(tester, {'type': 'ElevatedButton'});
      final result = await ok(tester, 'tap', {'handle': save});
      expect(log.events, ['save']);
      expect(result['tapped'], hasLength(2));
      // A dot where it landed.
      expect(controller.agent.marks.value, hasLength(1));
      await bridge.shutdown(tester);
    });

    testWidgets('acceptance: tap on a button under a dialog barrier returns '
        '"obscured" and does not tap', (tester) async {
      await pumpApp(tester, _Buttons(log: log));
      final save = await handle(tester, {'type': 'ElevatedButton'});
      await tester.tap(find.text('Open dialog'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      log.events.clear();
      final answer = await run(tester, 'tap', {'handle': save});
      expect(answer['ok'], isFalse);
      expect(answer['error'], 'obscured by ModalBarrier');
      // Under the dialog box itself: the dialog is named.
      final under = await handle(tester, {'text': 'Under'});
      final boxed = await run(tester, 'tap', {'handle': under});
      expect(boxed['error'], 'obscured by AlertDialog');
      await tester.pump(const Duration(seconds: 1));
      expect(log.events, isEmpty);
      expect(find.text('A dialog'), findsOneWidget, reason: 'still open');
      await bridge.shutdown(tester);
    });

    testWidgets('watch out for: picking mode is left first, so its pointer '
        'trap does not swallow the tap', (tester) async {
      await pumpApp(tester, _Buttons(log: log));
      controller.startPicking();
      await tester.pump();
      final save = await handle(tester, {'type': 'ElevatedButton'});
      await ok(tester, 'tap', {'handle': save});
      expect(log.events, ['save']);
      expect(controller.mode, PinPointMode.idle);
      await bridge.shutdown(tester);
    });

    testWidgets('while the user writes a note, the agent waits its turn', (
      tester,
    ) async {
      await pumpApp(tester, _Buttons(log: log));
      final save = await handle(tester, {'type': 'ElevatedButton'});
      controller.startPicking();
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.text('Open dialog')));
      await tester.pump();
      expect(controller.mode, PinPointMode.commenting);
      final answer = await run(tester, 'tap', {'handle': save});
      expect(answer['error'], contains('the user is writing a note'));
      expect(log.events, isEmpty);
      controller.stop();
      await bridge.shutdown(tester);
    });

    testWidgets('the events: touch kind, a private pointer range, increasing '
        'time stamps, about 50 ms between down and up', (tester) async {
      await pumpApp(tester, _Buttons(log: log));
      final save = await handle(tester, {'type': 'ElevatedButton'});
      await ok(tester, 'tap', {'handle': save});
      final events = log.pointer;
      expect(events, hasLength(2));
      expect(events[0], isA<PointerDownEvent>());
      expect(events[1], isA<PointerUpEvent>());
      for (final event in events) {
        expect(event.kind, PointerDeviceKind.touch);
        expect(event.device, greaterThanOrEqualTo(SyntheticInput.deviceBase));
      }
      final held = events[1].timeStamp - events[0].timeStamp;
      expect(held, greaterThanOrEqualTo(const Duration(milliseconds: 50)));
      await bridge.shutdown(tester);
    });

    testWidgets('long_press fires onLongPress', (tester) async {
      await pumpApp(tester, _Buttons(log: log));
      final save = await handle(tester, {'type': 'ElevatedButton'});
      await ok(tester, 'long_press', {'handle': save});
      expect(log.events, ['hold']);
      await bridge.shutdown(tester);
    });

    testWidgets('a widget scrolled out of view is not tapped', (tester) async {
      await pumpApp(tester, const _LongList());
      final item = await handle(tester, {'text': 'Item 2'});
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .jumpTo(2000);
      await tester.pump();
      final answer = await run(tester, 'tap', {'handle': item});
      expect(answer['ok'], isFalse);
      expect(
        answer['error'],
        anyOf(contains('not on screen'), startsWith('stale')),
      );
      await bridge.shutdown(tester);
    });
  });

  group('enter_text', () {
    testWidgets('acceptance: enter_text updates the field, runs its formatter '
        'and calls onChanged', (tester) async {
      await pumpApp(tester, _Form(log: log));
      final field = await handle(tester, {'key': 'code'});
      final result = await ok(tester, 'enter_text', {
        'handle': field,
        'text': 'ab12cd',
      });
      expect(result['text'], 'AB12CD', reason: 'the formatter ran');
      expect(log.events, ['changed AB12CD']);
      expect(find.text('AB12CD'), findsOneWidget);
      expect(result['focused'], isTrue);
      await bridge.shutdown(tester);
    });

    testWidgets('an obscured field is never echoed back', (tester) async {
      await pumpApp(tester, _Form(log: log));
      final field = await handle(tester, {'key': 'password'});
      final result = await ok(tester, 'enter_text', {
        'handle': field,
        'text': 'hunter2',
      });
      expect(result['text'], '[masked]');
      final found = await ok(tester, 'find_widgets', {'key': 'password'});
      final widget = (found['widgets']! as List).first! as Map;
      expect(widget['value'], '[masked]');
      await bridge.shutdown(tester);
    });

    testWidgets('a read-only field is refused', (tester) async {
      await pumpApp(tester, _Form(log: log));
      final field = await handle(tester, {'key': 'locked'});
      final answer = await run(tester, 'enter_text', {
        'handle': field,
        'text': 'x',
      });
      expect(answer['error'], contains('read only'));
      await bridge.shutdown(tester);
    });
  });

  group('wait_idle', () {
    testWidgets('acceptance: returns idle: false on a looping spinner, '
        'without hanging', (tester) async {
      await pumpApp(tester, const _Spinner());
      final result = await ok(tester, 'wait_idle', {'timeout_ms': 500});
      expect(result['idle'], isFalse);
      await bridge.shutdown(tester);
    });

    testWidgets('returns idle: true on a still screen', (tester) async {
      await pumpApp(tester, _Buttons(log: log));
      final result = await ok(tester, 'wait_idle', {'timeout_ms': 1000});
      expect(result['idle'], isTrue);
      await bridge.shutdown(tester);
    });
  });

  group('scroll', () {
    testWidgets('scroll moves the nearest scrollable', (tester) async {
      await pumpApp(tester, const _LongList());
      final list = await handle(tester, {'type': 'ListView'});
      final result = await ok(tester, 'scroll', {'handle': list, 'dy': 400});
      expect(result['pixels'], 400);
      final item = await handle(tester, {'text': 'Item 3'});
      final again = await ok(tester, 'scroll', {'handle': item, 'dy': -100});
      expect(again['pixels'], 300, reason: 'from an item: its list');
      await bridge.shutdown(tester);
    });

    testWidgets('watch out for: scroll_to finds a lazy item that was never '
        'built, by scrolling and searching again', (tester) async {
      await pumpApp(tester, const _LongList());
      expect(
        (await ok(tester, 'find_widgets', {'text': 'Item 300'}))['widgets'],
        isEmpty,
      );
      final result = await ok(tester, 'scroll_to', {'text': 'Item 300'});
      final found = result['widget']! as Map<String, Object?>;
      expect(found['text'], 'Item 300');
      expect(found['visible'], isTrue);
      expect(find.text('Item 300'), findsOneWidget);
      // And tap it through its new handle.
      await ok(tester, 'tap', {'handle': found['handle']});
      expect(find.text('tapped 300'), findsOneWidget);
      await bridge.shutdown(tester);
    });

    testWidgets('scroll_to gives up at its step limit', (tester) async {
      await pumpApp(tester, const _LongList());
      final answer = await run(tester, 'scroll_to', {
        'text': 'Item 900',
        'max_steps': 3,
      });
      expect(answer['ok'], isFalse);
      expect(answer['error'], contains('not found after 3 steps'));
      await bridge.shutdown(tester);
    });

    testWidgets('scroll_to with a handle brings it into view', (tester) async {
      await pumpApp(tester, const _LongList());
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .jumpTo(110);
      await tester.pump();
      final top = tester.getTopLeft(find.byType(ListView)).dy;
      final item = await handle(tester, {'text': 'Item 2'});
      expect(
        tester.getRect(find.byType(ListTile).first).top,
        lessThan(top),
        reason: 'partly scrolled away',
      );
      final result = await ok(tester, 'scroll_to', {'handle': item});
      expect((result['widget']! as Map)['visible'], isTrue);
      expect(
        tester.getRect(find.text('Item 2')).top,
        greaterThanOrEqualTo(top),
      );
      await bridge.shutdown(tester);
    });
  });

  group('navigate and back', () {
    testWidgets('acceptance: navigate works with named routes', (tester) async {
      await pumpApp(
        tester,
        const _Page('home'),
        routes: {'/detail': (_) => const _Page('detail')},
      );
      final result = await ok(tester, 'navigate', {'path': '/detail'});
      expect(result['handled'], isTrue);
      expect(result['route'], '/detail');
      expect(find.text('page detail'), findsOneWidget);

      final back = await ok(tester, 'back');
      expect(back['handled'], isTrue);
      expect(find.text('page home'), findsOneWidget);
      expect(find.text('page detail'), findsNothing);
      await bridge.shutdown(tester);
    });

    testWidgets('acceptance: navigate works with a Router', (tester) async {
      final delegate = _Delegate();
      addTearDown(delegate.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: RouterConfig<String>(
            routeInformationProvider: PlatformRouteInformationProvider(
              initialRouteInformation: RouteInformation(uri: Uri.parse('/')),
            ),
            routeInformationParser: _Parser(),
            routerDelegate: delegate,
            backButtonDispatcher: RootBackButtonDispatcher(),
          ),
          builder: (context, child) => PinPointWrapper(
            controller: controller,
            config: PinPointConfig(bridgeUrl: AgentBridge.url),
            child: child,
          ),
        ),
      );
      await tester.pump();
      controller.agent.enabled = true;
      await tester.pump();
      expect(find.text('page /'), findsOneWidget);

      final result = await ok(tester, 'navigate', {'path': '/settings'});
      expect(result['handled'], isTrue);
      expect(delegate.stack, ['/', '/settings']);
      expect(find.text('page /settings'), findsOneWidget);

      final back = await ok(tester, 'back');
      expect(back['handled'], isTrue);
      expect(delegate.stack, ['/']);
      await bridge.shutdown(tester);
    });

    testWidgets('an unknown route is not handled', (tester) async {
      await pumpApp(tester, const _Page('home'));
      final answer = await run(tester, 'navigate', {'path': ''});
      expect(answer['ok'], isFalse);
      expect(answer['error'], contains('path'));
      await bridge.shutdown(tester);
    });
  });

  group('run_steps', () {
    testWidgets('acceptance: type, scroll the page and tap in one call, '
        'with widgets named by target', (tester) async {
      await pumpApp(tester, _LongForm(log: log));
      final result = await ok(tester, 'run_steps', {
        'steps': [
          {
            'tool': 'enter_text',
            'target': {'key': 'name'},
            'text': 'Ada',
          },
          // From the field: its own horizontal scrollable must not take
          // the dy; the page moves.
          {
            'tool': 'scroll',
            'target': {'key': 'name'},
            'dy': 400,
          },
          {
            'tool': 'tap',
            'target': {'text': 'Save'},
          },
          {'tool': 'find_widgets', 'type': 'TextField'},
          {'tool': 'find_widgets', 'type': 'ListView'},
        ],
      });
      final steps = (result['steps']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect([for (final s in steps) s['ok']], everyElement(isTrue));
      expect(log.events, ['changed Ada', 'saved']);
      final scrolled = steps[1]['result']! as Map<String, Object?>;
      expect(scrolled['axis'], 'vertical');
      expect(scrolled['pixels'], greaterThan(0));
      Map<String, Object?> firstWidget(Map<String, Object?> step) =>
          ((step['result']! as Map)['widgets']! as List).first!
              as Map<String, Object?>;
      expect(firstWidget(steps[3])['value'], 'Ada');
      expect(
        (firstWidget(steps[4])['scroll']! as Map)['pixels'],
        scrolled['pixels'],
      );
      await bridge.shutdown(tester);
    });

    testWidgets('stops at the first failing step; a bad step list runs '
        'nothing', (tester) async {
      await pumpApp(tester, _LongForm(log: log));
      final result = await ok(tester, 'run_steps', {
        'steps': [
          {
            'tool': 'enter_text',
            'target': {'key': 'name'},
            'text': 'Ada',
          },
          {
            'tool': 'tap',
            'target': {'text': 'Missing'},
          },
          {
            'tool': 'tap',
            'target': {'text': 'Save'},
          },
        ],
      });
      final steps = result['steps']! as List<Object?>;
      expect(steps, hasLength(2));
      expect((steps[1]! as Map)['error'], startsWith('no widget matches'));
      expect(result['stopped'], 'at step 2 of 3');
      expect(log.events, ['changed Ada'], reason: 'step 3 never ran');

      final refused = await run(tester, 'run_steps', {
        'steps': [
          {
            'tool': 'enter_text',
            'target': {'key': 'name'},
            'text': 'Bob',
          },
          {'tool': 'screenshot'},
        ],
      });
      expect(refused['error'], startsWith('step 2: screenshot cannot run'));
      expect(log.events, ['changed Ada'], reason: 'step 1 never ran');
      await bridge.shutdown(tester);
    });

    testWidgets('a widget that is still coming in is waited for', (
      tester,
    ) async {
      await pumpApp(tester, _Sheet(log: log));
      final result = await ok(tester, 'run_steps', {
        'steps': [
          {
            'tool': 'tap',
            'target': {'text': 'Open'},
          },
          // The sheet starts below the screen and slides up.
          {
            'tool': 'tap',
            'target': {'text': 'Confirm'},
          },
        ],
      });
      expect(result.containsKey('stopped'), isFalse, reason: '$result');
      expect(log.events, ['confirmed']);
      await bridge.shutdown(tester);
    });

    testWidgets('a read after a change returns once its widget stops '
        'moving; a spinner elsewhere does not hold it', (tester) async {
      await pumpApp(tester, const _Grow());
      final result = await ok(tester, 'run_steps', {
        'steps': [
          {
            'tool': 'tap',
            'target': {'text': 'Grow'},
          },
          {'tool': 'find_widgets', 'key': 'box'},
        ],
      });
      final read = (result['steps']! as List).last! as Map<String, Object?>;
      final box = ((read['result']! as Map)['widgets']! as List).single! as Map;
      expect((box['rect']! as List)[2], 300, reason: 'the grown width');
      expect(read.containsKey('settled'), isFalse);
      await bridge.shutdown(tester);
    });

    testWidgets('an idle app is not waited on, unless wait_ms asks', (
      tester,
    ) async {
      await pumpApp(tester, _Later(log: log));
      // Nothing draws: the widget cannot come by itself, so no wait.
      final now = await run(tester, 'tap', {
        'target': {'text': 'Later'},
      });
      expect(now['error'], startsWith('no widget matches'));
      // Content that loads: the agent asks to wait for it.
      await ok(tester, 'tap', {
        'target': {'text': 'Later'},
        'wait_ms': 1000,
      });
      expect(log.events, ['later']);
      await bridge.shutdown(tester);
    });
  });
}

class _Log {
  final List<String> events = <String>[];
  final List<PointerEvent> pointer = <PointerEvent>[];
}

class _Buttons extends StatelessWidget {
  const _Buttons({required this.log});

  final _Log log;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Listener(
      onPointerDown: log.pointer.add,
      onPointerUp: log.pointer.add,
      child: Stack(
        children: [
          const Center(child: Text('Under')),
          // Away from the center, where a dialog box would be.
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: () => log.events.add('save'),
                onLongPress: () => log.events.add('hold'),
                child: const Text('Save'),
              ),
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(content: Text('A dialog')),
                ),
                child: const Text('Open dialog'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Form extends StatelessWidget {
  const _Form({required this.log});

  final _Log log;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextField(
          key: const ValueKey<String>('code'),
          inputFormatters: [_Upper()],
          onChanged: (value) => log.events.add('changed $value'),
        ),
        const TextField(key: ValueKey<String>('password'), obscureText: true),
        const TextField(key: ValueKey<String>('locked'), readOnly: true),
      ],
    ),
  );
}

class _Upper extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toUpperCase());
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _LongList extends StatefulWidget {
  const _LongList();

  @override
  State<_LongList> createState() => _LongListState();
}

class _LongListState extends State<_LongList> {
  String _tapped = '';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_tapped)),
    body: ListView.builder(
      itemCount: 1000,
      itemExtent: 48,
      itemBuilder: (context, i) => ListTile(
        title: Text('Item $i'),
        onTap: () => setState(() => _tapped = 'tapped $i'),
      ),
    ),
  );
}

class _Page extends StatelessWidget {
  const _Page(this.name);

  final String name;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('page $name')));
}

class _Parser extends RouteInformationParser<String> {
  @override
  Future<String> parseRouteInformation(RouteInformation routeInformation) =>
      Future<String>.value(routeInformation.uri.path);

  @override
  RouteInformation restoreRouteInformation(String configuration) =>
      RouteInformation(uri: Uri.parse(configuration));
}

class _Delegate extends RouterDelegate<String>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<String> {
  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  List<String> stack = ['/'];

  @override
  String get currentConfiguration => stack.last;

  @override
  Future<void> setNewRoutePath(String configuration) async {
    stack = configuration == '/' ? ['/'] : [...stack, configuration];
    notifyListeners();
  }

  @override
  Widget build(BuildContext context) => Navigator(
    key: navigatorKey,
    pages: [
      for (final path in stack)
        MaterialPage<void>(
          key: ValueKey<String>(path),
          name: path,
          child: _Page(path),
        ),
    ],
    onDidRemovePage: (page) {
      stack = [
        for (final path in stack)
          if (path != page.name) path,
      ];
      notifyListeners();
    },
  );
}

class _LongForm extends StatelessWidget {
  const _LongForm({required this.log});

  final _Log log;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: [
        TextField(
          key: const ValueKey<String>('name'),
          onChanged: (value) => log.events.add('changed $value'),
        ),
        const SizedBox(height: 700),
        ElevatedButton(
          onPressed: () => log.events.add('saved'),
          child: const Text('Save'),
        ),
        const SizedBox(height: 200),
      ],
    ),
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.log});

  final _Log log;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            builder: (_) => Padding(
              padding: const EdgeInsets.all(24),
              child: ElevatedButton(
                onPressed: () => log.events.add('confirmed'),
                child: const Text('Confirm'),
              ),
            ),
          ),
          child: const Text('Open'),
        ),
      ),
    ),
  );
}

class _Grow extends StatefulWidget {
  const _Grow();

  @override
  State<_Grow> createState() => _GrowState();
}

class _GrowState extends State<_Grow> {
  double _width = 100;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        // Never settles: an idle wait would run to its timeout.
        const CircularProgressIndicator(),
        ElevatedButton(
          onPressed: () => setState(() => _width = 300),
          child: const Text('Grow'),
        ),
        AnimatedContainer(
          key: const ValueKey<String>('box'),
          duration: const Duration(milliseconds: 500),
          width: _width,
          height: 40,
          color: Colors.teal,
        ),
      ],
    ),
  );
}

class _Later extends StatefulWidget {
  const _Later({required this.log});

  final _Log log;

  @override
  State<_Later> createState() => _LaterState();
}

class _LaterState extends State<_Later> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    // Like a network answer: a timer, and no frames meanwhile.
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: _loaded
          ? TextButton(
              onPressed: () => widget.log.events.add('later'),
              child: const Text('Later'),
            )
          : const SizedBox.shrink(),
    ),
  );
}

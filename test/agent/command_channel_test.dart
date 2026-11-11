import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/agent/agent_control.dart';
import 'package:pinpoint/src/overlay/agent_layer.dart';

import '../support/agent_host.dart';

/// Milestone 12, build step 1: the command channel with one harmless
/// command (`get_screen`), end to end through the app's long poll, and the
/// "Allow agent control" switch.
void main() {
  late PinPointController controller;
  late AgentBridge bridge;

  setUp(() {
    controller = PinPointController();
    bridge = AgentBridge();
  });
  tearDown(() => controller.dispose());

  Future<void> pumpScreen(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(agentApp(controller: controller, home: home));
    await tester.pump();
  }

  Future<void> turnOn(WidgetTester tester) async {
    controller.agent.enabled = true;
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the poll runs only while control is on; get_screen comes '
      'back end to end', (tester) async {
    await pumpScreen(tester, const _Screen());
    expect(controller.agent.enabled, isFalse, reason: 'off by default');
    expect(bridge.requests, isEmpty, reason: 'no poll while off');
    final refused = await bridge.call(tester, 'get_screen');
    expect(refused['error'], startsWith('agent control is disabled'));

    await turnOn(tester);
    expect(bridge.requests, contains('GET /commands'));
    final answer = await bridge.call(tester, 'get_screen');
    expect(answer['ok'], isTrue, reason: '$answer');
    final screen = answer['result']! as Map<String, Object?>;
    expect(screen['route'], '/');
    expect(screen['viewport'], {'width': 800, 'height': 600});
    expect(screen['mode'], 'idle');
    final outline = (screen['outline']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final save = outline.singleWhere((e) => e['text'] == 'Save');
    expect(save['widget'], 'Text');
    expect(save['handle'], matches(RegExp(r'^h\d+$')));
    expect(save['source'], matches(RegExp(r'command_channel_test\.dart:\d+$')));
    expect(save['rect'], hasLength(4));
    expect(save['visible'], isTrue);
    await bridge.shutdown(tester);
  });

  testWidgets('turning control off stops the poll and tells the bridge', (
    tester,
  ) async {
    await pumpScreen(tester, const _Screen());
    await turnOn(tester);
    expect(bridge.queue.connected, isTrue);
    controller.agent.enabled = false;
    await tester.pump();
    await tester.pump();
    expect(bridge.control, [false]);
    expect(bridge.queue.connected, isFalse);
    final polls = bridge.requests.where((r) => r == 'GET /commands').length;
    await tester.pump(const Duration(seconds: 30));
    expect(
      bridge.requests.where((r) => r == 'GET /commands').length,
      polls,
      reason: 'no new poll after control is off',
    );
    await bridge.shutdown(tester);
  });

  testWidgets('watch out for: disposing the wrapper cancels the held poll', (
    tester,
  ) async {
    await pumpScreen(tester, const _Screen());
    await turnOn(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(bridge.control, [false]);
    expect(bridge.queue.connected, isFalse);
    await bridge.shutdown(tester);
  });

  testWidgets('watch out for: the poll stops while the tab is hidden and '
      'comes back when it shows', (tester) async {
    await pumpScreen(tester, const _Screen());
    await turnOn(tester);
    await _lifecycle(tester, AppLifecycleState.hidden);
    expect(bridge.control, [false]);
    expect(bridge.queue.connected, isFalse);
    expect(controller.agent.enabled, isTrue, reason: 'the switch stays on');

    await _lifecycle(tester, AppLifecycleState.resumed);
    expect(bridge.queue.connected, isTrue);
    final answer = await bridge.call(tester, 'get_screen');
    expect(answer['ok'], isTrue);
    await bridge.shutdown(tester);
  });

  testWidgets('acceptance: with control off, every driving tool returns '
      '"agent control is disabled" and nothing happens', (tester) async {
    await pumpScreen(tester, const _Screen());
    await tester.enterText(find.byType(TextField), 'kept');
    await tester.pump();
    expect(find.text('count 0'), findsOneWidget);

    for (final tool in AgentControl.drivingTools) {
      final answer = await drive(
        tester,
        controller.agent.run(tool, {
          'handle': 'h1',
          'text': 'typed',
          'path': '/other',
          'dy': 100,
          'id': 'pp_x',
          'viewport': {'width': 320, 'height': 640},
        }),
      );
      expect(answer['ok'], isFalse, reason: tool);
      expect(answer['error'], 'agent control is disabled', reason: tool);
    }
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('count 0'), findsOneWidget);
    expect(find.text('kept'), findsOneWidget);
    expect(find.text('Other'), findsNothing);
    expect(controller.environment.isActive, isFalse);
    expect(controller.agent.driving, isNull);
    await bridge.shutdown(tester);
  });

  testWidgets('the switch turns control on, the chip shows it in idle, and '
      'Esc turns it off', (tester) async {
    await pumpScreen(tester, const _Screen());
    expect(find.byKey(AgentLayer.toggleKey), findsNothing);
    controller.startPicking();
    await tester.pump();
    await tester.tap(find.byKey(AgentLayer.toggleKey));
    await tester.pump();
    expect(controller.agent.enabled, isTrue);

    controller.stop();
    await tester.pump();
    // Visibly on when it is on, idle included.
    expect(find.byKey(AgentLayer.bannerKey), findsOneWidget);
    expect(find.text('Agent control on · Esc stops'), findsOneWidget);
    expect(find.byKey(AgentLayer.toggleKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.agent.enabled, isFalse);
    expect(find.byKey(AgentLayer.bannerKey), findsNothing);
    expect(bridge.control, [false]);
    await bridge.shutdown(tester);
  });

  testWidgets('get_screen keeps lists to 20 and strings to 200 characters, '
      'with a parameter for more', (tester) async {
    await pumpScreen(tester, const _ManyTexts());
    await turnOn(tester);
    final answer = await bridge.call(tester, 'get_screen');
    final screen = answer['result']! as Map<String, Object?>;
    final outline = screen['outline']! as List<Object?>;
    expect(outline, hasLength(20));
    expect(screen['more'], greaterThan(0));
    for (final entry in outline.cast<Map<String, Object?>>()) {
      final text = entry['text'] as String?;
      if (text != null) expect(text.length, lessThanOrEqualTo(200));
    }

    final more = await bridge.call(tester, 'get_screen', {
      'limit': 40,
      'max_chars': 400,
    });
    final wider = more['result']! as Map<String, Object?>;
    expect((wider['outline']! as List<Object?>).length, greaterThan(20));
    final long = (wider['outline']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((e) => e['text'] as String? ?? '')
        .reduce((a, b) => a.length >= b.length ? a : b);
    expect(long.length, greaterThan(200));
    await bridge.shutdown(tester);
  });
}

Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage(state.toString()),
    (_) {},
  );
  await tester.pump();
  await tester.pump();
}

class _Screen extends StatefulWidget {
  const _Screen();

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  int _count = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('count $_count'),
        ElevatedButton(
          onPressed: () => setState(() => _count++),
          child: const Text('Save'),
        ),
        const TextField(),
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const Text('Other'))),
          child: const Text('Open other'),
        ),
      ],
    ),
  );
}

class _ManyTexts extends StatelessWidget {
  const _ManyTexts();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Wrap(
      children: [Text('long ' * 100), for (var i = 0; i < 40; i++) Text('t$i')],
    ),
  );
}

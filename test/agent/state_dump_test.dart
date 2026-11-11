import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/agent/command_channel.dart';

import '../support/agent_host.dart';

/// Milestone 12, build step 6: the state dump, and the service-extension
/// transport spike.
void main() {
  late PinPointController controller;
  late AgentBridge bridge;

  setUp(() {
    controller = PinPointController();
    bridge = AgentBridge();
  });
  tearDown(() => controller.dispose());

  Future<void> pumpApp(
    WidgetTester tester, {
    List<StateAdapter> adapters = const [],
  }) async {
    await tester.pumpWidget(
      agentApp(
        controller: controller,
        home: const _Screen(),
        config: PinPointConfig(
          bridgeUrl: AgentBridge.url,
          stateAdapters: adapters,
        ),
      ),
    );
    await tester.pump();
  }

  Future<Map<String, Object?>> state(
    WidgetTester tester,
    Map<String, Object?> query,
  ) async {
    final found = await drive(
      tester,
      controller.agent.run('find_widgets', query),
    );
    final widgets =
        (found['result']! as Map<String, Object?>)['widgets']! as List<Object?>;
    final handle = (widgets.first! as Map)['handle'];
    final answer = await drive(
      tester,
      controller.agent.run('get_state', {'handle': handle}),
    );
    expect(answer['ok'], isTrue, reason: '$answer');
    return answer['result']! as Map<String, Object?>;
  }

  testWidgets('get_state: the nearest State, scroll position, focus, text '
      'field, route and inherited widgets', (tester) async {
    await pumpApp(tester);
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(30);
    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pump();

    final field = await state(tester, {'type': 'TextField'});
    final nearest = field['state']! as Map<String, Object?>;
    expect(nearest['type'], '_TextFieldState');
    expect(field['focused'], isTrue);
    expect(field['text'], {
      'value': 'hello',
      'selection': [5, 5],
    });
    final scroll = field['scroll']! as Map<String, Object?>;
    expect(scroll['pixels'], 30);
    expect(scroll['axis'], 'vertical');
    expect(field['route'], {'name': '/', 'current': true});
    final inherited = (field['inherited']! as List<Object?>).cast<String>();
    expect(inherited, contains('MediaQuery'));
    expect(inherited.length, lessThanOrEqualTo(30));

    final counter = await state(tester, {'type': '_Counter'});
    final props = (counter['state']! as Map)['properties']! as Map;
    expect(props['count'], '3');
    expect(counter['focused'], isFalse);
    await bridge.shutdown(tester);
  });

  testWidgets('an obscured field is masked in the dump', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byKey(const ValueKey('pin')), '1234');
    await tester.pump();
    final pin = await state(tester, {'key': 'pin'});
    expect((pin['text']! as Map)['value'], '[masked]');
    await bridge.shutdown(tester);
  });

  testWidgets('state adapters add the app values (Bloc, Riverpod, '
      'Provider)', (tester) async {
    await pumpApp(tester, adapters: [_CartAdapter()]);
    final dump = await state(tester, {'type': '_Counter'});
    expect(dump['adapters'], {
      'cart': {'items': 2, 'total': '9.50'},
    });
    await bridge.shutdown(tester);
  });

  testWidgets('a throwing adapter is reported, not fatal', (tester) async {
    await pumpApp(tester, adapters: [_Broken()]);
    final dump = await state(tester, {'type': '_Counter'});
    expect((dump['adapters']! as Map)['broken'], startsWith('failed:'));
    await bridge.shutdown(tester);
  });

  group('service-extension transport (spike)', () {
    testWidgets('routes ext.pinpoint.command to the handler while started', (
      tester,
    ) async {
      final transport = ServiceExtensionTransport();
      final calls = <String>[];
      transport.start((tool, args) async {
        calls.add('$tool $args');
        return {
          'ok': true,
          'result': {'echo': tool},
        };
      });
      expect(transport.running, isTrue);
      final answer = await ServiceExtensionTransport.handle(
        ServiceExtensionTransport.method,
        {
          'tool': 'get_screen',
          'args': jsonEncode({'limit': 3}),
        },
      );
      expect(calls, ['get_screen {limit: 3}']);
      expect(jsonDecode(answer), {
        'ok': true,
        'result': {'echo': 'get_screen'},
      });

      transport.stop();
      final off = await ServiceExtensionTransport.handle(
        ServiceExtensionTransport.method,
        {'tool': 'tap'},
      );
      expect(
        (jsonDecode(off) as Map<String, Object?>)['error'],
        'agent control is disabled',
      );
      // Registered once per isolate: a second start does not throw.
      ServiceExtensionTransport()
        ..start((tool, args) async => const {'ok': true})
        ..stop();
      expect(debugRegisteredPinpointExtension, isTrue);
    });
  });
}

class _CartAdapter extends StateAdapter {
  @override
  String get name => 'cart';

  @override
  Map<String, Object?>? read(BuildContext context) {
    // A real adapter reads without subscribing, for example
    // `context.read<CartCubit>().state`.
    final screen = context.findAncestorWidgetOfExactType<_Screen>();
    return screen == null ? null : {'items': 2, 'total': '9.50'};
  }
}

class _Broken extends StateAdapter {
  @override
  String get name => 'broken';

  @override
  Map<String, Object?>? read(BuildContext context) =>
      throw StateError('no cart here');
}

class _Screen extends StatelessWidget {
  const _Screen();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: const [
        _Counter(),
        TextField(),
        TextField(key: ValueKey('pin'), obscureText: true),
        SizedBox(height: 2000),
      ],
    ),
  );
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  final int _count = 3;

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(IntProperty('count', _count));
  }

  @override
  Widget build(BuildContext context) => Text('count $_count');
}

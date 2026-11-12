import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';

import '../support/trace_host.dart';

/// PLAN-v2 Milestone 13, build step 5: watches.
void main() {
  late PinPointController controller;
  final parent = GlobalKey<_ParentState>();

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Future<void> pumpApp(
    WidgetTester tester, {
    PinPointConfig config = const PinPointConfig(),
  }) async {
    await tester.pumpWidget(
      traceApp(
        controller: controller,
        config: config,
        home: Scaffold(body: _Parent(key: parent)),
      ),
    );
    await tester.pump();
  }

  List<TraceEvent> states() => [
    for (final e in recorder.events)
      if (e.kind == TraceKind.state) e,
  ];

  Future<Map<String, Object?>> watchChild(WidgetTester tester) =>
      toolResult(tester, controller, 'watch', {
        'target': {'type': '_Child'},
      });

  testWidgets('acceptance: a watch on a child records a state event when a '
      "value of the parent's State changes", (tester) async {
    await pumpApp(tester);
    final watch = await watchChild(tester);
    expect(watch['id'], 'w1');
    // The first values of both States, once.
    // A Scaffold made in project code is local too; it comes third.
    expect(states().take(2).map((e) => (e.data['state'], e.data['initial'])), [
      ('_ChildState', true),
      ('_ParentState', true),
    ]);

    parent.currentState!.load();
    await tester.pump();
    final change = states().last;
    expect(change.data['state'], '_ParentState');
    expect(change.data['initial'], isNull);
    expect(change.data['changed'], {
      'cache': ['0', '1'],
    });

    final lines = await traceLines(tester, controller, {
      'kinds': ['state'],
    });
    expect(lines.last, contains('_ParentState cache: 0 → 1'));
    await toolResult(tester, controller, 'unwatch', {});
  });

  testWidgets('watch says what it can see: private fields need a probe', (
    tester,
  ) async {
    await pumpApp(tester);
    final watch = await toolResult(tester, controller, 'watch', {
      'target': {'type': '_Child'},
      'ancestors': 2,
    });
    expect(watch['states'], [
      {'type': '_ChildState', 'shown': 1},
      {'type': '_ParentState', 'shown': 1},
    ]);
    expect(watch['shown'], 2);
    expect(watch['note'], contains('private fields need a probe'));
    // The child's private flag is not in its diagnostics.
    final child = states().first.data['changed']! as Map<String, Object?>;
    expect(child.keys, ['loading']);
    await toolResult(tester, controller, 'unwatch', {});
  });

  testWidgets('a watch holds level 3; the last unwatch lets it go', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(debugOnRebuildDirtyWidget, isNull);
    final watch = await watchChild(tester);
    expect((watch['level3']! as Map)['for'], ['watch']);
    expect(debugOnRebuildDirtyWidget, isNotNull);
    final removed = await toolResult(tester, controller, 'unwatch', {
      'id': 'w1',
    });
    expect(removed['removed'], 1);
    expect(debugOnRebuildDirtyWidget, isNull);
    final none = await runTool(tester, controller, 'unwatch', {'id': 'w9'});
    expect(none['error'], 'no watch w9');
  });

  testWidgets('acceptance (other level 3 sources still start): with the '
      'rebuild slot taken, the watch still records', (tester) async {
    await pumpApp(tester);
    void devTools(Element element, bool builtOnce) {}
    debugOnRebuildDirtyWidget = devTools;
    final detail = await toolResult(tester, controller, 'trace_detail', {
      'on': true,
    });
    expect(detail['rebuilds'], contains('rebuild slot taken'));
    expect(detail['running'], contains('watch'));
    await watchChild(tester);
    parent.currentState!.load();
    await tester.pump();
    expect(states().last.data['changed'], {
      'cache': ['0', '1'],
    });
    await toolResult(tester, controller, 'unwatch', {});
    await toolResult(tester, controller, 'trace_detail', {'on': false});
    expect(debugOnRebuildDirtyWidget, same(devTools));
    debugOnRebuildDirtyWidget = null;
  });

  testWidgets('at most 8 watches', (tester) async {
    await pumpApp(tester);
    for (var i = 0; i < 8; i++) {
      await watchChild(tester);
    }
    final ninth = await runTool(tester, controller, 'watch', {
      'target': {'type': '_Child'},
    });
    expect(ninth['ok'], isFalse);
    expect(ninth['error'], contains('at most 8 watches'));
    await toolResult(tester, controller, 'unwatch', {});
    expect(debugOnRebuildDirtyWidget, isNull);
  });

  testWidgets("the app's state adapters are watched too", (tester) async {
    await pumpApp(
      tester,
      config: const PinPointConfig(stateAdapters: [_CartAdapter()]),
    );
    await watchChild(tester);
    final first = states().first.data['changed']! as Map<String, Object?>;
    expect(first['cart.items'], '2');
    await toolResult(tester, controller, 'unwatch', {});
  });
}

class _Parent extends StatefulWidget {
  const _Parent({super.key});

  @override
  State<_Parent> createState() => _ParentState();
}

class _ParentState extends State<_Parent> {
  int cache = 0;

  void load() => setState(() => cache++);

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(IntProperty('cache', cache));
  }

  @override
  Widget build(BuildContext context) => _Child(cache: cache);
}

class _Child extends StatefulWidget {
  const _Child({required this.cache});

  final int cache;

  @override
  State<_Child> createState() => _ChildState();
}

class _ChildState extends State<_Child> {
  bool loading = false;
  // Not in debugFillProperties: a watch cannot see it.
  // ignore: unused_field
  final String _loadedForType = 'faq';

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(FlagProperty('loading', value: loading, ifTrue: 'loading'));
  }

  @override
  Widget build(BuildContext context) => Text('cache ${widget.cache}');
}

class _CartAdapter extends StateAdapter {
  const _CartAdapter();

  @override
  String get name => 'cart';

  @override
  Map<String, Object?>? read(BuildContext context) => {'items': 2};
}

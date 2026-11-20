import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/agent/agent_control.dart';
import 'package:pinpoint/src/bridge/agent_tools.dart';
import 'package:pinpoint/src/bridge/source_lookup.dart';
import 'package:pinpoint/src/bridge/state_flow_text.dart';
import 'package:pinpoint/src/state/state_lens.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/fake_provider.dart';
import '../support/trace_host.dart';

/// PLAN-v3 Milestone 21, build step 8: the `state_flow` command in the app,
/// through the agent's command path, over a real trace session.
void main() {
  late PinPointController controller;
  late ProductModel product;
  late CartModel cart;

  const DebugPrintCallback initialPrint = debugPrintSynchronously;

  setUp(() {
    controller = PinPointController();
    product = ProductModel();
    cart = CartModel();
  });
  tearDown(() {
    controller.dispose();
    CauseZone.debugReset();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      traceApp(
        controller: controller,
        home: Scaffold(
          body: FakeScope<ProductModel>(
            model: product,
            child: FakeScope<CartModel>(
              model: cart,
              child: const Column(
                children: [ProductScreen(), ProductAndCart()],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<Map<String, Object?>> flow(
    WidgetTester tester, [
    Map<String, Object?> args = const {
      'target': {'type': 'ProductScreen'},
    },
  ]) => toolResult(tester, controller, 'state_flow', args);

  /// A body that ends with every global back, as the binding demands.
  void scenario(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        try {
          await body(tester);
        } finally {
          TraceSession.current?.stateLensIfAny?.stop();
          expect(debugPrint, same(initialPrint));
          expect(debugPrintScheduleBuildForStacks, isFalse);
        }
      });

  test('the tool is a read tool and is in the bridge list', () {
    expect(AgentControl.readTools, contains('state_flow'));
    expect(agentToolNames, contains('state_flow'));
    final tool = agentTools.firstWhere((t) => t['name'] == 'state_flow');
    expect(tool['description'], contains('why two values change together'));
    expect(tool['description'], contains('what changed a value'));
    final properties =
        (tool['inputSchema']! as Map)['properties']! as Map<String, Object?>;
    expect(properties.keys, containsAll(<String>['target', 'seconds']));
  });

  scenario('the first call arms and answers what the widget reads; the '
      'second answers the chain', (tester) async {
    await pumpApp(tester);

    final first = await flow(tester);

    expect(first['armedNow'], isTrue);
    expect(first['armed'], isTrue);
    expect(first['seconds'], 30);
    expect(first['target'], {
      'type': 'ProductScreen',
      'source': contains('test/state/state_flow_tool_test.dart:'),
    });
    final readers = first['readers']! as List<Object?>;
    final dependency =
        (((readers.first! as Map)['dependencies']! as List).first as Map);
    expect(dependency['type'], 'ProductModel');
    expect(dependency['tag'], matches(RegExp(r'^#a\d+$')));
    expect(first['causes'], isEmpty);

    product.fetchDialog();
    await tester.pump();
    final second = await flow(tester);

    expect(second['armedNow'], isFalse);
    expect(second['armed'], isTrue);
    expect(second['secondsLeft'], inInclusiveRange(1, 30));
    final causes = [
      for (final c in second['causes']! as List<Object?>)
        if (((c! as Map)['notifies']! as List).isNotEmpty)
          c as Map<String, Object?>,
    ];
    expect(causes, hasLength(1), reason: '$second');
    final notify = (causes.single['notifies']! as List).single as Map;
    expect(notify['owner'], 'ProductModel');
    expect(notify['method'], 'ProductModel.fetchDialog');
    final rebuilt = causes.single['rebuilt']! as List;
    expect([
      for (final r in rebuilt) (r as Map)['type'],
    ], containsAll(<String>['ProductScreen', 'ProductAndCart']));
    expect(causes.single['hint'], contains('shape 1'));
    // No PinPoint.run in a test: the answer says why there is no cause.
    expect((second['notes']! as List).join(), contains('no causes'));

    // The bridge adds the code under the notify, from the project's source
    // (here the repository itself): one method set both values.
    final text = await tester.runAsync(
      () => stateFlowText(second, SourceLookup(Directory.current)),
    );
    // ignore: avoid_print
    if (Platform.environment['PP_PRINT'] != null) print(text);
    expect(text, contains('ProductModel #a1 notified   fetchDialog()'));
    expect(text, contains('test/support/fake_provider.dart:'));
    expect(
      text,
      contains('dialogLoading = true; loading = true; notifyListeners();'),
    );
    expect(text, contains('(dependencies: ProductModel #a1)   <- same object'));
    expect(text, contains('hint: shape 1: ProductModel'));
  });

  scenario('another target re-targets: one lens, one window', (tester) async {
    await pumpApp(tester);
    await flow(tester);
    final lens = TraceSession.current!.stateLens;
    expect(lens.value.targetType, 'ProductScreen');

    final other = await flow(tester, {
      'target': {'type': 'ProductAndCart'},
      'seconds': 5,
    });

    expect(other['armedNow'], isTrue);
    expect(other['seconds'], 5);
    expect((other['target']! as Map)['type'], 'ProductAndCart');
    expect(TraceSession.current!.stateLens, same(lens));
    expect(lens.value.targetType, 'ProductAndCart');
    expect(lens.armed, isTrue);
    expect(lens.value.dependencies, hasLength(2));
    // The first target's model has one listener less: ours on ProductScreen
    // is gone, ProductAndCart's is on (and the scope's own).
    expect(product.listenerCount, 2);
    expect(cart.listenerCount, 2);

    final again = await flow(tester, {
      'target': {'type': 'ProductAndCart'},
      'rearm': true,
    });
    expect(again['armedNow'], isTrue);
    expect(product.listenerCount, 2);
  });

  scenario('a window that ended still answers its chain; a bad seconds is '
      'an error the agent can act on', (tester) async {
    await pumpApp(tester);
    await flow(tester, {
      'target': {'type': 'ProductScreen'},
      'seconds': 1,
    });
    product.fetchDialog();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(TraceSession.current!.stateLens.armed, isFalse);

    final after = await flow(tester);

    expect(after['armedNow'], isFalse);
    expect(after['armed'], isFalse);
    expect(after['ended'], 'window ended');
    expect(
      (after['causes']! as List).any(
        (c) => ((c! as Map)['notifies']! as List).isNotEmpty,
      ),
      isTrue,
    );
    expect(product.listenerCount, 1);

    final bad = await runTool(tester, controller, 'state_flow', {
      'target': {'type': 'ProductScreen'},
      'seconds': 0,
    });
    expect(bad['ok'], isFalse);
    expect('${bad['error']}', contains('seconds'));
    final missing = await runTool(tester, controller, 'state_flow');
    expect(missing['ok'], isFalse);
  });

  scenario('the lens holds level 3 while armed and lets it go at the end', (
    tester,
  ) async {
    await pumpApp(tester);
    final session = TraceSession.current!;
    expect(session.demands, isNot(contains(TraceDemand.state)));

    await flow(tester);
    expect(session.demands, contains(TraceDemand.state));
    expect(session.rebuildSource.running, isTrue);

    session.stateLens.stop();
    expect(session.demands, isNot(contains(TraceDemand.state)));
  });

  testWidgets('disposing the wrapper gives every global back', (tester) async {
    await pumpApp(tester);
    await flow(tester);
    expect(debugPrintScheduleBuildForStacks, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(debugPrintScheduleBuildForStacks, isFalse);
    expect(debugPrint, same(initialPrint));
    expect(product.listenerCount, 0);
    expect(StateLens.maxWindow, const Duration(seconds: 30));
  });
}

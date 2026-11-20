import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/state/state_lens.dart';

import '../support/fake_provider.dart';
import '../support/lens_host.dart';

/// PLAN-v3 Milestone 21, build step 5: arming. One window on one target;
/// nothing is left behind when it ends.
void main() {
  late LensHost host;

  // The binding checks `debugPrint` after the body and before any tearDown:
  // everything comes back inside the body.
  const DebugPrintCallback initialPrint = debugPrintSynchronously;
  void scenario(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        host = LensHost(
          content: () => tester.element(find.byType(MaterialApp)),
        );
        try {
          await body(tester);
        } finally {
          host.dispose();
          expect(debugPrint, same(initialPrint));
          expect(debugPrintScheduleBuildForStacks, isFalse);
        }
      });

  Future<void> pumpScreen(WidgetTester tester, ProductModel model) =>
      tester.pumpWidget(
        MaterialApp(
          home: FakeScope<ProductModel>(
            model: model,
            child: const ProductScreen(),
          ),
        ),
      );

  // The notifies of every cause. (In a test the framework's own `setState`
  // calls carry the test file in their stack and make causes of their own.)
  List<Object?> notifiesOf(Map<String, Object?> chain) => [
    for (final c in chain['causes']! as List<Object?>)
      ...(c! as Map)['notifies']! as List,
  ];

  int stateEvents() => host.recorder.events
      .where(
        (e) =>
            e.kind == TraceKind.stateNotify ||
            e.kind == TraceKind.stateSetState,
      )
      .length;

  scenario('arming reads the dependencies, listens, and holds level 3', (
    tester,
  ) async {
    final model = ProductModel();
    await pumpScreen(tester, model);
    final scopeListeners = model.listenerCount;
    expect(scopeListeners, 1);

    host.lens.arm(tester.element(find.byType(ProductScreen)));

    final state = host.lens.value;
    expect(state.armed, isTrue);
    expect(state.targetType, 'ProductScreen');
    expect(state.targetSource, startsWith('test/state/state_lens_test.dart:'));
    expect(state.readers.single.dependencies.single.type, 'ProductModel');
    expect(state.dependencies.single.tag, '#a1');
    expect(state.window, StateLens.defaultWindow);
    expect(host.lens.secondsLeft, inInclusiveRange(29, 30));
    expect(state.rebuildsRecorded, isTrue);
    // Pinpoint's listener is on the model; the globals are set.
    expect(model.listenerCount, scopeListeners + 1);
    expect(debugPrintScheduleBuildForStacks, isTrue);
    expect(host.console.active, isTrue);
    expect(host.demands, 1);
    expect(host.rebuilds.running, isTrue);

    host.lens.stop();

    expect(host.lens.armed, isFalse);
    expect(host.lens.value.endedBecause, 'stopped');
    expect(host.lens.secondsLeft, 0);
    expect(model.listenerCount, scopeListeners);
    expect(debugPrintScheduleBuildForStacks, isFalse);
    expect(host.console.active, isFalse);
    expect(host.releases, 1);
    expect(host.rebuilds.running, isFalse);
    // Stopping twice does nothing.
    host.lens.stop();
    expect(host.releases, 1);
    expect(host.console.restores, 1);
  });

  scenario('the window ends by itself, at most 30 s, and the chain stays', (
    tester,
  ) async {
    final model = ProductModel();
    await pumpScreen(tester, model);
    host.lens.arm(
      tester.element(find.byType(ProductScreen)),
      window: const Duration(minutes: 5),
    );
    expect(host.lens.value.window, StateLens.maxWindow);

    model.fetchDialog();
    await tester.pump();
    await tester.pump(const Duration(seconds: 29));
    expect(host.lens.armed, isTrue);
    await tester.pump(const Duration(seconds: 2));

    expect(host.lens.armed, isFalse);
    expect(host.lens.value.endedBecause, 'window ended');
    expect(model.listenerCount, 1);
    expect(debugPrintScheduleBuildForStacks, isFalse);
    expect(host.console.restores, 1);
    expect(host.releases, 1);
    // What was seen stays readable, and nothing new is recorded.
    final before = stateEvents();
    expect(before, greaterThan(0));
    expect(
      host.lens.chain()['causes'],
      isNotEmpty,
      reason: 'the chain is read after the window ends',
    );
    model.fetchDialog();
    await tester.pump();
    expect(stateEvents(), before);
    final target = tester.element(find.byType(ProductScreen));
    expect(host.lens.wasTarget(target), isTrue);
    expect(host.lens.isTarget(target), isFalse);
  });

  scenario('one lens at a time: arming again re-targets', (tester) async {
    final first = ProductModel();
    final second = CartModel();
    await tester.pumpWidget(
      MaterialApp(
        home: FakeScope<ProductModel>(
          model: first,
          child: FakeScope<CartModel>(
            model: second,
            child: const Column(children: [ProductScreen(), _CartOnly()]),
          ),
        ),
      ),
    );
    host.lens.arm(tester.element(find.byType(ProductScreen)));
    first.fetchDialog();
    await tester.pump();
    final firstEvents = stateEvents();
    expect(firstEvents, greaterThan(0));
    expect(first.listenerCount, 2);

    host.lens.arm(tester.element(find.byType(_CartOnly)));

    // The first target's listener is gone, the second's is on.
    expect(first.listenerCount, 1);
    expect(second.listenerCount, 2);
    expect(host.lens.value.targetType, '_CartOnly');
    expect(host.lens.armed, isTrue);
    expect(host.console.installs, 2);
    expect(host.console.restores, 1);
    expect(host.demands, 2);
    expect(host.releases, 1);
    // The chain is the new window's: the first target's events are not in it.
    expect(host.lens.chain()['events'], 0);
    first.fetchDialog();
    await tester.pump();
    expect(notifiesOf(host.lens.chain()), isEmpty);
    second.bump();
    await tester.pump();
    expect(notifiesOf(host.lens.chain()), hasLength(1));
  });

  scenario('dispose and the registry give everything back', (tester) async {
    final model = ProductModel();
    await pumpScreen(tester, model);
    host.lens.arm(tester.element(find.byType(ProductScreen)));
    expect(model.listenerCount, 2);

    host.hooks.dispose();

    expect(host.lens.armed, isFalse);
    expect(host.lens.value.endedBecause, 'disposed');
    expect(model.listenerCount, 1);
    expect(debugPrintScheduleBuildForStacks, isFalse);
    expect(host.console.active, isFalse);
    expect(host.releases, 1);
  });

  scenario('the target unmounts: the window ends and the listeners go', (
    tester,
  ) async {
    final model = ProductModel();
    await pumpScreen(tester, model);
    host.lens.arm(tester.element(find.byType(ProductScreen)));
    expect(host.lens.armed, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    // The lens ends the window in a microtask after the frame.
    await tester.pump();

    expect(host.lens.armed, isFalse);
    expect(host.lens.value.endedBecause, 'target unmounted');
    expect(model.listenerCount, 0);
    expect(host.console.active, isFalse);
    expect(host.releases, 1);
    expect(debugPrintScheduleBuildForStacks, isFalse);
  });

  scenario('an unmounted element is not armed', (tester) async {
    final model = ProductModel();
    await pumpScreen(tester, model);
    final element = tester.element(find.byType(ProductScreen));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    host.lens.arm(element);

    expect(host.lens.armed, isFalse);
    expect(host.demands, 0);
    expect(host.console.installs, 0);
  });

  scenario('the state is a listenable: arm and stop notify', (tester) async {
    final model = ProductModel();
    await pumpScreen(tester, model);
    final seen = <bool>[];
    host.lens.addListener(() => seen.add(host.lens.value.armed));

    host.lens.arm(tester.element(find.byType(ProductScreen)));
    model.fetchDialog();
    await tester.pump();
    host.lens.stop();

    expect(seen.first, isTrue);
    expect(seen.last, isFalse);
    // A join in between: the events count shows in the state.
    expect(seen.length, greaterThanOrEqualTo(3));
    expect(host.lens.value.events, greaterThan(0));
    expect(host.lens.value.rebuilds, isNotEmpty);
  });
}

/// Reads the cart only.
class _CartOnly extends StatelessWidget {
  const _CartOnly();

  @override
  Widget build(BuildContext context) =>
      Text('cart ${watchFake<CartModel>(context).count}');
}

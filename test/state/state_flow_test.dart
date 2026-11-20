import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/state_flow.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

import '../support/fake_provider.dart';
import '../support/lens_host.dart';

const String _support = 'test/support/fake_provider.dart';

/// PLAN-v3 Milestone 21, build step 4: the notifies of one cause joined with
/// the elements that rebuilt after them, and one coupling hint.
void main() {
  late LensHost host;

  /// Runs [body] with a lens host; every global comes back before the
  /// binding checks `debugPrint` at the end of the body.
  void scenario(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        host = LensHost(
          content: () => tester.element(find.byType(MaterialApp)),
        );
        try {
          await body(tester);
        } finally {
          host.dispose();
        }
      });

  /// The cause that holds a notify, and the only one. In a test, `pump` runs
  /// the frame inside the test body, so the framework's own `setState` calls
  /// carry the test file as their first project frame and make causes of
  /// their own; a real frame starts in the engine.
  Map<String, Object?> onlyCause() {
    final chain = host.lens.chain();
    final causes = [
      for (final c in chain['causes']! as List<Object?>)
        if ((c! as Map)['notifies']! is List &&
            ((c as Map)['notifies']! as List).isNotEmpty)
          c as Map<String, Object?>,
    ];
    expect(causes, hasLength(1), reason: '$chain');
    return causes.single;
  }

  List<Map<String, Object?>> rebuilt(Map<String, Object?> cause) => [
    for (final r in cause['rebuilt']! as List<Object?>)
      r! as Map<String, Object?>,
  ];

  scenario('shape 1: one notify, two readers rebuilt: the method that set '
      'both values is named', (tester) async {
    final model = ProductModel();
    await tester.pumpWidget(
      MaterialApp(
        home: FakeScope<ProductModel>(
          model: model,
          child: const Column(
            children: [
              ProductScreen(key: ValueKey('a')),
              ProductScreen(key: ValueKey('b')),
            ],
          ),
        ),
      ),
    );
    host.lens.arm(tester.element(find.byKey(const ValueKey('a'))));
    expect(host.lens.value.readers.single.type, 'ProductScreen');

    model.fetchDialog();
    await tester.pump();

    final cause = onlyCause();
    final notify = (cause['notifies']! as List<Object?>).single! as Map;
    expect(notify['owner'], 'ProductModel');
    expect(notify['method'], 'ProductModel.fetchDialog');
    expect(notify['file'], _support);
    final readers = rebuilt(cause);
    expect(readers, hasLength(2), reason: '$readers');
    expect(readers.map((r) => r['type']).toSet(), {'ProductScreen'});
    expect(readers.map((r) => r['tag']).toSet(), hasLength(1));
    expect(readers.first['via'], 'dependency');
    expect(readers.first['owner'], 'ProductModel');
    final hint = cause['hint']! as String;
    expect(hint, startsWith('shape 1:'));
    expect(hint, contains('ProductModel (ProductModel.fetchDialog)'));
    expect(hint, contains('notified once and 2 readers rebuilt'));
    expect(hint, isNot(contains('shape 2')));
    expect(hint, isNot(contains('shape 3')));
  });

  scenario('shape 2: a notify inside another notify\'s listener', (
    tester,
  ) async {
    final product = ProductModel();
    final cart = CartModel();
    // The app's own listener: when the product changes, bump the cart.
    product.addListener(cart.bump);
    await tester.pumpWidget(
      MaterialApp(
        home: FakeScope<ProductModel>(
          model: product,
          child: FakeScope<CartModel>(
            model: cart,
            child: const ProductAndCart(),
          ),
        ),
      ),
    );
    host.lens.arm(tester.element(find.byType(ProductAndCart)));
    expect(host.lens.value.dependencies, hasLength(2));

    product.fetchDialog();
    await tester.pump();

    final cause = onlyCause();
    final notifies = [
      for (final n in cause['notifies']! as List<Object?>)
        n! as Map<String, Object?>,
    ];
    expect(notifies, hasLength(2));
    final nested = notifies.singleWhere((n) => n['owner'] == 'CartModel');
    final outer = notifies.singleWhere((n) => n['owner'] == 'ProductModel');
    expect(nested['depth'], 2);
    expect(outer.containsKey('depth'), isFalse);
    expect(nested['method'], 'CartModel.bump');
    final hint = cause['hint']! as String;
    expect(hint, contains('shape 2: CartModel (CartModel.bump) notified'));
    expect(hint, contains('the listener of ProductModel'));
    expect(hint, contains('one notifier triggers another'));
    // One reader reads both objects: not shape 1 or 3.
    expect(hint, isNot(contains('shape 1')));
    expect(hint, isNot(contains('shape 3')));
  });

  scenario('shape 3: a dialog route and its screen read one object', (
    tester,
  ) async {
    final model = ProductModel();
    late BuildContext screen;
    await tester.pumpWidget(
      MaterialApp(
        home: FakeScope<ProductModel>(
          model: model,
          child: Builder(
            builder: (context) {
              screen = context;
              return const ProductScreen();
            },
          ),
        ),
      ),
    );
    // The dialog is a route in the Navigator's overlay, not a child of the
    // screen: it gets the same object with a scope of its own.
    unawaited(
      showDialog<void>(
        context: screen,
        builder: (_) =>
            FakeScope<ProductModel>(model: model, child: const FetchDialog()),
      ),
    );
    await tester.pumpAndSettle();
    host.lens.arm(tester.element(find.byType(ProductScreen)));

    model.fetchDialog();
    await tester.pump();

    final cause = onlyCause();
    final readers = rebuilt(cause);
    expect(readers.map((r) => r['type']).toSet(), {
      'ProductScreen',
      'FetchDialog',
    });
    expect(readers.map((r) => r['tag']).toSet(), hasLength(1));
    final hint = cause['hint']! as String;
    expect(hint, contains('shape 3: FetchDialog and ProductScreen read the '));
    expect(hint, contains('same object ProductModel #a1'));
  });

  scenario('a ValueNotifier in a builder: the builder is the reader, with '
      'the value before and after', (tester) async {
    final notifier = ValueNotifier<int>(1);
    addTearDown(notifier.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: notifier,
          builder: (_, value, _) => Text('v$value'),
        ),
      ),
    );
    host.lens.arm(tester.element(find.byType(ValueListenableBuilder<int>)));

    notifier.value = 2;
    await tester.pump();

    final cause = onlyCause();
    final notify = (cause['notifies']! as List<Object?>).single! as Map;
    expect(notify['before'], 1);
    expect(notify['after'], 2);
    final readers = rebuilt(cause);
    expect(readers.single['via'], 'builder');
    expect(readers.single['type'], 'ValueListenableBuilder<int>');
    // One reader, one notify: nothing to say about coupling.
    expect(cause.containsKey('hint'), isFalse);
  });

  scenario('a setState in a watched State is a notable event with its line '
      'and its widget as the reader', (tester) async {
    final key = GlobalKey<SpinnerState>();
    await tester.pumpWidget(MaterialApp(home: Spinner(key: key)));
    host.lens.arm(tester.element(find.byType(Spinner)));

    key.currentState!.toggle();
    await tester.pump();

    // The test file is in the stack of every `setState` in a pumped frame:
    // the framework's own come with it. The State followed comes first.
    final causes = host.lens.chain()['causes']! as List<Object?>;
    final cause = causes.single! as Map<String, Object?>;
    final set = (cause['setStates']! as List<Object?>).first! as Map;
    expect(set['widget'], 'Spinner');
    expect(set['method'], 'SpinnerState.toggle');
    expect(set['file'], _support);
    expect(
      rebuilt(cause).where((r) => r['type'] == 'Spinner').single['via'],
      'setState',
    );
  });

  scenario('two separate actions are two causes, oldest first', (tester) async {
    final model = ProductModel();
    await tester.pumpWidget(
      MaterialApp(
        home: FakeScope<ProductModel>(
          model: model,
          child: const ProductScreen(),
        ),
      ),
    );
    host.lens.arm(tester.element(find.byType(ProductScreen)));

    model.fetchDialog();
    await tester.pump();
    model.fetchDialog();
    await tester.pump();

    final causes = [
      for (final c in host.lens.chain()['causes']! as List<Object?>)
        if (((c! as Map)['notifies']! as List).isNotEmpty)
          c as Map<String, Object?>,
    ];
    expect(causes, hasLength(2));
    expect(
      causes.first['frame']! as int,
      lessThan(causes.last['frame']! as int),
    );
  });

  group('coupling hint, from events alone', () {
    TraceEvent notify(
      int seq,
      String owner,
      String tag, {
      String method = 'M.go',
      int? depth,
    }) => TraceEvent(
      seq: seq,
      t: seq,
      frame: 1,
      kind: TraceKind.stateNotify,
      widget: owner,
      data: {'owner': owner, 'tag': tag, 'method': method, 'depth': ?depth},
    );

    FlowReader reader(String type, String tag, {String via = 'dependency'}) =>
        FlowReader(
          type: type,
          via: via,
          tag: tag,
          owner: 'Model',
          source: type,
        );

    test('nothing to say for one notify and one reader', () {
      expect(
        couplingHint([notify(1, 'A', '#a1')], const [], [reader('X', '#a1')]),
        isNull,
      );
    });

    test('a notify nested with no outer one followed says so', () {
      final hint = couplingHint(
        [notify(1, 'B', '#a2', depth: 2)],
        const [],
        const [],
      );
      expect(hint, contains('shape 2: B (M.go) notified inside the listener'));
    });

    test('shapes join in one line', () {
      final hint = couplingHint(
        [notify(1, 'A', '#a1')],
        const [],
        [reader('X', '#a1'), reader('Y', '#a1')],
      );
      expect(hint, contains('shape 1'));
      expect(hint, contains('; shape 3: X and Y read the same object'));
      expect(hint, isNot(contains('\n')));
    });

    test('the chain names a cause and drops the oldest past the limit', () {
      final recorder = TraceRecorder();
      for (var i = 0; i < maxFlowCauses + 3; i++) {
        recorder.add(
          TraceKind.stateNotify,
          widget: 'A',
          data: {'owner': 'A', 'tag': '#a1'},
        );
      }
      // No cause zone in a unit test: each notify is its own group only
      // when frames differ.
      expect(
        stateFlowChain(recorder, fromSeq: 1, rebuilds: const [])['events'],
        maxFlowCauses + 3,
      );
    });
  });

  test('a setState that no one follows and no project frame names is not a '
      'row, and a cause left with no row is not listed', () {
    final recorder = TraceRecorder();
    // As an older build recorded the engine's `invoke()` setStates.
    recorder.add(
      TraceKind.stateSetState,
      widget: '_Interactive',
      data: {'element': '_Interactive(dirty)', 'watched': false},
    );
    recorder.add(
      TraceKind.stateSetState,
      widget: 'Home',
      data: {
        'element': 'Home(dirty)',
        'watched': false,
        'file': 'lib/home.dart',
        'line': 3,
        'method': 'HomeState.load',
      },
    );
    final chain = stateFlowChain(recorder, fromSeq: 0, rebuilds: const []);
    expect(chain['events'], 1);
    final causes = chain['causes']! as List<Object?>;
    expect(causes, hasLength(1));
    final rows = (causes.single! as Map)['setStates']! as List<Object?>;
    expect(rows, hasLength(1));
    expect((rows.single! as Map)['widget'], 'Home');

    final noise = TraceRecorder();
    noise.add(
      TraceKind.stateSetState,
      widget: 'Focus',
      data: {'element': 'Focus(dirty)', 'watched': false},
    );
    final empty = stateFlowChain(noise, fromSeq: 0, rebuilds: const []);
    expect(empty['events'], 0);
    expect(empty['causes'], isEmpty);
  });
}

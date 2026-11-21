import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/state/hover_namer.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/story.dart';
import 'package:pinpoint/src/trace/story_names.dart';

import '../support/fake_provider.dart';
import '../support/lens_host.dart';

/// PLAN-v3 Milestone 21b: the story from real widgets and the real lens.
/// One scenario per kind of app in the plan's "Tests" paragraph. The pure
/// rules are in `test/trace/story_test.dart`.
void main() {
  late LensHost host;
  // The recorder's clock, for the story's own times.
  var fakeNow = 0;

  const DebugPrintCallback initialPrint = debugPrintSynchronously;
  void scenario(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        fakeNow = 0;
        host = LensHost(
          content: () => tester.element(find.byType(MaterialApp)),
          clock: () => fakeNow,
        );
        try {
          await body(tester);
        } finally {
          host.dispose();
          CauseZone.debugReset();
          expect(debugPrint, same(initialPrint));
          expect(debugPrintScheduleBuildForStacks, isFalse);
          expect(HoverNamer.debugInstalled, 0);
        }
      });

  Story story([StoryFilter filter = const StoryFilter()]) =>
      host.lens.story(filter);

  // The framework's own `setState` calls carry the test file in their stack
  // in a widget test, so a story also has setState rows; these read the
  // notify rows.
  List<StoryRow> stateRowsOf(Story story) => [
    for (final b in story.blocks) ...b.rows,
  ];

  List<StoryRow> rowsOf(Story story) => [
    for (final b in story.blocks)
      for (final r in b.rows)
        if (r.kind == 'notify') r,
  ];

  Future<void> pump(WidgetTester tester, Widget home) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: home)));

  // ---------------------------------------------------------------------
  scenario('a tap that sets two fields in a ChangeNotifier: one row, the '
      'method, both readers, one hint, and no tag anywhere', (tester) async {
    final model = ProductModel();
    await pump(
      tester,
      FakeScope<ProductModel>(
        model: model,
        child: const Column(children: [ProductScreen(), FetchDialog()]),
      ),
    );
    host.lens.arm(tester.element(find.byType(ProductScreen)));

    model.fetchDialog();
    await tester.pump();

    final s = story();
    final block = s.blocks.firstWhere(
      (b) => b.rows.any((r) => r.owner == 'ProductModel'),
    );
    final row = block.rows.firstWhere((r) => r.owner == 'ProductModel');
    expect(storyName(row).text, 'ProductModel');
    expect(row.method, 'ProductModel.fetchDialog');
    expect(row.file, endsWith('test/support/fake_provider.dart'));
    expect(block.rebuilt, containsAll(['ProductScreen', 'FetchDialog']));
    expect(block.hint, contains('widgets read'));
    // Without PinPoint.run: no cause, said once at the top.
    expect(block.cause.label, 'no cause recorded');
    expect(s.noCauseHint, contains('PinPoint.run'));
    expect(
      s.toJson().toString(),
      isNot(
        contains(
          'hint: ProductScreen and FetchDialog read the same ProductModel #',
        ),
      ),
    );
    expect(block.hint, isNot(contains('#a')));
    // Relative time, from the start of the watch.
    expect(blockTime(block), matches(RegExp(r'^\+\d+\.\d\d s$')));
  });

  // ---------------------------------------------------------------------
  scenario('20 rows, each with its own ValueNotifier: one row "xN" with '
      'instances named by Key, index and text', (tester) async {
    final notifiers = [for (var i = 0; i < 20; i++) ValueNotifier<bool>(false)];
    addTearDown(() {
      for (final n in notifiers) {
        n.dispose();
      }
    });
    // One line creates every builder: they are one group.
    Widget builder(int i) => ValueListenableBuilder<bool>(
      key: i < 5 ? ValueKey('row-$i') : null,
      valueListenable: notifiers[i],
      builder: (context, on, _) => Text('row $i $on'),
    );
    await pump(
      tester,
      SingleChildScrollView(
        child: Column(
          key: const ValueKey('list'),
          children: [
            for (var i = 0; i < 20; i++)
              if (i < 10) builder(i) else Center(child: builder(i)),
          ],
        ),
      ),
    );
    host.lens.arm(tester.element(find.byKey(const ValueKey('list'))));
    expect(host.lens.value.armed, isTrue);

    notifiers[3].value = true; // a Key
    notifiers[7].value = true; // an index
    notifiers[12].value = true; // the text of the widget
    notifiers[4].value = true;
    notifiers[3].value = false;
    await tester.pump();

    final row = rowsOf(
      story(),
    ).singleWhere((r) => r.owner == 'ValueNotifier<bool>');
    expect(row.count, 5);
    expect(row.instanceCount, 4);
    expect(row.base, 'ValueNotifier');
    final labels = [for (final i in row.instances) i.label];
    expect(labels, contains('key row-3'));
    expect(labels, contains('key row-4'));
    expect(labels, contains('index 12'));
    expect(
      labels.any((l) => l.startsWith('index ')),
      isTrue,
      reason: '$labels',
    );
    expect(row.changes.map((c) => (c.text, c.count)).toList(), [
      ('false → true', 4),
      ('true → false', 1),
    ]);
    // All 20 rows share one creating line: one row, with the `src` that
    // the bridge reads the name from.
    expect(row.src, startsWith('test/state/story_lens_test.dart:'));
    expect(row.srcArg, 'valueListenable');
    expect(
      rowHeadline(row, storyName(row, expression: 'notifiers')),
      'notifiers (ValueNotifier<bool>) ×5',
    );
  });

  // ---------------------------------------------------------------------
  scenario('an Equatable-style toString: only the changed field', (
    tester,
  ) async {
    final notifier = ValueNotifier<_Money>(_Money(1, 'EUR'));
    addTearDown(notifier.dispose);
    await pump(
      tester,
      ValueListenableBuilder<_Money>(
        valueListenable: notifier,
        builder: (context, m, _) => Text('$m'),
      ),
    );
    host.lens.arm(tester.element(find.byType(ValueListenableBuilder<_Money>)));

    notifier.value = _Money(2, 'EUR');
    notifier.value = _Money(2, 'EUR'); // equal by ==: no notify
    await tester.pump();

    final row = rowsOf(story()).single;
    expect(changesText(row), 'amount 1 → 2');
    expect(row.owner, 'ValueNotifier<_Money>');
  });

  // ---------------------------------------------------------------------
  scenario('a mutable list changed in place says so, with the length', (
    tester,
  ) async {
    final notifier = _ListNotifier();
    addTearDown(notifier.dispose);
    await pump(
      tester,
      ValueListenableBuilder<List<int>>(
        valueListenable: notifier,
        builder: (context, items, _) => Text('${items.length}'),
      ),
    );
    host.lens.arm(
      tester.element(find.byType(ValueListenableBuilder<List<int>>)),
    );

    notifier.add(3);
    notifier.replaceWithSame();
    await tester.pump();

    final row = rowsOf(story()).single;
    expect(row.changes.map((c) => c.text), [
      'changed in place: length 2 → 3',
      'new object, same value',
    ]);
  });

  // ---------------------------------------------------------------------
  scenario('a value that is a secret is masked, a controller shows no value '
      'at all', (tester) async {
    final login = ValueNotifier<_Login>(_Login('bob', 'a'));
    final controller = TextEditingController();
    addTearDown(login.dispose);
    addTearDown(controller.dispose);
    await pump(
      tester,
      Column(
        children: [
          ValueListenableBuilder<_Login>(
            valueListenable: login,
            builder: (context, v, _) => Text('$v'),
          ),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Text(controller.text),
          ),
        ],
      ),
    );
    host.lens.arm(tester.element(find.byType(Column).first));

    login.value = _Login('bob', 'hunter2');
    controller.text = 'my secret';
    await tester.pump();

    final all = story(const StoryFilter(showControllers: true));
    final text = all.toJson().toString();
    expect(text, isNot(contains('hunter2')));
    expect(text, isNot(contains('my secret')));
    final events = [
      for (final e in host.recorder.events)
        if (e.kind == TraceKind.stateNotify) e,
    ];
    final controllerEvent = events.firstWhere(
      (e) => e.data['owner'] == 'TextEditingController',
    );
    expect(controllerEvent.data.containsKey('after'), isFalse);
    expect(controllerEvent.data.containsKey('change'), isFalse);
    final rows = rowsOf(all);
    expect(
      rows
          .firstWhere((r) => r.owner.startsWith('ValueNotifier'))
          .changes
          .single
          .text,
      'password *** → ***',
    );
    expect(
      verbText(rows.firstWhere((r) => r.owner == 'TextEditingController')),
      'text changed',
    );
  });

  // ---------------------------------------------------------------------
  scenario('a timer made outside every cause is its own block', (tester) async {
    final zone = CauseZone();
    zone.run(() {});
    final model = CartModel();
    await pump(
      tester,
      FakeScope<CartModel>(model: model, child: const ProductAndCartOnly()),
    );
    host.lens.arm(tester.element(find.byType(ProductAndCartOnly)));
    zone.run(() {
      Timer(const Duration(milliseconds: 500), model.bump);
    });

    await tester.pump(const Duration(milliseconds: 600));

    final s = story();
    final block = s.blocks.firstWhere(
      (b) => b.rows.any((r) => r.owner == 'CartModel'),
    );
    expect(block.cause.kind, StoryKind.timer);
    expect(block.cause.label, 'timer or async callback');
    // A cause zone runs: nothing to say about PinPoint.run.
    expect(s.noCauseHint, isNull);
  });

  // ---------------------------------------------------------------------
  scenario('a change after an await keeps the tap and carries "+420 ms"', (
    tester,
  ) async {
    CauseZone().run(() {});
    final loading = ValueNotifier<bool>(false);
    final items = ValueNotifier<int>(0);
    addTearDown(loading.dispose);
    addTearDown(items.dispose);
    await pump(
      tester,
      Column(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: loading,
            builder: (context, v, _) => Text('$v'),
          ),
          ValueListenableBuilder<int>(
            valueListenable: items,
            builder: (context, v, _) => Text('$v'),
          ),
        ],
      ),
    );
    host.lens.arm(tester.element(find.byType(Column)));

    unawaited(
      CauseZone.enter(CauseKind.pointer, () async {
        host.recorder.add(
          TraceKind.pointer,
          widget: 'FetchButton',
          data: {'phase': 'up', 'pointer': 1, 'label': 'Fetch'},
        );
        loading.value = true;
        await Future<void>.delayed(const Duration(milliseconds: 420));
        fakeNow += 420;
        items.value = 5;
        loading.value = false;
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    final block = story().blocks.singleWhere((b) => b.rows.length > 1);
    expect(block.cause.kind, StoryKind.tap);
    expect(block.cause.label, 'tap "Fetch"');
    expect(block.rows.first.afterMs, isNull);
    final late = block.rows.where((r) => r.afterMs != null).toList();
    expect(late, isNotEmpty);
    expect(late.first.afterMs, inInclusiveRange(400, 470));
  });

  // ---------------------------------------------------------------------
  scenario('a hover over a list names the widget on enter and leave only, '
      'and the story folds it', (tester) async {
    CauseZone().run(() {});
    final hovered = [for (var i = 0; i < 4; i++) ValueNotifier<bool>(false)];
    addTearDown(() {
      for (final n in hovered) {
        n.dispose();
      }
    });
    await pump(
      tester,
      Column(
        children: [
          for (var i = 0; i < 4; i++) _HoverRow(index: i, hovered: hovered[i]),
        ],
      ),
    );
    final mouse = PointerDeviceKind.mouse;
    tester.binding.handlePointerEvent(
      PointerAddedEvent(position: const Offset(2, 2), kind: mouse),
    );
    host.lens.arm(tester.element(find.byType(Column)));
    expect(HoverNamer.debugInstalled, 1);
    final seqBefore = host.recorder.nextSeq;

    void moveTo(Offset position) => CauseZone.enter(
      CauseKind.pointer,
      () => tester.binding.handlePointerEvent(
        PointerHoverEvent(position: position, kind: mouse),
      ),
    );
    final row1 = tester.getCenter(find.byType(_HoverRow).at(1));
    final row2 = tester.getCenter(find.byType(_HoverRow).at(2));
    moveTo(row1); // enter row 1
    moveTo(row1 + const Offset(3, 0)); // a move inside: names nothing new
    moveTo(row2); // leave row 1, enter row 2
    await tester.pump();

    final hoverEvents = [
      for (final e in host.recorder.events)
        if (e.seq >= seqBefore &&
            e.kind == TraceKind.pointer &&
            e.data['phase'] == 'hover')
          e,
    ];
    // Enter and leave only: one event for each change of the widget, not
    // one for each move.
    expect(hoverEvents, hasLength(2));
    expect(hoverEvents.first.widget, '_HoverRow');
    expect(hoverEvents.last.data['left'], isNotNull);

    final folded = story();
    expect(folded.hiddenHover, greaterThan(0));
    expect(
      folded.blocks.where((b) => b.cause.kind == StoryKind.hover),
      isEmpty,
    );

    final shown = story(const StoryFilter(showHover: true));
    expect(shown.hiddenHover, 0);
    expect(shown.blocks.first.cause.kind, StoryKind.hover);
    expect(shown.blocks.first.cause.label, startsWith('hover'));
    // Two blocks that say the same fold into one with a count.
    final all = rowsOf(shown).where((r) => r.owner == 'ValueNotifier<bool>');
    expect(all, isNotEmpty);
    expect(
      all.first.instances.map((i) => i.label).any((l) => l.startsWith('index')),
      isTrue,
    );

    host.lens.stop();
    expect(HoverNamer.debugInstalled, 0);
  });

  scenario('no hover is named while the lens is not armed', (tester) async {
    CauseZone().run(() {});
    final hovered = ValueNotifier<bool>(false);
    addTearDown(hovered.dispose);
    await pump(tester, _HoverRow(index: 0, hovered: hovered));
    expect(HoverNamer.debugInstalled, 0);
    final seqBefore = host.recorder.nextSeq;
    tester.binding.handlePointerEvent(
      const PointerAddedEvent(
        position: Offset(2, 2),
        kind: PointerDeviceKind.mouse,
      ),
    );
    CauseZone.enter(
      CauseKind.pointer,
      () => tester.binding.handlePointerEvent(
        PointerHoverEvent(
          position: tester.getCenter(find.byType(_HoverRow)),
          kind: PointerDeviceKind.mouse,
        ),
      ),
    );
    await tester.pump();
    expect(host.recorder.nextSeq, seqBefore);
  });

  // ---------------------------------------------------------------------
  scenario('controllers: a verb each, folded; an animation is one block', (
    tester,
  ) async {
    final focus = FocusNode();
    final tabs = TabController(length: 3, vsync: const TestVSync());
    final animation = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(focus.dispose);
    addTearDown(tabs.dispose);
    addTearDown(animation.dispose);
    await pump(
      tester,
      Column(
        children: [
          ListenableBuilder(
            listenable: focus,
            builder: (context, _) => Text('${focus.hasFocus}'),
          ),
          ListenableBuilder(
            listenable: tabs,
            builder: (context, _) => Text('${tabs.index}'),
          ),
          ValueListenableBuilder<double>(
            valueListenable: animation,
            builder: (context, v, _) => Text('$v'),
          ),
        ],
      ),
    );
    host.lens.arm(tester.element(find.byType(Column)));

    tabs.index = 2;
    animation.forward();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final folded = story();
    expect(rowsOf(folded).where((r) => r.verb != null), isEmpty);
    expect(folded.hiddenControllers, greaterThan(3));
    animation.stop();
    final shown = story(const StoryFilter(showControllers: true));
    final verbs = {for (final r in rowsOf(shown)) verbText(r)};
    expect(verbs, contains('tab index 2'));
    expect(verbs, contains('animation'));
    // The frames of the animation fold into one block with a count.
    final run = shown.blocks
        .where((b) => b.rows.any((r) => r.verb == 'animation'))
        .reduce((a, b) => a.repeat >= b.repeat ? a : b);
    expect(run.repeat, greaterThan(1));
  });

  // ---------------------------------------------------------------------
  scenario('a setState-only story: the method, its line, the widget that '
      'rebuilt', (tester) async {
    await pump(tester, const _Counter());
    host.lens.arm(tester.element(find.byType(_Counter)));

    await tester.tap(find.text('count 0'));
    await tester.pump();

    final s = story();
    final row = stateRowsOf(s).firstWhere(
      (r) => r.kind == 'setState' && (r.method ?? '').contains('_bump'),
      orElse: () => throw StateError('${s.toJson()}'),
    );
    expect(row.owner, '_Counter');
    expect(row.file, endsWith('test/state/story_lens_test.dart'));
    expect(row.line, isNotNull);
    expect(storyMethod(row.method), contains('_bump'));
    expect(s.blocks.any((b) => b.rebuilt.contains('_Counter')), isTrue);
  });

  // ---------------------------------------------------------------------
  scenario('an agent command is labelled as the agent', (tester) async {
    CauseZone().run(() {});
    final model = CartModel();
    await pump(
      tester,
      FakeScope<CartModel>(model: model, child: const ProductAndCartOnly()),
    );
    host.lens.arm(tester.element(find.byType(ProductAndCartOnly)));

    CauseZone.enter(CauseKind.agent, model.bump);
    await tester.pump();

    final block = story().blocks.firstWhere(
      (b) => b.rows.any((r) => r.owner == 'CartModel'),
    );
    expect(block.cause.kind, StoryKind.agent);
    expect(block.cause.label, 'agent command');
  });

  // ---------------------------------------------------------------------
  scenario('the end lines: hot reload goes on, the target leaving ends the '
      'story, and the window ends', (tester) async {
    final model = CartModel();
    await pump(
      tester,
      FakeScope<CartModel>(model: model, child: const ProductAndCartOnly()),
    );
    host.lens.arm(tester.element(find.byType(ProductAndCartOnly)));
    model.bump();
    await tester.pump();

    host.lens.noteReassemble();
    await tester.pump();
    expect(host.lens.armed, isTrue);
    expect(story().ends.map((e) => e.text), ['hot reload']);

    await pump(tester, const SizedBox());
    await tester.pump();
    await tester.pump();

    expect(host.lens.armed, isFalse);
    expect(host.lens.value.endedBecause, 'target unmounted');
    final ends = story().ends.map((e) => e.text).toList();
    expect(ends, ['hot reload', 'target left the screen']);
    expect(story().blocks, isNotEmpty);
  });

  scenario('the window ending by itself is the last line', (tester) async {
    final model = CartModel();
    await pump(
      tester,
      FakeScope<CartModel>(model: model, child: const ProductAndCartOnly()),
    );
    host.lens.arm(
      tester.element(find.byType(ProductAndCartOnly)),
      window: const Duration(seconds: 2),
    );
    model.bump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(host.lens.armed, isFalse);
    expect(story().ends.single.text, 'window ended');
  });

  scenario('no timer and no extra frame: the story is read, not driven', (
    tester,
  ) async {
    final model = CartModel();
    await pump(
      tester,
      FakeScope<CartModel>(model: model, child: const ProductAndCartOnly()),
    );
    host.lens.arm(tester.element(find.byType(ProductAndCartOnly)));
    model.bump();
    await tester.pump();
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);

    story();
    story(const StoryFilter(showHover: true, showControllers: true));

    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}

class _Money {
  _Money(this.amount, this.currency);
  final int amount;
  final String currency;

  @override
  bool operator ==(Object other) =>
      other is _Money && other.amount == amount && other.currency == currency;

  @override
  int get hashCode => Object.hash(amount, currency);

  @override
  String toString() => '_Money(amount: $amount, currency: $currency)';
}

class _Login {
  _Login(this.user, this.password);
  final String user;
  final String password;

  @override
  String toString() => '_Login(user: $user, password: $password)';
}

class _ListNotifier extends ValueNotifier<List<int>> {
  _ListNotifier() : super(<int>[1, 2]);

  void add(int v) {
    value.add(v);
    notifyListeners();
  }

  void replaceWithSame() {
    // A new list with the same items: `ValueNotifier` notifies, as lists
    // are not equal by value.
    value = List<int>.of(value);
  }
}

class ProductAndCartOnly extends StatelessWidget {
  const ProductAndCartOnly({super.key});

  @override
  Widget build(BuildContext context) =>
      Text('cart ${watchFake<CartModel>(context).count}');
}

class _HoverRow extends StatelessWidget {
  const _HoverRow({required this.index, required this.hovered});

  final int index;
  final ValueNotifier<bool> hovered;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => hovered.value = true,
    onExit: (_) => hovered.value = false,
    child: ValueListenableBuilder<bool>(
      valueListenable: hovered,
      builder: (context, on, _) =>
          SizedBox(height: 40, child: Text('row $index $on')),
    ),
  );
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  void _bump() => setState(() => count++);

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onTap: _bump, child: Text('count $count'));
}

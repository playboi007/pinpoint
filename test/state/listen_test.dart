import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/hook_registry.dart';
import 'package:pinpoint/src/model/source_location.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/search/source_resolver.dart';
import 'package:pinpoint/src/state/dependencies.dart';
import 'package:pinpoint/src/state/listen.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

import '../support/markers.dart';

const String _thisFile = 'test/state/listen_test.dart';

/// PLAN-v3 Milestone 21, build step 2: Pinpoint's own listener.
void main() {
  final resolver = SourceResolver(
    paths: SourcePaths(projectRoot: Directory.current.path),
  );
  late TraceRecorder recorder;
  late StateListen listen;

  setUp(() {
    recorder = TraceRecorder();
    listen = StateListen(
      recorder: recorder,
      resolver: resolver,
      tags: IdentityTags(),
    );
  });
  tearDown(() => listen.stop());

  List<TraceEvent> notifies() => [
    for (final e in recorder.events)
      if (e.kind == TraceKind.stateNotify) e,
  ];

  testWidgets('a ValueNotifier in a ValueListenableBuilder gives before and '
      'after, and this file as the first project frame', (tester) async {
    final notifier = _Counting(1);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: notifier,
          builder: (_, value, _) => Text('v$value'),
        ),
      ),
    );
    final root = tester.element(find.byType(ValueListenableBuilder<int>));
    expect(listen.attachSubtree(tester.element(find.byType(MaterialApp))), 1);
    expect(listen.isAttached(notifier), isTrue);
    expect(root.mounted, isTrue);

    // PIN:set_value
    notifier.value = 5;
    await tester.pump();
    notifier.value = 7;
    await tester.pump();

    final events = notifies();
    expect(events, hasLength(2));
    final first = events.first;
    expect(first.data['before'], 1);
    expect(first.data['after'], 5);
    expect(events.last.data['before'], 5);
    expect(events.last.data['after'], 7);
    expect(first.data['via'], 'ValueListenableBuilder');
    expect(first.data['owner'], '_Counting');
    expect(first.data['tag'], '#a1');
    expect(first.widget, '_Counting');
    expect(first.data['file'], _thisFile);
    expect(first.data['line'], markerLine(_thisFile, 'set_value'));
    expect(first.data['method'], contains('main'));
    expect(first.source, startsWith('$_thisFile:'));
    // Our listener does not change what the app sees.
    expect(find.text('v7'), findsOneWidget);
  });

  testWidgets('a ChangeNotifier a provider scope holds: the method that '
      'notified is the frame', (tester) async {
    final model = _Model();
    await tester.pumpWidget(
      MaterialApp(
        home: _InheritedProviderScope<_Model?>(
          value: model,
          child: const _Reader(),
        ),
      ),
    );
    final reader = nearestReaders(
      tester.element(find.byType(_Reader)),
      resolver,
      tags: listen.tags,
    ).single;
    expect(listen.attachDependencies(reader.dependencies), 1);
    // The same object again adds nothing.
    expect(listen.attachDependencies(reader.dependencies), 0);

    model.fetch();
    final event = notifies().single;
    expect(event.data['owner'], '_Model');
    expect(event.data['tag'], reader.dependencies.single.tag);
    expect(event.data['via'], 'provider');
    expect(event.data['method'], '_Model.fetch');
    expect(event.data['file'], _thisFile);
    // A ChangeNotifier has no value to show.
    expect(event.data.containsKey('before'), isFalse);
  });

  testWidgets('no listener is left after unmount and after stop', (
    tester,
  ) async {
    final notifier = _Counting(0);
    final other = _Counting(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            ValueListenableBuilder<int>(
              valueListenable: notifier,
              builder: (_, value, _) => Text('$value'),
            ),
            ListenableBuilder(
              listenable: other,
              builder: (_, _) => const Text('other'),
            ),
          ],
        ),
      ),
    );
    expect(listen.attachSubtree(tester.element(find.byType(MaterialApp))), 2);
    // Each builder listens, and so does the lens.
    expect(notifier.listenerCount, 2);
    expect(other.listenerCount, 2);

    // Unmounting the builders: no call to the lens, the frame sweeps.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(notifier.listenerCount, 0);
    expect(other.listenerCount, 0);
    expect(listen.attached, 0);

    // Stop takes the rest off.
    final held = _Counting(0);
    expect(listen.attach(held, owner: 'Held'), isTrue);
    expect(held.listenerCount, 1);
    listen.stop();
    expect(held.listenerCount, 0);
    held.value = 1;
    expect(notifies(), isEmpty);
    // The lens cannot attach again once stopped.
    expect(listen.attach(held, owner: 'Held'), isFalse);
    expect(held.listenerCount, 0);
  });

  testWidgets('HookRegistry.dispose stops the lens', (tester) async {
    final hooks = HookRegistry();
    final lens = StateListen(
      recorder: recorder,
      resolver: resolver,
      hooks: hooks,
    );
    final held = _Counting(0);
    lens.attach(held, owner: 'Held');
    expect(held.listenerCount, 1);
    hooks.dispose();
    expect(held.listenerCount, 0);
  });

  testWidgets('an animation is passed over; a ListenableBuilder on a '
      'ChangeNotifier is followed', (tester) async {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(seconds: 1),
    );
    addTearDown(controller.dispose);
    final model = _Model();
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            AnimatedBuilder(
              animation: controller,
              builder: (_, _) => const Text('anim'),
            ),
            ListenableBuilder(
              listenable: model,
              builder: (_, _) => const Text('model'),
            ),
          ],
        ),
      ),
    );
    expect(listen.attachSubtree(tester.element(find.byType(MaterialApp))), 1);
    expect(listen.isAttached(controller), isFalse);
    expect(listen.isAttached(model), isTrue);
    model.fetch();
    expect(notifies().single.data['via'], 'ListenableBuilder');
  });

  testWidgets('values are clipped, and masked when the owner or a key is '
      'secret', (tester) async {
    final token = _Token('s3cret-value');
    final bag = _Bag({'name': 'a', 'api_token': 'abc'});
    final long = _Counting2('x' * 1000);
    listen.attach(token, owner: '_Token');
    listen.attach(bag, owner: '_Bag');
    listen.attach(long, owner: '_Counting2');
    token.value = 'other-secret';
    bag.value = {'name': 'b', 'api_token': 'def'};
    long.value = 'y' * 1000;

    final events = notifies();
    expect(events[0].data['before'], '***');
    expect(events[0].data['after'], '***');
    expect('${events[1].data['after']}', contains('name: b'));
    expect('${events[1].data['after']}', isNot(contains('def')));
    expect('${events[1].data['before']}', isNot(contains('abc')));
    expect(
      (events[2].data['after']! as String).length,
      lessThanOrEqualTo(maxTraceChars + 3),
    );
  });

  testWidgets('the attachments are capped', (tester) async {
    final small = StateListen(
      recorder: recorder,
      resolver: resolver,
      maxAttachments: 2,
    );
    addTearDown(small.stop);
    final all = [for (var i = 0; i < 4; i++) _Counting(i)];
    for (final n in all) {
      small.attach(n, owner: 'N');
    }
    expect(small.attached, 2);
  });
}

class _Counting extends ValueNotifier<int> {
  _Counting(super.value);

  final Set<VoidCallback> _held = <VoidCallback>{};
  int get listenerCount => _held.length;

  @override
  void addListener(VoidCallback listener) {
    _held.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _held.remove(listener);
    super.removeListener(listener);
  }
}

class _Counting2 extends ValueNotifier<String> {
  _Counting2(super.value);
}

class _Token extends ValueNotifier<String> {
  _Token(super.value);
}

class _Bag extends ValueNotifier<Map<String, String>> {
  _Bag(super.value);
}

class _Model extends ChangeNotifier {
  void fetch() {
    notifyListeners();
  }
}

class _InheritedProviderScope<T> extends InheritedWidget {
  const _InheritedProviderScope({required this.value, required super.child});

  final Object? value;

  @override
  bool updateShouldNotify(_InheritedProviderScope<T> oldWidget) => false;

  @override
  InheritedElement createElement() => _ScopeElement(this);
}

class _ScopeElement extends InheritedElement {
  _ScopeElement(super.widget);

  Object? get value => (widget as _InheritedProviderScope<Object?>).value;
}

class _Reader extends StatelessWidget {
  const _Reader();

  @override
  Widget build(BuildContext context) {
    context
        .dependOnInheritedWidgetOfExactType<_InheritedProviderScope<_Model?>>();
    return const SizedBox();
  }
}

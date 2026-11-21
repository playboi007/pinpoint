import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/hook_registry.dart';
import 'package:pinpoint/src/model/source_location.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/state/build_stacks.dart';
import 'package:pinpoint/src/state/stack_frames.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

import '../support/markers.dart';

const String _thisFile = 'test/state/build_stacks_test.dart';

/// PLAN-v3 Milestone 21, build step 3: who called `setState`, in an armed
/// window.
void main() {
  final paths = SourcePaths(projectRoot: Directory.current.path);
  late TraceRecorder recorder;
  late HookRegistry hooks;
  late List<String> console;
  late DebugPrintCallback original;
  var now = 0;

  setUp(() {
    recorder = TraceRecorder();
    hooks = HookRegistry();
    now = 0;
    console = <String>[];
    // The "real" debugPrint of the test: what the window must forward to.
    original = (String? message, {int? wrapWidth}) => console.add('$message');
    debugPrint = original;
  });

  // The test binding checks `debugPrint` after the body and before any
  // tearDown: put the binding's own callback back at the end of a body.
  // What the automated test binding expects `debugPrint` to be.
  const DebugPrintCallback initialPrint = debugPrintSynchronously;
  void scenario(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        try {
          await body(tester);
        } finally {
          hooks.dispose();
          debugPrint = initialPrint;
          debugPrintScheduleBuildForStacks = false;
        }
      });
  tearDown(() {
    hooks.dispose();
    debugPrintScheduleBuildForStacks = false;
  });

  BuildStacks make({
    Iterable<Element> Function()? watched,
    Element? Function()? content,
    ProjectFiles Function()? projectFiles,
    TraceRecorder? into,
    int maxPerSecond = BuildStacks.defaultMaxPerSecond,
  }) => BuildStacks(
    hooks: hooks,
    recorder: into ?? recorder,
    paths: paths,
    watched: watched,
    content: content,
    projectFiles: projectFiles,
    maxPerSecond: maxPerSecond,
    clock: () => now,
  );

  List<TraceEvent> setStates() => [
    for (final e in recorder.events)
      if (e.kind == TraceKind.stateSetState) e,
  ];

  Future<_SState> pumpState(WidgetTester tester) async {
    await tester.pumpWidget(const _S());
    return tester.state<_SState>(find.byType(_S));
  }

  scenario('a setState in a watched State gives its line', (tester) async {
    final state = await pumpState(tester);
    final element = tester.element(find.byType(_S));
    final stacks = make(watched: () => [element]);
    stacks.start(const Duration(seconds: 5));
    expect(stacks.armed, isTrue);
    expect(debugPrintScheduleBuildForStacks, isTrue);

    state.bump();
    final summary = stacks.stop();

    final event = setStates().single;
    expect(event.widget, '_S');
    expect(event.data['watched'], isTrue);
    expect(event.data['state'], '_SState');
    expect(event.data['file'], _thisFile);
    expect(event.data['line'], markerLine(_thisFile, 'set_state'));
    expect(event.data['method'], '_SState.bump');
    expect(event.source, startsWith('$_thisFile:'));
    expect(event.data['element'], startsWith('_S(dirty'));
    expect(summary.recorded, 1);
    expect(summary.dropped, 0);
  });

  scenario('the framework lines are not forwarded; every other line is, '
      'unchanged', (tester) async {
    final state = await pumpState(tester);
    final stacks = make();
    stacks.start(const Duration(seconds: 5));

    debugPrint('before', wrapWidth: 40);
    state.bump();
    debugPrint('after');
    stacks.stop();

    expect(console, ['before', 'after']);
    expect(setStates(), hasLength(1));
    // After the window the real callback is back.
    expect(identical(debugPrint, original), isTrue);
  });

  scenario('the flag and debugPrint are restored after the window ends '
      'by itself', (tester) async {
    await pumpState(tester);
    final stacks = make();
    stacks.start(const Duration(seconds: 2));
    expect(identical(debugPrint, original), isFalse);

    await tester.pump(const Duration(seconds: 3));
    expect(stacks.armed, isFalse);
    expect(debugPrintScheduleBuildForStacks, isFalse);
    expect(identical(debugPrint, original), isTrue);
    // Stopping again changes nothing.
    stacks.stop();
    expect(identical(debugPrint, original), isTrue);
  });

  scenario('a flag that was already on stays on after the window', (
    tester,
  ) async {
    await pumpState(tester);
    debugPrintScheduleBuildForStacks = true;
    final stacks = make();
    stacks.start(const Duration(seconds: 2));
    stacks.stop();
    expect(debugPrintScheduleBuildForStacks, isTrue);
    debugPrintScheduleBuildForStacks = false;
  });

  scenario('both are restored after an error in the handler', (tester) async {
    final state = await pumpState(tester);
    final stacks = make(into: _Failing());
    stacks.start(const Duration(seconds: 5));
    // The failing recorder throws while a stack is recorded.
    state.bump();
    expect(stacks.armed, isFalse);
    expect(stacks.summary.failure, contains('handler failed'));
    expect(debugPrintScheduleBuildForStacks, isFalse);
    expect(identical(debugPrint, original), isTrue);
  });

  scenario('HookRegistry.dispose closes an open window', (tester) async {
    await pumpState(tester);
    final stacks = make();
    stacks.start(const Duration(seconds: 5));
    hooks.dispose();
    expect(stacks.armed, isFalse);
    expect(debugPrintScheduleBuildForStacks, isFalse);
    expect(identical(debugPrint, original), isTrue);
  });

  scenario('the cap counts the stacks it drops, and a new second starts '
      'again', (tester) async {
    final state = await pumpState(tester);
    expect(BuildStacks.defaultMaxPerSecond, 30);
    final stacks = make(maxPerSecond: 3);
    stacks.start(const Duration(seconds: 5));
    for (var i = 0; i < 5; i++) {
      state.bump();
      await tester.pump();
    }
    expect(setStates(), hasLength(3));
    expect(stacks.dropped, 2);

    now += 1000;
    state.bump();
    await tester.pump();
    expect(setStates(), hasLength(4));

    final summary = stacks.stop();
    expect(summary.seen, 6);
    expect(summary.recorded, 4);
    expect(summary.dropped, 2);
    // The record says that it is partial.
    final dropped = [
      for (final e in recorder.events)
        if (e.kind == TraceKind.stateDropped) e,
    ];
    expect(dropped.single.data['n'], 2);
    // No line leaked to the console while stacks were dropped.
    expect(console, isEmpty);
  });

  scenario('a stack of the framework alone, for an element nobody follows, is '
      'left out; a stack with app code in it is kept', (tester) async {
    final stacks = make();
    stacks.start(const Duration(seconds: 5));
    // Shaped as `debugPrintStack` prints them (see api-notes, item 32).
    debugPrint('scheduleBuildFor() called for Tooltip(dirty)');
    debugPrint(
      '#0      debugPrintStack (package:flutter/src/foundation/assertions.dart:1213:29)\n'
      '#1      Element.markNeedsBuild (package:flutter/src/widgets/framework.dart:5403:12)\n'
      '#2      Ticker._tick (package:flutter/src/scheduler/ticker.dart:1:1)\n'
      '<asynchronous suspension>\n'
      '(elided one frame from package:stack_trace)',
    );
    debugPrint("...the build scope's dirty list is now: [Tooltip(dirty)]");
    expect(setStates(), isEmpty);

    debugPrint(
      'scheduleBuildFor() called for _HomeScreen(dirty, state: _HomeState#1) '
      '(ALREADY IN LIST)',
    );
    debugPrint(
      '#0      debugPrintStack (package:flutter/src/foundation/assertions.dart:1213:29)\n'
      '#1      State.setState (package:flutter/src/widgets/framework.dart:1221:15)\n'
      '#2      _HomeState.load.<anonymous closure> (package:my_app/home.dart:41:7)\n'
      '#3      Timer._run (dart:async/timer.dart:1:1)',
    );
    final summary = stacks.stop();

    expect(summary.seen, 2);
    expect(summary.filtered, 1);
    final event = setStates().single;
    expect(event.widget, '_HomeScreen');
    expect(event.data['watched'], isFalse);
    expect(event.data['inDirtyList'], isTrue);
    expect(event.data['file'], 'package:my_app/home.dart');
    expect(event.data['line'], 41);
    expect(event.data['method'], '_HomeState.load');
    // None of these lines reached the console.
    expect(console, isEmpty);
  });

  // The app's content next to a panel of Pinpoint's, as the wrapper builds
  // them: the content element is the boundary.
  final contentKey = GlobalKey();
  Future<(_SState, _OState)> pumpAppAndOverlay(WidgetTester tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            KeyedSubtree(key: contentKey, child: const _S()),
            const _O(),
          ],
        ),
      ),
    );
    return (
      tester.state<_SState>(find.byType(_S)),
      tester.state<_OState>(find.byType(_O)),
    );
  }

  Element? contentElement() => contentKey.currentContext as Element?;

  scenario('a setState in a widget of the overlay is not recorded, with a '
      'project frame in its stack or not', (tester) async {
    final (app, overlay) = await pumpAppAndOverlay(tester);
    // Two budgets: a label outside the content must not use them up.
    final stacks = make(content: contentElement, maxPerSecond: 2);
    stacks.start(const Duration(seconds: 5));

    for (var i = 0; i < 5; i++) {
      overlay.bump();
      await tester.pump();
    }
    app.bump();
    await tester.pump();
    final summary = stacks.stop();

    // The test file is a project frame for both; only the content counts.
    final event = setStates().single;
    expect(event.widget, '_S');
    expect(event.data['watched'], isFalse);
    expect(event.data['state'], '_SState');
    expect(event.data['file'], _thisFile);
    expect(event.data['method'], '_SState.bump');
    expect(summary.seen, 6);
    expect(summary.filtered, 5);
    expect(summary.recorded, 1);
    expect(summary.dropped, 0);
    expect(console, isEmpty);
  });

  scenario('an element the lens follows is recorded, also outside the '
      'content', (tester) async {
    final (_, overlay) = await pumpAppAndOverlay(tester);
    final element = tester.element(find.byType(_O));
    // Watched wins: the lens follows what it was told to follow.
    final stacks = make(content: contentElement, watched: () => [element]);
    stacks.start(const Duration(seconds: 5));
    overlay.bump();
    await tester.pump();
    stacks.stop();
    expect(setStates().single.data['watched'], isTrue);
  });

  scenario('a stack of the engine alone, for an element of the app, is left '
      'out', (tester) async {
    await pumpAppAndOverlay(tester);
    final element = tester.element(find.byType(_S));
    element.markNeedsBuild();
    final stacks = make(content: contentElement);
    stacks.start(const Duration(seconds: 5));
    // As a real app in Chrome prints it (api-notes item 34).
    debugPrint('scheduleBuildFor() called for $element');
    debugPrint(
      'lib/_engine/engine/platform_dispatcher.dart 1733:5   invoke\n'
      'packages/flutter/src/widgets/framework.dart 5307:7   markNeedsBuild\n'
      'lib/_engine/engine/platform_dispatcher.dart 1748:5   invoke1',
    );
    final summary = stacks.stop();
    await tester.pump();

    expect(setStates(), isEmpty);
    expect(summary.seen, 1);
    expect(summary.filtered, 1);
    expect(console, isEmpty);
  });

  scenario('a stack with a frame in a file of the app is recorded, as the '
      'path the bridge can open', (tester) async {
    await pumpAppAndOverlay(tester);
    final element = tester.element(find.byType(_S));
    element.markNeedsBuild();
    final files = ProjectFiles([
      'file://${Directory.current.path}/lib/src/features/x/y.dart',
    ], paths);
    final stacks = make(content: contentElement, projectFiles: () => files);
    stacks.start(const Duration(seconds: 5));
    debugPrint('scheduleBuildFor() called for $element');
    debugPrint(
      'lib/_engine/engine/platform_dispatcher.dart 1733:5   invoke\n'
      'packages/flutter/src/widgets/framework.dart 5307:7   markNeedsBuild\n'
      'package:genai_product/src/features/x/y.dart 88:5   fetchDialog',
    );
    stacks.stop();
    await tester.pump();

    final event = setStates().single;
    expect(event.widget, '_S');
    expect(event.data['file'], 'lib/src/features/x/y.dart');
    expect(event.data['line'], 88);
    expect(event.data['method'], 'fetchDialog');
    expect(event.data['state'], '_SState');
  });

  scenario('a line after a label that is not a stack is forwarded', (
    tester,
  ) async {
    final stacks = make();
    stacks.start(const Duration(seconds: 5));
    debugPrint('scheduleBuildFor() called for Foo(dirty)');
    debugPrint('hello');
    debugPrint('hello again');
    stacks.stop();
    expect(console, ['hello', 'hello again']);
  });

  scenario('a second start only moves the end of the window', (tester) async {
    await pumpState(tester);
    final stacks = make();
    stacks.start(const Duration(seconds: 1));
    stacks.start(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 2));
    expect(stacks.armed, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(stacks.armed, isFalse);
  });

  scenario('a window is never longer than the maximum', (tester) async {
    await pumpState(tester);
    final stacks = make();
    stacks.start(const Duration(minutes: 10));
    await tester.pump(BuildStacks.maxWindow + const Duration(seconds: 1));
    expect(stacks.armed, isFalse);
    expect(debugPrintScheduleBuildForStacks, isFalse);
  });
}

class _Failing extends TraceRecorder {
  @override
  TraceEvent add(
    String kind, {
    Map<String, Object?> data = const <String, Object?>{},
    String? widget,
    String? source,
    cause,
  }) => throw StateError('recorder is broken');
}

class _S extends StatefulWidget {
  const _S();

  @override
  State<_S> createState() => _SState();
}

class _SState extends State<_S> {
  int n = 0;

  void bump() {
    // PIN:set_state
    setState(() => n++);
  }

  @override
  Widget build(BuildContext context) =>
      Text('$n', textDirection: TextDirection.ltr);
}

class _O extends StatefulWidget {
  const _O();

  @override
  State<_O> createState() => _OState();
}

// Stands for a panel of Pinpoint's own, outside the content.
class _OState extends State<_O> {
  int n = 0;

  void bump() => setState(() => n++);

  @override
  Widget build(BuildContext context) =>
      Text('o$n', textDirection: TextDirection.ltr);
}

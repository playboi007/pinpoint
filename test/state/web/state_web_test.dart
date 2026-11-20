@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/hook_registry.dart';
import 'package:pinpoint/src/model/source_location.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/search/source_index.dart';
import 'package:pinpoint/src/search/source_resolver.dart';
import 'package:pinpoint/src/state/build_stacks.dart';
import 'package:pinpoint/src/state/console_filter.dart';
import 'package:pinpoint/src/state/stack_frames.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v3 Milestone 21, in Chrome: `flutter test --platform chrome
/// test/state/web` (and with `--wasm`).
///
/// On web, Flutter writes the label and the stack of each `scheduleBuildFor`
/// call to `console.error` before the dump listeners see them. These tests
/// check, in a real browser, that the stack is read in the DDC format, that
/// the first project frame is this file, and that the console filter keeps
/// those lines out of the console and forwards every other call.
void main() {
  late HookRegistry hooks;
  late JSObject console;
  late JSAny? realError;

  // What reached the "real" `console.error`, with all its arguments. The
  // browser's own function is put back after each test.
  late List<List<String>> reached;

  setUp(() {
    hooks = HookRegistry();
    reached = <List<String>>[];
    console = globalContext['console']! as JSObject;
    realError = console['error'];
    // A real variadic function: a Dart closure made by `toJS` has a fixed
    // arity, and DDC refuses a call with fewer arguments.
    globalContext['__pinpointRecord'] = ((JSArray<JSAny?> args) {
      reached.add([for (final value in args.toDart) '${value.dartify()}']);
    }).toJS;
    console['error'] = (globalContext['Function']! as JSFunction)
        .callAsConstructor<JSFunction>(
          'return globalThis.__pinpointRecord(Array.prototype.slice.call(arguments));'
              .toJS,
        );
  });

  tearDown(() {
    hooks.dispose();
    console['error'] = realError;
  });

  void error(String a, [String? b, String? c]) {
    final args = <JSAny?>[a.toJS, ?b?.toJS, ?c?.toJS];
    console.callMethodVarArgs<JSAny?>('error'.toJS, args);
  }

  test('the filter drops the scheduleBuildFor lines and forwards the rest '
      'with all their arguments', () {
    final filter = createConsoleFilter(hooks);
    expect(filter.available, isTrue);
    final original = console['error'];

    filter.install();
    expect(filter.active, isTrue);
    expect(console['error'], isNot(same(original)));

    error('scheduleBuildFor() called for Foo(dirty)');
    error('#0      debugPrintStack (package:flutter/src/foundation/a.dart:1)');
    error("...the build scope's dirty list is now: [Foo]");
    error('BuildOwner.scheduleBuildFor() called; _dirtyElementsNeedsResorting');
    error('packages/flutter/src/widgets/framework.dart 1:1  markNeedsBuild');
    // An unrelated error goes through, with every argument.
    error('Unhandled: boom', 'second', 'third');
    error('only one');
    // A stack that does not follow a label is not dropped.
    error('some other message');

    expect(reached, [
      ['Unhandled: boom', 'second', 'third'],
      ['only one'],
      ['some other message'],
    ]);
    expect(filter.dropped, 5);

    filter.restore();
    expect(filter.active, isFalse);
    expect(console['error'].strictEquals(original).toDart, isTrue);
    // Restored: the lines are the browser's again.
    reached.clear();
    error('scheduleBuildFor() called for Foo(dirty)');
    expect(reached, hasLength(1));
  });

  test('restore leaves a console.error that another script wrote', () {
    final filter = createConsoleFilter(hooks)..install();
    final theirs = (() => null).toJS;
    console['error'] = theirs;

    filter.restore();

    expect(console['error'].strictEquals(theirs).toDart, isTrue);
  });

  test('the registry restores the console when it is disposed', () {
    final original = console['error'];
    createConsoleFilter(hooks).install();
    expect(console['error'].strictEquals(original).toDart, isFalse);

    hooks.dispose();

    expect(console['error'].strictEquals(original).toDart, isTrue);
  });

  testWidgets('a setState while armed is read from the DDC stack: this file '
      'is the first project frame; the console stays clean', (tester) async {
    final recorder = TraceRecorder();
    final key = GlobalKey<_SpinnerState>();
    await tester.pumpWidget(MaterialApp(home: _Spinner(key: key)));
    final seenByListener = <String>[];
    ErrorToConsoleDumper.addWebDumpListener(seenByListener.add);

    final filter = createConsoleFilter(hooks)..install();
    final stacks = BuildStacks(
      hooks: hooks,
      recorder: recorder,
      paths: const SourcePaths(),
      watched: () => [tester.element(find.byType(_Spinner))],
    )..start(const Duration(seconds: 10));
    try {
      key.currentState!.toggle();
      await tester.pump();
    } finally {
      stacks.stop();
      filter.restore();
      // The binding checks debugPrint before any tearDown.
      hooks.dispose();
    }

    // The label and the stack came through the dump listener, in this
    // platform's format, and the filter kept them out of the console.
    final stack = seenByListener.firstWhere((m) => m.contains('.dart'));
    final first = firstProjectFrameIn(stack, const SourcePaths());
    // For the notes: the frame of this file as the browser reports it.
    // ignore: avoid_print
    print(
      'first project frame: $first\n'
      '${stack.split('\n').where((l) => l.contains('state_web_test')).take(2).join('\n')}',
    );
    expect(first, isNotNull);
    expect(first!.file, contains('state_web_test.dart'));
    expect(first.line, greaterThan(0));
    expect(filter.dropped, greaterThanOrEqualTo(2), reason: 'label and stack');
    expect(
      reached.where((a) => a.first.startsWith('scheduleBuildFor')),
      isEmpty,
    );
    expect(reached.where((a) => a.first.contains('dirty list')), isEmpty);

    final events = [
      for (final e in recorder.events)
        if (e.kind == TraceKind.stateSetState && e.widget == '_Spinner') e,
    ];
    expect(events, hasLength(1), reason: '${recorder.events.toList()}');
    final event = events.single;
    expect(event.data['watched'], isTrue);
    expect(event.data['file'], contains('state_web_test.dart'));
    expect(event.data['line'], isA<int>());
    // dart2wasm inlines `toggle`: the closure that called it is the frame.
    expect(event.data['method'], kIsWasm ? 'main' : 'toggle');
    // ignore: avoid_print
    print('state.setState: ${event.toJsonLine()}');
  });

  testWidgets('with the content and the app files known, a panel outside '
      'the content is not recorded, and the app is, with the file the '
      'widgets were created in', (tester) async {
    final recorder = TraceRecorder();
    final appKey = GlobalKey<_SpinnerState>();
    final panelKey = GlobalKey<_SpinnerState>();
    final contentKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            KeyedSubtree(
              key: contentKey,
              child: _Spinner(key: appKey),
            ),
            _Spinner(key: panelKey),
          ],
        ),
      ),
    );
    const paths = SourcePaths();
    final uris = SourceIndex(
      resolver: const SourceResolver(paths: paths),
    ).localFiles(root: contentKey.currentContext! as Element);
    final files = ProjectFiles(uris, paths);
    // ignore: avoid_print
    print('project files: $uris');
    expect(files.isEmpty, isFalse);

    final stacks = BuildStacks(
      hooks: hooks,
      recorder: recorder,
      paths: paths,
      content: () => contentKey.currentContext as Element?,
      projectFiles: () => files,
    )..start(const Duration(seconds: 10));
    try {
      panelKey.currentState!.toggle();
      await tester.pump();
      appKey.currentState!.toggle();
      await tester.pump();
    } finally {
      stacks.stop();
      hooks.dispose();
    }

    final events = [
      for (final e in recorder.events)
        if (e.kind == TraceKind.stateSetState) e,
    ];
    // ignore: avoid_print
    print('events: ${events.map((e) => e.toJsonLine()).join('\n')}');
    expect(events, hasLength(1), reason: '${stacks.summary}');
    expect(events.single.data['watched'], isFalse);
    expect(events.single.data['file'], contains('state_web_test.dart'));
    expect(stacks.summary.filtered, greaterThanOrEqualTo(1));
  });

  test('firstProjectFrame reads the DDC lines seen in Chrome', () {
    final frame = firstProjectFrameIn(
      'packages/flutter/src/widgets/framework.dart 5307:7  markNeedsBuild\n'
      'package:flutter/src/widgets/framework.dart 5307:7   markNeedsBuild\n'
      'http://localhost:54803/dart-sdk/lib/async/zone.dart 710:7   run\n'
      'package:pinpoint/src/state/a.dart 1:1   go\n'
      'package:shop/product_detail_provider.dart 88:5   fetchDialog\n'
      'state_web_test.dart 3:4   main',
      const SourcePaths(),
    );
    expect(frame!.file, 'package:shop/product_detail_provider.dart');
    expect(frame.line, 88);
    expect(frame.method, 'fetchDialog');

    // As the user's app in `flutter run -d chrome` prints the engine and
    // the framework (api-notes item 34): never the project.
    expect(
      firstProjectFrameIn(
        'lib/_engine/engine/platform_dispatcher.dart 1733:5   invoke\n'
        'packages/flutter/src/material/scrollbar.dart 429:5   handleHoverExit',
        const SourcePaths(),
      ),
      isNull,
    );
  });
}

class _Spinner extends StatefulWidget {
  const _Spinner({super.key});

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner> {
  bool busy = false;

  void toggle() {
    setState(() => busy = !busy);
  }

  @override
  Widget build(BuildContext context) => Text('spinner $busy');
}

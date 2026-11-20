import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/core/code_line_cache.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';
import 'package:pinpoint/src/overlay/source_location_button.dart';
import 'package:pinpoint/src/overlay/state_chain.dart';
import 'package:pinpoint/src/overlay/state_tab.dart';
import 'package:pinpoint/src/overlay/toast_layer.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/fake_bridge.dart';
import '../support/fake_provider.dart';
import '../support/trace_host.dart';

/// PLAN-v3 Milestone 21, build step 7: the State tab of the Info panel.
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
    BridgeClient.debugClient = null;
  });

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

  Future<void> pumpApp(
    WidgetTester tester, {
    Widget? home,
    PinPointConfig config = const PinPointConfig(),
  }) async {
    await tester.pumpWidget(
      traceApp(
        controller: controller,
        config: config,
        home:
            home ??
            FakeScope<ProductModel>(
              model: product,
              child: FakeScope<CartModel>(
                model: cart,
                child: const Column(
                  children: [ProductScreen(), ProductAndCart()],
                ),
              ),
            ),
      ),
    );
    await tester.pump();
  }

  /// Picks the text at [at], selects the crumb named [type] and opens the
  /// State tab.
  Future<void> openState(
    WidgetTester tester, {
    required Finder at,
    required String type,
  }) async {
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(at));
    await tester.pump();
    final selection = controller.selection.value!;
    for (var i = 0; i < selection.chain.length; i++) {
      if (selection.chain[i].name == type) {
        controller.selectChainIndex(i);
        break;
      }
    }
    await tester.pump();
    await tester.tap(find.byKey(InfoPanel.stateTabKey));
    await tester.pump();
  }

  /// Arms the lens on the selection as the tab's Watch button does, but
  /// without leaving picking: Watch itself closes the panel (see
  /// `watch_mode_test.dart`), and these tests read the panel.
  Future<void> armHere(WidgetTester tester) async {
    TraceSession.current!.stateLens.arm(controller.selection.value!.element);
    await tester.pump();
  }

  final panel = find.byKey(InfoPanel.panelKey);
  final screenText = find.textContaining('screen ');
  final watch = find.byKey(StateTab.watchKey);
  final stop = find.byKey(StateTab.stopKey);
  final tag = RegExp(r'#a\d+');

  Finder inPanel(Pattern text) =>
      find.descendant(of: panel, matching: find.textContaining(text));

  Finder hints() => find.byWidgetPredicate((w) {
    final key = w.key;
    return key is ValueKey<String> &&
        key.value.startsWith('pinpoint.stateTab.') &&
        key.value.endsWith('.hint');
  });

  /// The `#aN` of each row that matches [text].
  List<String> tagsOf(WidgetTester tester, Pattern text) => [
    for (final widget in tester.widgetList<Text>(inPanel(text)))
      tag.firstMatch(widget.textSpan?.toPlainText() ?? widget.data ?? '')![0]!,
  ];

  scenario('the tab lists what the widget reads, and a shared object shows '
      'the same tag on two rows', (tester) async {
    await pumpApp(
      tester,
      home: FakeScope<ProductModel>(
        model: product,
        child: const _Outer(child: ProductScreen()),
      ),
    );
    await openState(tester, at: screenText, type: 'ProductScreen');

    expect(inPanel('01 READS'), findsOneWidget);
    expect(inPanel('ProductScreen'), findsWidgets);
    expect(inPanel('_Outer'), findsWidgets);
    final rows = RegExp(r'^ProductModel #a\d+');
    expect(inPanel(rows), findsNWidgets(2));
    final tags = tagsOf(tester, rows);
    expect(tags.toSet(), hasLength(1), reason: '$tags');
    expect(
      find.descendant(of: panel, matching: find.text('provider')),
      findsNWidgets(2),
    );
    // Reading is cheap: nothing is armed.
    expect(TraceSession.current!.stateLens.armed, isFalse);
    expect(watch, findsOneWidget);
    expect(stop, findsNothing);
  });

  scenario('a widget that reads no state says so', (tester) async {
    await pumpApp(tester, home: const Center(child: Text('plain text')));
    await openState(tester, at: find.text('plain text'), type: 'Text');

    expect(inPanel('No state read here'), findsOneWidget);
    expect(inPanel('Nothing changed yet'), findsNothing);
  });

  scenario('an armed lens shows a static end time in the tab, and draws no '
      'frame on a timer', (tester) async {
    await pumpApp(tester);
    await openState(tester, at: screenText, type: 'ProductScreen');
    final lens = TraceSession.current!.stateLens;
    expect(lens.armed, isFalse);

    await armHere(tester);

    expect(lens.armed, isTrue);
    expect(lens.target, same(controller.selection.value!.element));
    final line = find.byKey(StateTab.watchingKey);
    expect(line, findsOneWidget);
    final first = tester.widget<Text>(line).data!;
    expect(first, matches(RegExp(r'^Watching until \d\d:\d\d:\d\d$')));
    expect(stop, findsOneWidget);
    expect(watch, findsNothing);
    expect(find.byKey(StateTab.chainKey), findsOneWidget);

    // Idle: no frame is scheduled and the line is the same ten seconds
    // later. The window runs 30 s, so it is still open.
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(lens.armed, isTrue);
    expect(tester.widget<Text>(line).data, first);
  });

  scenario('a notify shows its chain row, the code line and the coupling '
      'hint', (tester) async {
    final asked = <Uri>[];
    final fake = FakeBridge();
    BridgeClient.debugClient = MockClient((request) async {
      if (request.url.path != '/source') return fake.handle(request);
      asked.add(request.url);
      final line = int.parse(request.url.queryParameters['line']!);
      return http.Response(
        jsonEncode({
          'file': request.url.queryParameters['file'],
          'start': line - 3,
          'end': line,
          'text':
              'void fetchDialog() {\n'
              '  dialogLoading = true;\n'
              '  loading = true;\n'
              '  notifyListeners();',
        }),
        200,
      );
    });
    await pumpApp(
      tester,
      config: PinPointConfig(bridgeUrl: Uri.parse('http://127.0.0.1:4747')),
    );
    await openState(tester, at: screenText, type: 'ProductScreen');
    await armHere(tester);

    product.fetchDialog();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(StateTab.chainKey), findsOneWidget);
    expect(inPanel('Nothing changed yet'), findsNothing);
    expect(inPanel(RegExp(r'ProductModel #a\d+ notified')), findsOneWidget);
    expect(inPanel('fetchDialog()'), findsWidgets);
    // The location is behind the folder button, not printed in the row.
    expect(inPanel('test/support/fake_provider.dart'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(StateTab.chainKey),
        matching: find.byType(SourceLocationButton),
      ),
      findsWidgets,
    );
    // The rebuilt readers, with the object they read.
    expect(
      inPanel(RegExp(r'ProductScreen +reads ProductModel #a\d+')),
      findsOne,
    );
    expect(
      inPanel(RegExp(r'ProductAndCart +reads ProductModel #a\d+')),
      findsOne,
    );
    expect(inPanel('same object'), findsWidgets);
    // The code under the notify came from the bridge, once per line.
    expect(asked, isNotEmpty);
    expect(find.text('dialogLoading = true;'), findsWidgets);
    expect(find.text('notifyListeners();'), findsWidgets);
    final calls = asked.length;
    await tester.pump(const Duration(seconds: 1));
    expect(asked, hasLength(calls));
    // The hint is the lens's own line, set apart with the accent colour.
    expect(hints(), findsOneWidget);
    expect(
      find.descendant(of: hints(), matching: find.textContaining('shape 1')),
      findsOneWidget,
    );
  });

  scenario('with no bridge the chain shows no code and no error', (
    tester,
  ) async {
    await pumpApp(tester);
    await openState(tester, at: screenText, type: 'ProductScreen');
    await armHere(tester);

    product.fetchDialog();
    await tester.pump();
    await tester.pump();

    expect(inPanel(RegExp(r'ProductModel #a\d+ notified')), findsOneWidget);
    expect(find.text('notifyListeners();'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  scenario('a window with no change says nothing changed yet', (tester) async {
    await pumpApp(tester);
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(screenText));
    await tester.pump();
    final selection = controller.selection.value!;
    for (var i = 0; i < selection.chain.length; i++) {
      if (selection.chain[i].name == 'ProductScreen') {
        controller.selectChainIndex(i);
        break;
      }
    }
    await tester.pump();
    // Opened and closed before the tab exists: no event fell inside the
    // window (a test's own `setState` calls carry the test file in their
    // stack, so they would make events of their own).
    TraceSession.current!.stateLens
      ..arm(controller.selection.value!.element)
      ..stop();
    await tester.tap(find.byKey(InfoPanel.stateTabKey));
    await tester.pump();

    expect(inPanel('Nothing changed yet'), findsOneWidget);
    expect(find.byKey(StateTab.stoppedKey), findsOneWidget);
  });

  scenario('Stop closes the window and the tab says why', (tester) async {
    await pumpApp(tester);
    await openState(tester, at: screenText, type: 'ProductScreen');
    final lens = TraceSession.current!.stateLens;
    await armHere(tester);
    expect(lens.armed, isTrue);

    await tester.tap(stop);
    await tester.pump();

    expect(lens.armed, isFalse);
    expect(debugPrintScheduleBuildForStacks, isFalse);
    expect(find.byKey(StateTab.stoppedKey), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(StateTab.stoppedKey)).data,
      'Stopped: stopped',
    );
    expect(watch, findsOneWidget);
    expect(stop, findsNothing);
    // The chain of the window stays readable.
    expect(find.byKey(StateTab.chainKey), findsOneWidget);
  });

  scenario('the window ending on its own shows "Stopped: window ended"', (
    tester,
  ) async {
    await pumpApp(tester);
    await openState(tester, at: screenText, type: 'ProductScreen');
    await armHere(tester);

    await tester.pump(const Duration(seconds: 31));
    await tester.pump();

    expect(
      tester.widget<Text>(find.byKey(StateTab.stoppedKey)).data,
      'Stopped: window ended',
    );
  });

  // -- The folder button: the location of a row is behind it. ---------------

  Finder locationIcons(Key section) => find.descendant(
    of: find.byKey(section),
    matching: find.byType(SourceLocationButton),
  );

  final tip = find.text(SourceLocationButton.tipText);
  final popover = find.byKey(StateTab.locationPopoverKey);
  final copyButton = find.byKey(StateTab.locationCopyKey);

  /// Hovers [target] with a mouse. The gesture is removed with the test.
  Future<TestGesture> hover(WidgetTester tester, Finder target) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();
    return mouse;
  }

  /// Notifies once with the lens armed, so the chain has a located row.
  Future<void> openStateWithChain(WidgetTester tester) async {
    await pumpApp(tester);
    await openState(tester, at: screenText, type: 'ProductScreen');
    await armHere(tester);
    product.fetchDialog();
    await tester.pump();
    await tester.pump();
  }

  scenario('no row prints an absolute path, and each located row has a '
      'folder button', (tester) async {
    await openStateWithChain(tester);

    final panelRows = find.byKey(StateTab.readsKey);
    final chainRows = find.byKey(StateTab.chainKey);
    for (final section in [panelRows, chainRows]) {
      expect(
        find.descendant(of: section, matching: find.textContaining('/')),
        findsNothing,
        reason: 'a path or a line was printed',
      );
      expect(
        find.descendant(
          of: section,
          matching: find.textContaining(RegExp(r'\.dart')),
        ),
        findsNothing,
      );
    }
    // A reader row, a dependency row and a notify row have one each.
    expect(StateTab.locationKey('r0'), isNotNull);
    expect(find.byKey(StateTab.locationKey('r0')), findsOneWidget);
    expect(find.byKey(StateTab.locationKey('r0.d0')), findsOneWidget);
    expect(locationIcons(StateTab.readsKey), findsWidgets);
    expect(locationIcons(StateTab.chainKey), findsWidgets);
    final notify = find.descendant(
      of: chainRows,
      matching: find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> && key.value.endsWith('.n0');
      }),
    );
    expect(notify, findsOneWidget);
    // The rest of the row stays.
    expect(inPanel(RegExp(r'ProductModel #a\d+ notified')), findsOneWidget);
    expect(inPanel('fetchDialog()'), findsWidgets);
  });

  scenario('the tip shows after 2 s of hover, not after 1 s, and goes when '
      'the pointer leaves', (tester) async {
    await openStateWithChain(tester);
    final icon = find.byKey(StateTab.locationKey('r0'));

    final mouse = await hover(tester, icon);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tip, findsNothing);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tip, findsOneWidget);
    expect(popover, findsNothing);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tip, findsNothing);

    // Leaving before 2 s cancels the tip.
    await mouse.moveTo(tester.getCenter(icon));
    await tester.pump(const Duration(seconds: 1));
    await mouse.moveTo(const Offset(1, 1));
    await tester.pump(const Duration(seconds: 3));
    expect(tip, findsNothing);
    expect(tester.takeException(), isNull);
  });

  scenario('the tip shows at once with reduced motion once its 2 s are '
      'over', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await openStateWithChain(tester);
    await hover(tester, find.byKey(StateTab.locationKey('r0')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(tip, findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  scenario('a tap opens the popover with the short path and the line', (
    tester,
  ) async {
    await openStateWithChain(tester);
    expect(popover, findsNothing);

    await tester.tap(find.byKey(StateTab.locationKey('r0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(popover, findsOneWidget);
    final texts = [
      for (final t in tester.widgetList<Text>(
        find.descendant(of: popover, matching: find.byType(Text)),
      ))
        t.textSpan?.toPlainText() ?? t.data ?? '',
    ];
    final path = texts.firstWhere((t) => t.endsWith('.dart'));
    expect(path, startsWith('test/'));
    expect(path, isNot(contains('/Users/')));
    expect(texts.any((t) => RegExp(r'^LINE \d+$').hasMatch(t)), isTrue);
    expect(copyButton, findsOneWidget);
    // A second tap on the same icon is behind the barrier: only one popover.
    expect(tip, findsNothing);
  });

  scenario('Copy puts path:line on the clipboard, and toasts it', (
    tester,
  ) async {
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await openStateWithChain(tester);
    await tester.tap(find.byKey(StateTab.locationKey('r0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final line = tester
        .widgetList<Text>(
          find.descendant(of: popover, matching: find.byType(Text)),
        )
        .map((t) => t.data ?? '')
        .firstWhere((t) => t.startsWith('LINE '));

    await tester.tap(copyButton);
    await tester.pump();

    expect(copied, hasLength(1));
    expect(copied.single, matches(RegExp(r'^test/.+\.dart:\d+$')));
    expect(copied.single, endsWith(':${line.substring(5)}'));
    // The overlay's toast is wired in: the popover closes and the toast says
    // what was copied (the bare button, with no toast hook, says "Copied":
    // the next test).
    expect(popover, findsNothing);
    expect(find.text('Copied ${copied.single}'), findsOneWidget);
    await tester.pump(ToastController.lifetime);
  });

  scenario('with a toast hook, Copy reports it and closes the popover', (
    tester,
  ) async {
    final toasts = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async {
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (context) => Align(
                alignment: Alignment.topRight,
                child: SourceLocationButton(
                  key: StateTab.locationKey('x'),
                  path: 'lib/src/main.dart',
                  line: 12,
                  onToast: toasts.add,
                  popoverKey: StateTab.locationPopoverKey,
                  copyKey: StateTab.locationCopyKey,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byKey(StateTab.locationKey('x')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('lib/src/'), findsNothing);
    expect(popover, findsOneWidget);

    await tester.tap(copyButton);
    await tester.pump();
    await tester.pump();

    expect(toasts, ['Copied lib/src/main.dart:12']);
    expect(popover, findsNothing);
  });

  scenario('Esc and a click outside close the popover', (tester) async {
    await openStateWithChain(tester);
    final icon = find.byKey(StateTab.locationKey('r0'));

    await tester.tap(icon);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(popover, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(popover, findsNothing);

    await tester.tap(icon);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(popover, findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pump();
    expect(popover, findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('shortSourcePath cuts an absolute path from its lib/ directory', () {
    expect(
      shortSourcePath(
        '/Users/mac/Desktop/admin-genai-product/app/lib/src/features/'
        'plan_run/plan_run_screen.dart',
      ),
      'lib/src/features/plan_run/plan_run_screen.dart',
    );
    expect(
      shortSourcePath('/Users/me/app/test/a_test.dart'),
      'test/a_test.dart',
    );
    expect(shortSourcePath('C:/dev/app/lib/main.dart'), 'lib/main.dart');
    expect(shortSourcePath('lib/src/x.dart'), 'lib/src/x.dart');
    expect(shortSourcePath('/opt/other/x.dart'), '/opt/other/x.dart');
  });

  // -- The shared chain rows and the /source cache. -------------------------

  Map<String, Object?> chainOf(List<Map<String, Object?>> causes) => {
    'causes': causes,
    'events': causes.length,
  };

  Future<void> pumpChain(
    WidgetTester tester,
    Map<String, Object?> chain, {
    CodeLineCache? cache,
    BridgeClient? Function()? bridge,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StateChainView(
            chain: chain,
            cache: cache ?? CodeLineCache(),
            bridge: bridge,
          ),
        ),
      ),
    );
  }

  scenario('"No rebuilt reader seen" shows for a notify row only', (
    tester,
  ) async {
    final noReader = find.text('No rebuilt reader seen for it');
    Map<String, Object?> notify() => {
      'owner': 'CartModel',
      'tag': '#a1',
      'method': 'CartModel.add',
      'file': 'lib/cart.dart',
      'line': 10,
    };
    Map<String, Object?> setState() => {
      'widget': 'Counter',
      'method': '_CounterState.bump',
      'file': 'lib/counter.dart',
      'line': 20,
    };

    // A notify that no reader answered: the line stays.
    await pumpChain(
      tester,
      chainOf([
        {
          'cause': 1,
          'notifies': [notify()],
          'rebuilt': <Object?>[],
        },
      ]),
    );
    expect(noReader, findsOneWidget);

    // A cause that has only setStates: no line, whatever the rebuilt list.
    await pumpChain(
      tester,
      chainOf([
        {
          'cause': 2,
          'setStates': [setState()],
          'rebuilt': <Object?>[],
        },
        {
          'frame': 7,
          'setStates': [setState()],
        },
      ]),
    );
    expect(noReader, findsNothing);
    expect(find.textContaining('Counter'), findsWidgets);

    // A notify and a setState in one cause with nothing rebuilt: the notify
    // row earns the line.
    await pumpChain(
      tester,
      chainOf([
        {
          'cause': 3,
          'notifies': [notify()],
          'setStates': [setState()],
        },
      ]),
    );
    expect(noReader, findsOneWidget);
  });

  test(
    'askable refuses package, dart, engine, packages and non-dart files',
    () {
      for (final file in [
        'package:flutter/src/widgets/framework.dart',
        'dart:async',
        'dart:ui/window.dart',
        'lib/_engine/engine/platform_dispatcher.dart',
        'packages/flutter/src/x.dart',
        'lib/main.js',
        'lib/main',
        '',
      ]) {
        expect(CodeLineCache.askable(file), isFalse, reason: file);
      }
      for (final file in [
        'lib/src/cart.dart',
        'test/support/fake_provider.dart',
        '/Users/me/app/lib/main.dart',
      ]) {
        expect(CodeLineCache.askable(file), isTrue, reason: file);
      }
    },
  );

  scenario('/source is never asked for a skipped file, and a failed lookup is '
      'asked once for the session', (tester) async {
    final asked = <String>[];
    final fake = FakeBridge();
    BridgeClient.debugClient = MockClient((request) async {
      if (request.url.path != '/source') return fake.handle(request);
      final file = request.url.queryParameters['file']!;
      final line = request.url.queryParameters['line']!;
      asked.add('$file:$line');
      return http.Response('{"error":"no such file"}', 404);
    });
    final config = PinPointConfig(
      bridgeUrl: Uri.parse('http://127.0.0.1:4747'),
    );
    BridgeClient? bridge() =>
        BridgeClient.find(url: config.bridgeUrl, sinks: config.sinks);
    Map<String, Object?> row(String file, int line) => {
      'owner': 'M',
      'tag': '#a1',
      'method': 'M.go',
      'file': file,
      'line': line,
    };
    final skipped = [
      'package:flutter/src/foundation/change_notifier.dart',
      'dart:async',
      'lib/_engine/engine/platform_dispatcher.dart',
      'packages/flutter/src/x.dart',
      'lib/notes.txt',
    ];
    final chain = chainOf([
      {
        'cause': 1,
        'notifies': [
          for (var i = 0; i < skipped.length; i++) row(skipped[i], 10 + i),
          row('lib/missing.dart', 5),
        ],
        'rebuilt': <Object?>[],
      },
    ]);
    final cache = CodeLineCache();
    addTearDown(cache.dispose);

    await pumpChain(tester, chain, cache: cache, bridge: bridge);
    await tester.pump();
    await tester.pump();
    expect(asked, ['lib/missing.dart:5']);

    // Built again, and by a second view of the same session cache (the tab
    // and the card): the 404 is not asked again.
    await pumpChain(tester, chain, cache: cache, bridge: bridge);
    await tester.pump();
    await pumpChain(tester, chain, cache: cache, bridge: bridge);
    await pumpChain(tester, chain, cache: cache, bridge: bridge);
    await tester.pump(const Duration(seconds: 2));
    expect(asked, ['lib/missing.dart:5']);
    expect(cache.requests, 1);
    expect(tester.takeException(), isNull);
  });

  for (final palette in PinPointPalette.values) {
    scenario('works in the ${palette.name} palette', (tester) async {
      controller.palette.select(palette);
      await pumpApp(tester);
      await openState(tester, at: screenText, type: 'ProductScreen');
      await armHere(tester);
      product.fetchDialog();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(controller.palette.value, palette);
      expect(hints(), findsOneWidget);
      final context = tester.element(hints());
      final tokens = PinPointTokens.of(context);
      final box = tester.widget<Container>(hints());
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, tokens.accentBg);
      final text = tester.widget<Text>(
        find.descendant(of: hints(), matching: find.byType(Text)),
      );
      expect(text.style!.color, tokens.accentInk);

      // The folder button's tip and popover use the palette's paper and ink.
      final icon = find.byKey(StateTab.locationKey('r0'));
      final mouse = await hover(tester, icon);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 400));
      final tipBox = tester.widget<DecoratedBox>(
        find.byKey(StateTab.locationTipKey),
      );
      final tipDecoration = tipBox.decoration as BoxDecoration;
      expect(tipDecoration.color, tokens.paper);
      expect((tipDecoration.border! as Border).top.color, tokens.ink);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(icon);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final surface = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byKey(StateTab.locationPopoverKey),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final surfaceDecoration = surface.decoration as BoxDecoration;
      expect(surfaceDecoration.color, tokens.paper);
      expect((surfaceDecoration.border! as Border).top.color, tokens.ink);
      expect(tester.takeException(), isNull);
    });
  }
}

/// A reader above the screen: it reads the same product model.
class _Outer extends StatelessWidget {
  const _Outer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    watchFake<ProductModel>(context);
    return child;
  }
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';
import 'package:pinpoint/src/overlay/state_tab.dart';
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

  scenario('Watch state arms the lens, shows a static end time, and draws no '
      'frame on a timer', (tester) async {
    await pumpApp(tester);
    await openState(tester, at: screenText, type: 'ProductScreen');
    final lens = TraceSession.current!.stateLens;
    expect(lens.armed, isFalse);

    await tester.tap(watch);
    await tester.pump();

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
    await tester.tap(watch);
    await tester.pump();

    product.fetchDialog();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(StateTab.chainKey), findsOneWidget);
    expect(inPanel('Nothing changed yet'), findsNothing);
    expect(inPanel(RegExp(r'ProductModel #a\d+ notified')), findsOneWidget);
    expect(inPanel('fetchDialog()'), findsWidgets);
    expect(inPanel('test/support/fake_provider.dart:'), findsWidgets);
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
    await tester.tap(watch);
    await tester.pump();

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
    await tester.tap(watch);
    await tester.pump();
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
    await tester.tap(watch);
    await tester.pump();

    await tester.pump(const Duration(seconds: 31));
    await tester.pump();

    expect(
      tester.widget<Text>(find.byKey(StateTab.stoppedKey)).data,
      'Stopped: window ended',
    );
  });

  for (final palette in PinPointPalette.values) {
    scenario('works in the ${palette.name} palette', (tester) async {
      controller.palette.select(palette);
      await pumpApp(tester);
      await openState(tester, at: screenText, type: 'ProductScreen');
      await tester.tap(watch);
      await tester.pump();
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

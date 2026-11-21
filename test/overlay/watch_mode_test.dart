import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/info_panel.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/overlay/source_location_button.dart';
import 'package:pinpoint/src/overlay/state_tab.dart';
import 'package:pinpoint/src/overlay/story_view.dart';
import 'package:pinpoint/src/overlay/toast_layer.dart';
import 'package:pinpoint/src/overlay/watch_card.dart';
import 'package:pinpoint/src/sink/bridge_client.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/fake_bridge.dart';
import '../support/fake_provider.dart';
import '../support/trace_host.dart';

/// PLAN-v3 Milestone 21: watch mode of the state lens. "Watch state" leaves
/// picking, so the app gets its events, and opens a marker and a card that
/// list the changes as they happen.
void main() {
  late PinPointController controller;
  late ProductModel product;
  late ValueNotifier<bool> showScreen;
  late int taps;

  const DebugPrintCallback initialPrint = debugPrintSynchronously;

  setUp(() {
    controller = PinPointController();
    product = ProductModel();
    showScreen = ValueNotifier<bool>(true);
    taps = 0;
  });
  tearDown(() {
    controller.dispose();
    showScreen.dispose();
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

  final tapButton = find.widgetWithText(ElevatedButton, 'tap');
  final notifyButton = find.widgetWithText(ElevatedButton, 'notify');
  final screenText = find.textContaining('screen ');
  final card = find.byKey(WatchCard.cardKey);
  final panel = find.byKey(InfoPanel.panelKey);
  final markerLayer = find.byKey(InspectorOverlay.watchMarkerKey);

  Future<void> pumpApp(
    WidgetTester tester, {
    PinPointConfig config = const PinPointConfig(),
  }) async {
    await tester.pumpWidget(
      traceApp(
        controller: controller,
        config: config,
        home: Scaffold(
          body: FakeScope<ProductModel>(
            model: product,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: showScreen,
                  builder: (context, show, _) =>
                      show ? const ProductScreen() : const SizedBox.shrink(),
                ),
                ElevatedButton(
                  onPressed: () => taps++,
                  child: const Text('tap'),
                ),
                ElevatedButton(
                  onPressed: product.fetchDialog,
                  child: const Text('notify'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Picks the screen's text, selects the `ProductScreen` crumb and opens
  /// the State tab.
  Future<void> openState(WidgetTester tester) async {
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
    await tester.tap(find.byKey(InfoPanel.stateTabKey));
    await tester.pump();
  }

  /// "Watch state" from picking, and the frames of the card's opening.
  Future<void> watchScreen(WidgetTester tester) async {
    await openState(tester);
    await tester.tap(find.byKey(StateTab.watchKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// A notify from the app's own button, then the frames that join it.
  Future<void> notifyInApp(WidgetTester tester) async {
    await tester.tap(notifyButton);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Finder inCard(Pattern text) =>
      find.descendant(of: card, matching: find.textContaining(text));

  String text(WidgetTester tester, Key key) =>
      tester.widget<Text>(find.byKey(key)).data!;

  scenario('Watch leaves picking, closes the panel and the app gets its '
      'taps', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);

    final lens = TraceSession.current!.stateLens;
    expect(lens.armed, isTrue);
    expect(controller.mode, PinPointMode.idle);
    expect(controller.selection.value, isNull);
    expect(panel, findsNothing);
    expect(card, findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(WatchCard.titleKey))
          .textSpan!
          .toPlainText(),
      'WATCHING ProductScreen',
    );
    expect(
      text(tester, WatchCard.statusKey),
      matches(RegExp(r'^until \d\d:\d\d:\d\d$')),
    );
    expect(find.byKey(WatchCard.stopKey), findsOneWidget);

    // The app's own button works: nothing of Pinpoint's covers it.
    await tester.tap(tapButton);
    await tester.pump();
    expect(taps, 1);
    await tester.tap(tapButton);
    await tester.pump();
    expect(taps, 2);
    expect(controller.mode, PinPointMode.idle);
  });

  scenario('the card shows the notify row after the app notifies', (
    tester,
  ) async {
    await pumpApp(tester);
    await watchScreen(tester);

    await notifyInApp(tester);

    expect(inCard('Nothing changed yet'), findsNothing);
    expect(inCard(RegExp(r'^ProductModel')), findsOneWidget);
    // The identity tag is for grouping: the card never shows it.
    expect(inCard(RegExp(r'#a\d+')), findsNothing);
    expect(inCard('fetchDialog()'), findsWidgets);
    expect(
      find.descendant(of: card, matching: find.byType(SourceLocationButton)),
      findsWidgets,
    );
    // A second notify is a second block, below the first (oldest on top).
    await notifyInApp(tester);
    final rows = find.descendant(
      of: card,
      matching: find.textContaining(RegExp(r'^ProductModel')),
    );
    expect(rows, findsNWidgets(2));
    expect(
      tester.getTopLeft(rows.first).dy,
      lessThan(tester.getTopLeft(rows.last).dy),
    );
  });

  scenario('dragging the header moves the card, and it stays in the '
      'viewport', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);
    final viewport = tester.getSize(find.byType(MaterialApp));
    final start = tester.getRect(card);
    expect(start.width, WatchCard.width);
    expect(start.height, lessThanOrEqualTo(viewport.height * 0.45 + 0.01));
    final grab =
        tester.getTopLeft(find.byKey(WatchCard.headerKey)) +
        const Offset(10, 8);

    await tester.dragFrom(grab, const Offset(-120, -60));
    await tester.pump();
    final moved = tester.getRect(card);
    expect(moved.left, closeTo(start.left - 120, 0.01));
    expect(moved.top, closeTo(start.top - 60, 0.01));

    // Far past the corner: it stops at the margins.
    await tester.dragFrom(
      tester.getTopLeft(find.byKey(WatchCard.headerKey)) + const Offset(10, 8),
      const Offset(-5000, -5000),
    );
    await tester.pump();
    final corner = tester.getRect(card);
    expect(corner.left, panelMarginX);
    expect(corner.top, panelMarginY);

    await tester.dragFrom(
      tester.getTopLeft(find.byKey(WatchCard.headerKey)) + const Offset(10, 8),
      const Offset(9000, 9000),
    );
    await tester.pump();
    final far = tester.getRect(card);
    expect(far.right, lessThanOrEqualTo(viewport.width - panelMarginX));
    expect(far.bottom, lessThanOrEqualTo(viewport.height - panelMarginY));
    expect(far.left, greaterThan(corner.left));

    // The place is kept for the session: close and watch again.
    final kept = controller.watch.cardPosition;
    expect(kept, isNotNull);
    controller.watch.close();
    await tester.pump();
    expect(card, findsNothing);
    await watchScreen(tester);
    expect(tester.getRect(card).topLeft, far.topLeft);
  });

  scenario('Esc stops the lens, Esc again closes the card', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);
    final lens = TraceSession.current!.stateLens;
    await notifyInApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(lens.armed, isFalse);
    expect(card, findsOneWidget);
    expect(text(tester, WatchCard.statusKey), 'Stopped: stopped');
    expect(find.byKey(WatchCard.againKey), findsOneWidget);
    expect(find.byKey(WatchCard.stopKey), findsNothing);
    // The chain of the window stays readable.
    expect(inCard(RegExp(r'^ProductModel')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(card, findsNothing);
    expect(controller.watch.open, isFalse);
    expect(controller.mode, PinPointMode.idle);
  });

  scenario('Stop, the window ending, and Close', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);
    final lens = TraceSession.current!.stateLens;

    await tester.tap(find.byKey(WatchCard.stopKey));
    await tester.pump();
    expect(lens.armed, isFalse);
    expect(text(tester, WatchCard.statusKey), 'Stopped: stopped');

    await tester.tap(find.byKey(WatchCard.againKey));
    await tester.pump();
    expect(lens.armed, isTrue);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(text(tester, WatchCard.statusKey), 'Stopped: window ended');

    await tester.tap(find.byKey(WatchCard.closeKey));
    await tester.pump();
    expect(card, findsNothing);
  });

  scenario('Watch again re-arms the same target', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);
    final lens = TraceSession.current!.stateLens;
    final target = lens.target;
    await notifyInApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(lens.armed, isFalse);

    await tester.tap(find.byKey(WatchCard.againKey));
    await tester.pump();

    expect(lens.armed, isTrue);
    expect(lens.target, same(target));
    expect(
      text(tester, WatchCard.statusKey),
      matches(RegExp(r'^until \d\d:\d\d:\d\d$')),
    );
    expect(find.byKey(WatchCard.stopKey), findsOneWidget);
    // A new window starts with an empty chain.
    expect(inCard('Nothing changed yet'), findsOneWidget);
    await notifyInApp(tester);
    expect(inCard(RegExp(r'^ProductModel')), findsOneWidget);
  });

  scenario('picking again keeps the lens running and the card open', (
    tester,
  ) async {
    await pumpApp(tester);
    await watchScreen(tester);

    controller.startPicking();
    await tester.pump();
    expect(controller.mode, PinPointMode.picking);
    expect(TraceSession.current!.stateLens.armed, isTrue);
    expect(card, findsOneWidget);

    // Esc leaves picking; the card and the lens stay.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.mode, PinPointMode.idle);
    expect(TraceSession.current!.stateLens.armed, isTrue);
    expect(card, findsOneWidget);
  });

  scenario('the marker sits on the target and hides when it unmounts', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(markerLayer, findsOneWidget);
    expect(controller.watch.markerRect.value, isNull);
    await watchScreen(tester);

    final rect = tester.getRect(find.byType(ProductScreen));
    expect(controller.watch.markerRect.value, rect);
    final tokens = PinPointTokens.of(tester.element(markerLayer));
    final object = tester.renderObject<RenderBox>(markerLayer);
    expect(
      object,
      paints
        ..path(color: tokens.paper)
        ..path(color: tokens.accent)
        ..rect(color: tokens.accent),
    );
    // The tag's words are painted too.
    expect(tester.widgetList<CustomPaint>(markerLayer), isNotEmpty);

    showScreen.value = false;
    await tester.pump();
    await tester.pump();
    expect(controller.watch.markerRect.value, isNull);
    expect(object, isNot(paints..path(color: tokens.paper)));
    // The card stays; "Watch again" is off while there is no target.
    expect(card, findsOneWidget);
  });

  scenario('the marker goes with the window', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);
    expect(controller.watch.markerRect.value, isNotNull);

    await tester.tap(find.byKey(WatchCard.stopKey));
    await tester.pump();
    expect(controller.watch.markerRect.value, isNull);
  });

  scenario('no frame is scheduled while watching and idle', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);
    await notifyInApp(tester);

    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.binding.hasScheduledFrame, isFalse);
    final lens = TraceSession.current!.stateLens;
    expect(lens.armed, isTrue);
    // The end time did not move.
    final shown = text(tester, WatchCard.statusKey);
    await tester.pump(const Duration(seconds: 5));
    expect(text(tester, WatchCard.statusKey), shown);
  });

  scenario('a lens the agent armed opens no card and no marker', (
    tester,
  ) async {
    await pumpApp(tester);
    final answer = await toolResult(tester, controller, 'state_flow', {
      'target': {'type': 'ProductScreen'},
    });
    expect(answer['armed'], isTrue);
    expect(TraceSession.current!.stateLens.armed, isTrue);

    await notifyInApp(tester);
    await tester.pumpAndSettle();

    expect(controller.watch.open, isFalse);
    expect(card, findsNothing);
    expect(controller.watch.markerRect.value, isNull);
    expect(
      tester.renderObject<RenderBox>(markerLayer),
      isNot(paints..path(color: PinPointTokens.redline.paper)),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  scenario('the agent moving the lens ends the user\'s watch in the card', (
    tester,
  ) async {
    await pumpApp(tester);
    await watchScreen(tester);

    await toolResult(tester, controller, 'state_flow', {
      'target': {'type': 'ElevatedButton'},
      'rearm': true,
    });
    await tester.pump();

    expect(card, findsOneWidget);
    expect(text(tester, WatchCard.statusKey), 'Stopped: re-targeted');
    expect(controller.watch.markerRect.value, isNull);
  });

  scenario('Copy in the card calls the toast', (tester) async {
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
    await pumpApp(tester);
    await watchScreen(tester);
    await notifyInApp(tester);

    final where = find.descendant(
      of: card,
      matching: find.byType(SourceLocationButton),
    );
    // The card follows the bottom, so the newest row is the one in view.
    await tester.tap(where.last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(StateTab.locationCopyKey));
    await tester.pump();
    await tester.pump();

    expect(copied, hasLength(1));
    expect(find.text('Copied ${copied.single}'), findsOneWidget);
    expect(find.byKey(StateTab.locationPopoverKey), findsNothing);
    await tester.pump(ToastController.lifetime);
  });

  scenario('a failed /source lookup is asked once for the session', (
    tester,
  ) async {
    final asked = <String>[];
    final fake = FakeBridge();
    BridgeClient.debugClient = MockClient((request) async {
      if (request.url.path != '/source') return fake.handle(request);
      asked.add(
        '${request.url.queryParameters['file']}:'
        '${request.url.queryParameters['line']}',
      );
      return http.Response(jsonEncode({'error': 'no such file'}), 404);
    });
    await pumpApp(
      tester,
      config: PinPointConfig(bridgeUrl: Uri.parse('http://127.0.0.1:4747')),
    );
    await watchScreen(tester);

    await notifyInApp(tester);
    await notifyInApp(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(asked, isNotEmpty);
    expect(asked.toSet(), hasLength(asked.length), reason: '$asked');
    final calls = asked.length;

    // Watch again, notify again, then the State tab of a new pick: the
    // same lines are not asked again.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tap(find.byKey(WatchCard.againKey));
    await tester.pump();
    await notifyInApp(tester);
    expect(asked, hasLength(calls));
    expect(inCard(RegExp(r'^ProductModel')), findsOneWidget);
    expect(find.textContaining('notifyListeners'), findsNothing);
  });

  scenario('the card follows the bottom of the story; scrolled up it says '
      '"N new ↓" and does not move', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);
    for (var i = 0; i < 6; i++) {
      await notifyInApp(tester);
    }
    final scrollable = find.descendant(
      of: find.byKey(WatchCard.bodyKey),
      matching: find.byType(Scrollable),
    );
    ScrollPosition position() =>
        tester.state<ScrollableState>(scrollable).position;
    expect(position().maxScrollExtent, greaterThan(0));
    // At the bottom, and newer rows are in view.
    expect(position().extentAfter, lessThan(24));
    expect(find.byKey(WatchCard.newKey), findsNothing);

    // The user reads older blocks: the card stays where it is.
    await tester.drag(scrollable, const Offset(0, 400));
    await tester.pump();
    final reading = position().pixels;
    expect(position().extentAfter, greaterThan(24));
    await notifyInApp(tester);
    await tester.pump();
    expect(position().pixels, reading);
    expect(find.byKey(WatchCard.newKey), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(WatchCard.newKey),
              matching: find.byType(Text),
            ),
          )
          .data,
      matches(RegExp(r'^\d+ new ↓$')),
    );

    await tester.tap(find.byKey(WatchCard.newKey));
    await tester.pump();
    expect(position().extentAfter, lessThan(24));
    expect(find.byKey(WatchCard.newKey), findsNothing);
  });

  scenario('a hot reload goes on: the card says so and the lens stays '
      'armed', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);
    await notifyInApp(tester);

    // What a hot reload does to each element, without its slow wait.
    // What the wrapper's `reassemble` calls (a real `Element.reassemble`
    // of the whole tree takes seconds in a test).
    TraceSession.current!.stateLens.noteReassemble();
    await tester.pump();
    await tester.pump();

    expect(TraceSession.current!.stateLens.armed, isTrue);
    expect(inCard('hot reload'), findsOneWidget);
    await notifyInApp(tester);
    expect(inCard(RegExp(r'^ProductModel')), findsWidgets);
  });

  scenario('the filters live in the card: hidden changes are counted and '
      '"Only my state" is a check box', (tester) async {
    await pumpApp(tester);
    await watchScreen(tester);
    await notifyInApp(tester);

    expect(find.byKey(StoryKeys.onlyMine), findsOneWidget);
    await tester.tap(find.byKey(StoryKeys.onlyMine));
    await tester.pump();
    // The app's own model is the project's state: still there.
    expect(inCard(RegExp(r'^ProductModel')), findsWidgets);
  });

  for (final palette in PinPointPalette.values) {
    scenario('the card works in the ${palette.name} palette', (tester) async {
      controller.palette.select(palette);
      await pumpApp(tester);
      await watchScreen(tester);
      await notifyInApp(tester);

      expect(tester.takeException(), isNull);
      final tokens = PinPointTokens.of(tester.element(card));
      final surface = tester.widget<DecoratedBox>(
        find.descendant(of: card, matching: find.byType(DecoratedBox)).first,
      );
      final decoration = surface.decoration as BoxDecoration;
      expect(decoration.color, tokens.paper);
      expect((decoration.border! as Border).top.color, tokens.ink);
      final title =
          tester.widget<Text>(find.byKey(WatchCard.titleKey)).textSpan!
              as TextSpan;
      expect(title.children!.first.style!.color, tokens.accentInk);
      // The coupling hint is set apart with the accent colour.
      final hint = find.descendant(
        of: card,
        matching: find.byWidgetPredicate((w) {
          final key = w.key;
          return key is ValueKey<String> && key.value.endsWith('.hint');
        }),
      );
      expect(hint, findsWidgets);
      final box =
          tester.widget<Container>(hint.first).decoration! as BoxDecoration;
      expect(box.color, tokens.accentBg);

      // The marker takes its colour from the palette too.
      expect(
        tester.renderObject<RenderBox>(markerLayer),
        paints
          ..path(color: tokens.paper)
          ..path(color: tokens.accent),
      );
    });
  }

  scenario('with reduced motion the card opens at once', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpApp(tester);
    await openState(tester);
    await tester.tap(find.byKey(StateTab.watchKey));
    await tester.pump();

    expect(card, findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find.descendant(of: card, matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 1);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });
}

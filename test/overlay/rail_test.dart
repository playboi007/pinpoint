import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/overlay/agent_layer.dart';
import 'package:pinpoint/src/overlay/environment_panel.dart';
import 'package:pinpoint/src/overlay/findings_panel.dart';
import 'package:pinpoint/src/overlay/rail.dart';
import 'package:pinpoint/src/overlay/theme_menu.dart';
import 'package:pinpoint/src/overlay/toolbar.dart';
import 'package:pinpoint/src/theme/controls.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

/// The right-edge rail: its items, where it sits, and where the panels open.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Future<void> pumpHost(
    WidgetTester tester, {
    PinPointConfig config = const PinPointConfig(allowAgentControl: true),
    Size size = const Size(1200, 900),
    Widget home = const Scaffold(body: Center(child: Text('app'))),
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => PinPointWrapper(
          controller: controller,
          config: config,
          child: child,
        ),
        home: home,
      ),
    );
  }

  final rail = find.byKey(RailLayer.railKey);

  testWidgets('shows in idle: What-if, Findings, agent, Theme, then the '
      'launcher', (tester) async {
    await pumpHost(tester);
    expect(controller.isActive, isFalse);
    final items = [
      EnvironmentBar.toggleKey,
      FindingsPanel.buttonKey,
      AgentLayer.toggleKey,
      ThemeMenu.buttonKey,
    ];
    var lastBottom = tester.getRect(rail).top;
    for (final key in items) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.size, const Size(40, 40), reason: '$key');
      expect(rect.top, greaterThan(lastBottom - 1), reason: 'in order');
      lastBottom = rect.bottom;
    }
    final launcher = tester.getRect(find.byType(PinPointLauncher));
    expect(launcher.top, greaterThan(lastBottom), reason: 'after an ink rule');
    expect(launcher.size, const Size(40, 44));
    expect(
      tester.getRect(rail).width,
      40 + 2,
      reason: 'items plus the 1 px border on each side',
    );
  });

  testWidgets('has no agent item unless agent control is allowed', (
    tester,
  ) async {
    await pumpHost(
      tester,
      config: const PinPointConfig(allowAgentControl: false),
    );
    expect(find.byKey(AgentLayer.toggleKey), findsNothing);
    expect(find.byKey(ThemeMenu.buttonKey), findsOneWidget);
  });

  testWidgets('sits 8 px from the right edge, centred, and takes pointer '
      'events only on itself', (tester) async {
    var taps = 0;
    await pumpHost(
      tester,
      home: Scaffold(
        body: Center(
          child: TextButton(onPressed: () => taps++, child: const Text('go')),
        ),
      ),
    );
    final rect = tester.getRect(rail);
    expect(rect.right, 1200 - 8);
    expect(rect.center.dy, closeTo(450, 0.5));

    // Beside the rail, in idle, the app gets the tap.
    await tester.tap(find.text('go'));
    expect(taps, 1);
    await tester.tapAt(rect.centerLeft - const Offset(20, 0));
    expect(taps, 1);
  });

  testWidgets('What-if opens the panel beside the rail, starting picking '
      'from idle', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.byKey(EnvironmentBar.toggleKey));
    await tester.pump();
    expect(controller.mode, PinPointMode.picking);
    final panel = tester.getRect(find.byKey(EnvironmentPanel.panelKey));
    final railRect = tester.getRect(rail);
    expect(panel.width, 360);
    expect(panel.right, railRect.left - 8, reason: 'left of the rail');
    expect(panel.top, greaterThanOrEqualTo(12));
    expect(panel.bottom, lessThanOrEqualTo(900 - 12));

    // The item shows it is open, and a second tap closes the panel.
    await tester.tap(find.byKey(EnvironmentBar.toggleKey));
    await tester.pump();
    expect(find.byKey(EnvironmentPanel.panelKey), findsNothing);
  });

  testWidgets('Findings opens beside the rail, with a count badge once '
      'there are findings', (tester) async {
    await pumpHost(tester);
    controller.startPicking();
    await tester.pump();
    controller.findings.addCaptured([
      const Finding(
        kind: 'exception',
        severity: Severity.error,
        summary: 'Uncaught StateError: late',
      ),
    ]);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(FindingsPanel.buttonKey),
        matching: find.byType(CountBadge),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(FindingsPanel.buttonKey));
    await tester.pump();
    final panel = tester.getRect(find.byKey(FindingsPanel.panelKey));
    expect(panel.right, tester.getRect(rail).left - 8);
    expect(find.byType(SeverityBadge), findsOneWidget);
    expect(find.text('ERROR'), findsOneWidget);
  });

  testWidgets('a panel is 16 px narrower than a 360 px viewport and keeps '
      'its margin', (tester) async {
    await pumpHost(tester, size: const Size(360, 640));
    await tester.tap(find.byKey(EnvironmentBar.toggleKey));
    await tester.pump();
    final panel = tester.getRect(find.byKey(EnvironmentPanel.panelKey));
    expect(panel.width, 344);
    expect(panel.left, 8);
    expect(panel.right, 352);
    expect(panel.height, lessThanOrEqualTo(640 - 24));
  });

  testWidgets('the agent item turns control on and off', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.byKey(AgentLayer.toggleKey));
    await tester.pump();
    expect(controller.agent.enabled, isTrue);
    expect(find.text('AGENT CONTROL ON · ESC STOPS'), findsOneWidget);
    await tester.tap(find.byKey(AgentLayer.toggleKey));
    await tester.pump();
    expect(controller.agent.enabled, isFalse);
  });

  testWidgets('drags along the edge, and the panel follows', (tester) async {
    await pumpHost(tester);
    // The findings list is short, so it can move.
    await tester.tap(find.byKey(FindingsPanel.buttonKey));
    await tester.pump();
    final start = tester.getRect(rail);
    final panelStart = tester.getRect(find.byKey(FindingsPanel.panelKey));

    await tester.drag(find.byKey(ThemeMenu.buttonKey), const Offset(-300, 120));
    await tester.pump();
    final moved = tester.getRect(rail);
    expect(moved.left, start.left, reason: 'never off the edge');
    expect(moved.top, start.top + 120);
    expect(
      tester.getRect(find.byKey(FindingsPanel.panelKey)).top,
      greaterThan(panelStart.top),
    );
    expect(controller.mode, PinPointMode.picking, reason: 'a drag is no tap');
  });

  testWidgets('the launcher starts and stops picking, and shows the '
      'frozen mark', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.byType(PinPointLauncher));
    await tester.pump();
    expect(controller.mode, PinPointMode.picking);
    controller.toggleFreeze();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(PinPointLauncher),
        matching: find.byIcon(PinPointIcons.acUnit),
      ),
      findsOneWidget,
    );
    expect(find.text('FROZEN'), findsOneWidget);
    await tester.tap(find.byType(PinPointLauncher));
    await tester.pump();
    expect(controller.mode, PinPointMode.idle);
  });
}

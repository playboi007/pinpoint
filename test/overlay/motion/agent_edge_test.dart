import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/agent/agent_control.dart';
import 'package:pinpoint/src/overlay/agent_layer.dart';

/// Moment 8: when agent control turns on, a dashed accent line draws itself
/// once around the screen edge (500 ms) and stays still; when it turns off
/// the line pulls back. The "AGENT CONTROL ON" chip stays.
void main() {
  late AgentControl agent;

  setUp(() => agent = AgentControl());
  tearDown(() => agent.dispose());

  Future<void> pump(WidgetTester tester, {bool reduced = false}) =>
      tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(800, 600),
              disableAnimations: reduced,
            ),
            child: SizedBox.expand(
              child: AgentLayer(agent: agent, origin: () => Offset.zero),
            ),
          ),
        ),
      );

  RenderBox edge(WidgetTester tester) =>
      tester.renderObject<RenderBox>(find.byKey(AgentLayer.edgeKey));

  PaintPattern twoPaths() => paints
    ..path()
    ..path();

  testWidgets('at rest, off, it paints and runs nothing', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(edge(tester), paintsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('turning control on draws the line around the edge in 500 ms, '
      'then it stays still', (tester) async {
    await pump(tester);
    agent.enabled = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    expect(edge(tester), twoPaths(), reason: 'halo and dashes, partly drawn');

    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.hasRunningAnimations, isTrue, reason: '450 ms: not yet');
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isFalse, reason: 'drawn by 500 ms');

    // It stays while control is on, and nothing moves.
    expect(edge(tester), twoPaths());
    await tester.pump(const Duration(seconds: 5));
    expect(edge(tester), twoPaths());
    expect(tester.binding.hasScheduledFrame, isFalse);
    // The chip is still there.
    expect(find.byKey(AgentLayer.bannerKey), findsOneWidget);
    expect(find.text('AGENT CONTROL ON · ESC STOPS'), findsOneWidget);
  });

  testWidgets('turning it off pulls the line back, and it ends', (
    tester,
  ) async {
    await pump(tester);
    agent.enabled = true;
    await tester.pumpAndSettle();
    expect(edge(tester), twoPaths());

    agent.enabled = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    expect(edge(tester), twoPaths(), reason: 'still partly there');
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(edge(tester), paintsNothing);
    expect(find.byKey(AgentLayer.bannerKey), findsNothing);
  });

  testWidgets('already on when the layer starts: the line is just there', (
    tester,
  ) async {
    agent.enabled = true;
    await pump(tester);
    expect(tester.hasRunningAnimations, isFalse);
    expect(edge(tester), twoPaths());
  });

  testWidgets('reduced motion: the line is there or not, at once', (
    tester,
  ) async {
    await pump(tester, reduced: true);
    agent.enabled = true;
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(edge(tester), twoPaths());

    agent.enabled = false;
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(edge(tester), paintsNothing);
  });

  testWidgets('it takes no pointer events', (tester) async {
    await pump(tester);
    final ignore = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byKey(AgentLayer.edgeKey),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(ignore.ignoring, isTrue);
  });
}

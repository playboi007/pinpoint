import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/detect/error_capture.dart';
import 'package:pinpoint/src/overlay/theme_menu.dart';
import 'package:pinpoint/src/trace/sources/pointer_source.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/markers.dart';
import '../support/trace_host.dart';

const String _file = 'test/trace/trace_sources_test.dart';

/// PLAN-v2 Milestone 13, build step 3: the pointer, key, text, route, error
/// and finding sources (all level 1).
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      traceApp(
        controller: controller,
        home: const _Screen(),
        routes: {'/next': (_) => const Scaffold(body: Text('next'))},
      ),
    );
    await tester.pump();
  }

  List<TraceEvent> events(String kind) => [
    for (final e in recorder.events)
      if (e.kind == kind) e,
  ];

  testWidgets('acceptance: with trace_detail on, a tap on the counter gives '
      'input.pointer, then build for the counter, in the same or the next '
      'frame', (tester) async {
    await pumpApp(tester);
    await toolResult(tester, controller, 'trace_detail', {'on': true});
    final from = recorder.nextSeq;
    await tester.tap(find.text('+'));
    await tester.pump();
    final after = [
      for (final e in recorder.events)
        if (e.seq >= from && e.kind != TraceKind.frame) e,
    ];
    final down = after.firstWhere(
      (e) => e.kind == TraceKind.pointer && e.data['phase'] == 'down',
    );
    final up = after.firstWhere(
      (e) => e.kind == TraceKind.pointer && e.data['phase'] == 'up',
    );
    final build = after.firstWhere(
      (e) => e.kind == TraceKind.build && e.widget == '_Screen',
    );
    expect(down.seq, lessThan(up.seq));
    expect(up.seq, lessThan(build.seq));
    expect(build.frame - down.frame, inInclusiveRange(0, 1));
    await toolResult(tester, controller, 'trace_detail', {'on': false});
  });

  testWidgets('acceptance: input.pointer carries the anchor of the widget '
      'under it, and the position inside it as a fraction', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('+'));
    // The anchor's ordinal is filled after the event, from a timer.
    await tester.pump(Duration.zero);
    final down = events(TraceKind.pointer)
        .firstWhere((e) => e.data['phase'] == 'down');
    final line = markerLine(_file, 'plus');
    expect(down.widget, 'Text');
    expect(down.source, contains('$_file:$line:'));
    final anchor = down.data['anchor']! as Map<String, Object?>;
    expect(anchor['file'], endsWith(_file));
    expect(anchor['line'], line);
    expect(anchor['widget'], 'Text');
    expect(anchor['ordinal'], 0);
    // tester.tap hits the center.
    expect(down.data['fx'], closeTo(0.5, 0.01));
    expect(down.data['fy'], closeTo(0.5, 0.01));
  });

  testWidgets('acceptance: a password field\'s input.text is masked, and so '
      'are the keys typed into it', (tester) async {
    await pumpApp(tester);
    await tester.showKeyboard(find.byKey(const ValueKey('password')));
    await tester.pump();
    tester.testTextInput.enterText('hunter2');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    final text = events(TraceKind.text).last;
    expect(text.data['value'], '[masked]');
    expect(text.data['length'], 7);
    expect(text.widget, 'TextField');
    final key = events(TraceKind.key).last;
    expect(key.data['key'], '[masked]');
    expect(key.data.containsKey('char'), isFalse);
    expect(
      recorder.events.map((e) => e.toJsonLine()).join(),
      isNot(contains('hunter2')),
    );

    await tester.showKeyboard(find.byKey(const ValueKey('name')));
    await tester.pump();
    tester.testTextInput.enterText('Ada');
    await tester.pump();
    expect(events(TraceKind.text).last.data['value'], 'Ada');
  });

  testWidgets('acceptance: an idle app records nothing: 5 seconds with no '
      'input adds zero events', (tester) async {
    await pumpApp(tester);
    await tester.pump(const Duration(seconds: 1));
    final before = recorder.nextSeq;
    await tester.binding.delayed(const Duration(seconds: 5));
    expect(recorder.nextSeq, before);
    // Nothing waits to draw a frame either (engineering rule 2).
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('acceptance: disposing the wrapper restores every slot the '
      'sources took', (tester) async {
    final onError = FlutterError.onError;
    await pumpApp(tester);
    await toolResult(tester, controller, 'trace_detail', {'on': true});
    expect(PointerSource.debugInstalled, 1);
    expect(ErrorCapture.listeners, hasLength(1));
    expect(debugOnRebuildDirtyWidget, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(TraceSession.current, isNull);
    expect(PointerSource.debugInstalled, 0);
    expect(ErrorCapture.listeners, isEmpty);
    expect(debugOnRebuildDirtyWidget, isNull);
    expect(FlutterError.onError, same(onError));
  });

  testWidgets('watch out for: pointer moves come hundreds a second; at most '
      'one per 16 ms is recorded, and only while a pointer is down', (
    tester,
  ) async {
    await pumpApp(tester);
    final from = recorder.nextSeq;
    // Over a part of the app that does not react: no frame is drawn, so
    // the events' own time stamps set the limit.
    final gesture = await tester.startGesture(const Offset(600, 500));
    // Thirty moves 1 ms apart, then thirty more 40 ms later.
    var stamp = Duration.zero;
    for (var batch = 0; batch < 2; batch++) {
      for (var i = 0; i < 30; i++) {
        stamp += const Duration(milliseconds: 1);
        await gesture.moveBy(const Offset(0, 2), timeStamp: stamp);
      }
      stamp += const Duration(milliseconds: 40);
    }
    await gesture.up(timeStamp: stamp);
    await tester.pump();
    final moves = [
      for (final e in recorder.events)
        if (e.seq >= from &&
            e.kind == TraceKind.pointer &&
            e.data['phase'] == 'move')
          e,
    ];
    // 30 ms per batch: two moves each (at 1 ms and 17 ms).
    expect(moves, hasLength(4));
    // A mouse moving with no button down: hover, not recorded.
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: const Offset(100, 100));
    await hover.moveTo(const Offset(120, 140));
    await tester.pump();
    await hover.removePointer();
    expect(
      recorder.events.where(
        (e) => e.seq > moves.last.seq && e.data['phase'] == 'move',
      ),
      isEmpty,
    );
  });

  testWidgets('Pinpoint never records itself: a tap on the rail and the '
      'picking trap are left out (rule 14)', (tester) async {
    await pumpApp(tester);
    final from = recorder.nextSeq;
    await tester.tap(find.byKey(ThemeMenu.buttonKey));
    await tester.pump();
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(const Offset(40, 300));
    await tester.pump();
    expect(
      recorder.events.where(
        (e) => e.seq >= from && e.kind == TraceKind.pointer,
      ),
      isEmpty,
    );
    controller.stop();
    await tester.pump();
  });

  testWidgets("the agent's synthetic tap is tagged by: agent", (tester) async {
    await pumpApp(tester);
    controller.agent.enabled = true;
    await toolResult(tester, controller, 'tap', {
      'target': {'text': '+'},
    });
    final down = events(TraceKind.pointer)
        .firstWhere((e) => e.data['phase'] == 'down');
    expect(down.data['by'], 'agent');
    controller.agent.enabled = false;
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('keys are recorded; Pinpoint\'s own shortcut is not', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    final keys = events(TraceKind.key);
    expect(
      keys.where((e) => e.data['key'] == 'Q').map((e) => e.data['phase']),
      ['down', 'up'],
    );
    expect(
      keys.where((e) => e.data['key'] == 'C' && e.data['phase'] == 'down'),
      isEmpty,
    );
    controller.stop();
    await tester.pump();
  });

  testWidgets('a route change, an error and a finding are recorded', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(events(TraceKind.route).single.data, {'from': null, 'to': '/'});
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(events(TraceKind.route).last.data, {'from': '/', 'to': '/next'});

    FlutterError.reportError(
      FlutterErrorDetails(exception: StateError('boom'), library: 'test'),
    );
    expect(tester.takeException(), isStateError);
    final error = events(TraceKind.error).single;
    expect(error.data['type'], 'StateError');
    expect(error.data['message'], 'Bad state: boom');

    controller.findings.addCaptured([
      const Finding(
        kind: 'overflow',
        severity: Severity.error,
        summary: 'Row overflows by 12 px on the right',
      ),
    ]);
    final finding = events(TraceKind.finding).single;
    expect(finding.data['kind'], 'overflow');
    expect(finding.data['summary'], contains('Row overflows'));
    // Listed again by the next change: not new.
    controller.findings.addCaptured(const []);
    expect(events(TraceKind.finding), hasLength(1));
    await tester.pump(Duration.zero);
  });
}

class _Screen extends StatefulWidget {
  const _Screen();

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('count $count'),
            ElevatedButton(
              onPressed: () => setState(() => count++),
              // PIN:plus
              child: const Text('+'),
            ),
            const SizedBox(width: 300, child: TextField(key: ValueKey('name'))),
            const SizedBox(
              width: 300,
              child: TextField(key: ValueKey('password'), obscureText: true),
            ),
            Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).pushNamed('/next'),
                child: const Text('Next'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

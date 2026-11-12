import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/trace_host.dart';

/// PLAN-v2 Milestone 13, acceptance "the cost of level 1 on the example's
/// long list is inside the budget", measured in the VM on a copy of the
/// example's long list.
///
/// Session 16 has not set the budget yet. The plan's numbers are used
/// until then: level 1 within 3 % of off for frame time, `get_screen`
/// within 5 %. VM wall time in a test is too noisy for 3 %, so the check
/// is on the recorder's own time per frame (what the frame events carry),
/// with loose guards; the numbers go to docs/api-notes.md, and the real
/// check is a CPU profile in Chrome.
void main() {
  late PinPointController controller;
  final scroll = ScrollController();

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget app(bool trace) => traceApp(
    controller: controller,
    config: PinPointConfig(trace: TraceConfig(enabled: trace)),
    home: _LongList(controller: scroll),
  );

  /// Wall time of [frames] frames that each scroll the list by 24 px.
  Future<Duration> scrollFrames(WidgetTester tester, int frames) async {
    final watch = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      scroll.jumpTo((scroll.offset + 24) % 20000);
      await tester.pump(const Duration(milliseconds: 16));
    }
    return watch.elapsed;
  }

  /// The median time of [runs] `get_screen` calls, in microseconds.
  Future<int> getScreen(WidgetTester tester, int runs) async {
    final times = <int>[];
    for (var i = 0; i < runs; i++) {
      final watch = Stopwatch()..start();
      await toolResult(tester, controller, 'get_screen');
      times.add(watch.elapsedMicroseconds);
    }
    times.sort();
    return times[times.length ~/ 2];
  }

  testWidgets('acceptance: level 1 on the long list stays in budget (VM)', (
    tester,
  ) async {
    // Warm up both ways first: the first frames compile and cache.
    await tester.pumpWidget(app(false));
    await scrollFrames(tester, 60);
    await tester.pumpWidget(app(true));
    await scrollFrames(tester, 60);

    final off = <Duration>[];
    final on = <Duration>[];
    // The recorder's own time per frame, as the frame events report it.
    final selfTimes = <int>[];
    // Alternate which goes first, so warm-up and GC do not favour one.
    for (var round = 0; round < 4; round++) {
      for (final trace in round.isEven ? [false, true] : [true, false]) {
        await tester.pumpWidget(app(trace));
        expect(TraceSession.current == null, !trace);
        (trace ? on : off).add(await scrollFrames(tester, 120));
        if (trace) {
          selfTimes.addAll([
            for (final e in recorder.events)
              if (e.kind == TraceKind.frame && e.data['us'] is int)
                e.data['us']! as int,
          ]);
        }
      }
    }
    selfTimes.sort();
    final selfMedian = selfTimes[selfTimes.length ~/ 2];
    final selfP95 = selfTimes[(selfTimes.length * 0.95).floor()];

    int best(List<Duration> runs) =>
        runs.map((d) => d.inMicroseconds).reduce((a, b) => a < b ? a : b);
    final ratio = best(on) / best(off);

    await tester.pumpWidget(app(false));
    final screenOff = await getScreen(tester, 9);
    await tester.pumpWidget(app(true));
    final screenOn = await getScreen(tester, 9);

    debugPrint(
      'pinpoint trace cost (VM): 120 scroll frames off ${best(off)} us, on '
      '${best(on)} us (x${ratio.toStringAsFixed(3)}); recorder per frame '
      'median $selfMedian us, p95 $selfP95 us; get_screen median off '
      '$screenOff us, on $screenOn us',
    );
    // Loose guards: a source that does far too much per frame fails here.
    // The wall-time ratio is printed, not checked: in the VM it swings
    // between 0.95 and 1.6 from run to run with nothing changed.
    expect(selfMedian, lessThan(200));
    expect(selfP95, lessThan(1000));
    expect(screenOn / screenOff, lessThan(1.5));
  });
}

class _LongList extends StatelessWidget {
  const _LongList({required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Long list')),
    body: ListView.builder(
      controller: controller,
      itemCount: 1000,
      itemBuilder: (context, index) => ListTile(
        leading: CircleAvatar(child: Text('${index + 1}')),
        title: Text('Item ${index + 1}'),
        subtitle: const Text('A subtitle that may wrap on narrow viewports.'),
        trailing: const Icon(Icons.more_vert),
      ),
    ),
  );
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/trace_causes.dart';
import 'package:pinpoint/src/trace/trace_format.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 14, build step 7: `why` and `caused_by`, plain Dart.
///
/// The planted loop runs here with real zones and a fake engine: a widget
/// builds in each frame, and a post-frame callback of that frame (which
/// runs with the frame's cause, `scheduler/binding.dart:818`) sets state
/// and starts a request. The state makes the next frame. This is the test
/// of the whole milestone in the plan's "How to verify".
void main() {
  tearDown(CauseZone.debugReset);

  const widget = '_ImproveExistingConfig';
  const source = 'lib/screens/existing.dart:40:12';

  Future<TraceRecorder> plantedLoop({bool rebuilds = true}) async {
    final recorder = TraceRecorder();
    final engine = _Engine();
    if (rebuilds) recorder.startRebuildCoverage();
    var dirty = true;
    var requests = 0;
    final answers = <Future<void>>[];
    engine.onFrame = () {
      // build: level 3 records the widget's rebuild.
      if (rebuilds) {
        recorder.add(TraceKind.build, widget: widget, source: source);
      }
      // A post-frame callback added during build: the planted load.
      if (requests < 6) {
        dirty = true; // setState(() => _loading = true)
        requests++;
        recorder.add(
          TraceKind.netRequest,
          data: const {'method': 'GET', 'url': '/existing?type=faq'},
        );
        answers.add(
          Future<void>.delayed(const Duration(milliseconds: 30), () {
            recorder.add(
              TraceKind.netResponse,
              data: const {
                'method': 'GET',
                'url': '/existing?type=faq',
                'status': 200,
              },
            );
          }),
        );
      }
    };
    // The engine draws a frame whenever one was asked for.
    for (var i = 0; i < 8 && dirty; i++) {
      dirty = false;
      engine.frame();
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await Future.wait(answers);
    return recorder;
  }

  TraceEvent nthRequest(TraceRecorder recorder, int n) => recorder.events
      .where((e) => e.kind == TraceKind.netRequest)
      .elementAt(n - 1);

  group('why', () {
    test('acceptance: why on the 5th request of the planted loop returns a '
        "chain that names the widget's build", () async {
      final recorder = await plantedLoop();
      final fifth = nthRequest(recorder, 5);
      final answer = whyAnswer(recorder, fifth.seq);
      final chain = (answer['chain']! as List<Object?>).cast<String>();
      expect(chain.first, contains('net.request'));
      expect(chain.join('\n'), contains('build  $widget (existing.dart:40)'));
      // Walks back frame to frame, and sees the same work repeat.
      expect(
        chain.where((l) => l.startsWith('cause c')).length,
        greaterThan(1),
      );
      expect(answer['loop'], isTrue);
      // A short chain, not the whole run.
      expect(chain.length, lessThanOrEqualTo(20));
    });

    test('a tap ends the chain at its entry', () async {
      final recorder = TraceRecorder();
      final engine = _Engine();
      engine.onPointer = () {
        recorder.add(
          TraceKind.pointer,
          widget: 'SaveButton',
          data: const {'phase': 'down'},
        );
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 5), () {
            recorder.add(
              TraceKind.netRequest,
              data: const {'method': 'POST', 'url': '/save'},
            );
          }),
        );
      };
      engine.pointer();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final request = recorder.events.last;
      final answer = whyAnswer(recorder, request.seq);
      final chain = (answer['chain']! as List<Object?>).join('\n');
      expect(chain, contains('pointer'));
      expect(chain, contains('entry:'));
      expect(chain, contains('SaveButton'));
      expect(answer['loop'], isFalse);
    });

    test('state.notify and state.setState are notable events of a cause, '
        'and make the next frame dirty (PLAN-v3 Milestone 21)', () async {
      final recorder = TraceRecorder();
      final engine = _Engine();
      // The first tap only logs a probe; the second one sets state.
      engine.onPointer = () => recorder.add(TraceKind.probe);
      engine.pointer();
      engine.onPointer = () {
        recorder.add(
          TraceKind.stateNotify,
          widget: 'ProductDetailProvider',
          data: const {
            'owner': 'ProductDetailProvider',
            'tag': '#a1',
            'method': 'ProductDetailProvider.fetchDialog',
          },
        );
      };
      engine.pointer();
      final notify = recorder.events.last;
      engine.onFrame = () => recorder.add(TraceKind.build, widget: 'Screen');
      engine.frame();

      final answer = whyAnswer(recorder, recorder.events.last.seq);
      final chain = (answer['chain']! as List<Object?>).join('\n');
      // The frame was made dirty by the tap that notified, not the probe.
      expect(chain, contains('made dirty by c${notify.cause} (pointer)'));
      // And that cause lists the notify as what it did.
      expect(chain, contains('state.notify  ProductDetailProvider #a1'));
      expect(chain, contains('in ProductDetailProvider.fetchDialog'));
    });

    test('without causes it says so, and it never fails', () {
      final recorder = TraceRecorder()..add(TraceKind.probe);
      final answer = whyAnswer(recorder, 1);
      expect(answer['hint'], 'no causes: wrap runApp in PinPoint.run');
      expect(answer['chain'], hasLength(1));
    });

    test('a seq that is not held is a clear error', () {
      final recorder = TraceRecorder()..add(TraceKind.probe);
      expect(
        () => whyAnswer(recorder, 99),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('not held'),
          ),
        ),
      );
    });

    test('rebuilds not recorded: the chain says so instead of naming no '
        'build', () async {
      final recorder = await plantedLoop(rebuilds: false);
      final answer = whyAnswer(recorder, nthRequest(recorder, 5).seq);
      expect(
        (answer['notes']! as List<Object?>).join(),
        contains('rebuilds not recorded'),
      );
    });

    test('watch out for: an old cause shows its age, so a chain that starts '
        'at app start is not read as "the first tap did it"', () {
      final recorder = TraceRecorder(clock: () => 300000);
      CauseZone().run(() {});
      final old = CauseZone.newCause(CauseKind.pointer)!;
      final event = recorder.add(TraceKind.probe, cause: old);
      // Started four minutes before its first event here.
      old.t = 300000 - 240000;
      final chain = (whyAnswer(recorder, event.seq)['chain']! as List<Object?>)
          .join('\n');
      expect(chain, contains('started 4 min ago'));
      expect(chain, contains('keeps the cause'));
    });

    test('the tool description states the post-frame limit', () {
      expect(whyLimits, contains('post-frame callback'));
    });
  });

  group('caused_by', () {
    test('counts what the widget\'s subtree started: requests and rebuilds, '
        'with the first few of each', () async {
      final recorder = await plantedLoop();
      final answer = causedByAnswer(
        recorder,
        sources: {source},
        widget: widget,
      );
      final counts = answer['counts']! as Map<String, Object?>;
      expect(counts['requests'], 6);
      // Six frames each started a load; the seventh only built.
      expect(counts['rebuilds'], 7);
      expect(answer['summary'], contains('6 requests, 7 rebuilds'));
      final first = answer['first']! as Map<String, Object?>;
      expect((first['requests']! as List<Object?>).length, 3);
    });

    test('a tap on the widget counts what its cause did', () async {
      final recorder = TraceRecorder();
      final engine = _Engine();
      engine.onPointer = () {
        recorder
          ..add(
            TraceKind.pointer,
            widget: 'SaveButton',
            source: 'lib/save.dart:9:3',
            data: const {'phase': 'down'},
          )
          ..add(
            TraceKind.netRequest,
            data: const {'method': 'POST', 'url': '/save'},
          );
      };
      engine.pointer();
      engine.pointer();
      final answer = causedByAnswer(
        recorder,
        sources: {'lib/save.dart:9:3'},
        widget: 'SaveButton',
      );
      expect((answer['counts']! as Map)['requests'], 2);
      expect((answer['counts']! as Map)['taps'], 2);
    });

    test('since limits the window', () async {
      final recorder = await plantedLoop();
      final answer = causedByAnswer(
        recorder,
        sources: {source},
        widget: widget,
        since: SeqBound(nthRequest(recorder, 6).seq),
      );
      expect((answer['counts']! as Map)['requests'], 1);
    });

    test('nothing recorded says so', () {
      final recorder = TraceRecorder();
      final answer = causedByAnswer(recorder, sources: {}, widget: 'X');
      expect(answer['summary'], 'nothing recorded for X in the window');
    });
  });
}

class _Packet {}

/// A fake engine: frames and pointer packets come from outside every
/// cause, through the binding zone.
class _Engine {
  _Engine()
    : zone = CauseZone(
        kindOf: (arg) => switch (arg) {
          _Packet() => CauseKind.pointer,
          Duration() => CauseKind.frame,
          _ => null,
        },
      ) {
    zone.run(() => _binding = Zone.current);
  }

  final CauseZone zone;
  late Zone _binding;
  void Function()? onFrame;
  void Function()? onPointer;

  void frame() =>
      _binding.runUnaryGuarded<Duration>((_) => onFrame?.call(), Duration.zero);

  void pointer() =>
      _binding.runUnaryGuarded<Object?>((_) => onPointer?.call(), _Packet());
}

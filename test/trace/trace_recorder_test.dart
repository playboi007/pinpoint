import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/trace_format.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 13, build step 1: the event model and the recorder's
/// limits. Plain Dart, no widget tree.
void main() {
  group('TraceEvent', () {
    test('round trips through JSON and one JSONL line', () {
      final event = TraceEvent(
        seq: 7,
        t: 1234,
        frame: 40,
        kind: TraceKind.build,
        widget: 'Counter',
        source: 'lib/counter.dart:12:5',
        data: const {'n': 3},
      );
      final back = TraceEvent.fromJsonLine(event.toJsonLine())!;
      expect(back.toJson(), event.toJson());
      expect(event.toJsonLine(), isNot(contains('\n')));
      // Empty and unset fields stay out of the line.
      final bare = TraceEvent(seq: 1, t: 0, frame: 0, kind: 'frame');
      expect(bare.toJson().keys, ['seq', 't', 'frame', 'kind']);
    });

    test('reads the fixture run and skips broken lines', () {
      final text = File('test/fixtures/runs/loop.jsonl').readAsStringSync();
      final events = TraceEvent.parseJsonl('$text\n{broken\n\n{"seq":1}\n');
      expect(events, hasLength(42));
      expect(events.first.kind, TraceKind.frame);
      expect(events.last.kind, TraceKind.error);
    });

    test('kind filters match a prefix up to a dot', () {
      expect(TraceKind.matches('input.key', 'input'), isTrue);
      expect(TraceKind.matches('input.key', 'input.key'), isTrue);
      expect(TraceKind.matches('inputs', 'input'), isFalse);
      expect(TraceKind.matches('build', 'input'), isFalse);
    });

    test('traceValues clips like a state dump', () {
      final values = traceValues({
        'long': 'x' * 500,
        'list': List<int>.generate(50, (i) => i),
        'object': Object(),
        'nested': {
          'deep': [1, 2],
        },
        'nan': double.nan,
      });
      expect((values['long']! as String).length, maxTraceChars);
      expect(values['list'], hasLength(maxTraceItems));
      expect(values['object'], "Instance of 'Object'");
      // One level deep only: the inner list becomes text.
      expect((values['nested']! as Map)['deep'], '[1, 2]');
      expect(values['nan'], 'NaN');
    });
  });

  group('TraceRecorder', () {
    test('acceptance: 30,000 events in leave 20,000, and get_trace says '
        'partial: true', () {
      final recorder = TraceRecorder();
      for (var i = 0; i < 30000; i++) {
        recorder.add(TraceKind.probe, data: {'i': i});
      }
      expect(recorder.length, 20000);
      expect(recorder.dropped, 10000);
      expect(recorder.oldest!.seq, 10001);
      expect(recorder.newest!.seq, 30000);
      expect(recorder.partial, isTrue);

      final answer = traceAnswer(recorder, const TraceQuery());
      expect(answer['partial'], isTrue);
      expect(answer['reason'], contains('10000'));
      // A window inside what is held is whole.
      final recent = traceAnswer(
        recorder,
        const TraceQuery(since: SeqBound(29990)),
      );
      expect(recent['partial'], isFalse);
    });

    test('the byte limit drops the oldest too', () {
      final recorder = TraceRecorder(maxEvents: 1000, maxBytes: 10 * 1024);
      for (var i = 0; i < 500; i++) {
        recorder.add(TraceKind.probe, data: {'text': 'y' * 150});
      }
      expect(recorder.bytes, lessThanOrEqualTo(10 * 1024));
      expect(recorder.length, lessThan(500));
      expect(recorder.dropped, 500 - recorder.length);
      expect(recorder.newest!.seq, 500);
    });

    test('an event larger than the byte limit is still kept alone', () {
      final recorder = TraceRecorder(maxEvents: 10, maxBytes: 100);
      recorder
        ..add('a')
        ..add('b', data: {'text': 'z' * 200});
      expect(recorder.length, 1);
      expect(recorder.newest!.kind, 'b');
    });

    test('seq, time and frame come from the run', () {
      var clock = 0;
      var frame = 5;
      final recorder = TraceRecorder(clock: () => clock, frameOf: () => frame);
      final a = recorder.add('a');
      clock = 40;
      frame = 6;
      final b = recorder.add('b');
      expect([a.seq, a.t, a.frame], [1, 0, 5]);
      expect([b.seq, b.t, b.frame], [2, 40, 6]);
      recorder.clear();
      // A seq is never reused.
      expect(recorder.add('c').seq, 3);
      expect(recorder.dropped, 0);
    });

    test('rebuild gaps cover what level 3 did not record', () {
      final recorder = TraceRecorder();
      for (var i = 0; i < 10; i++) {
        recorder.add('a'); // seq 1-10: not covered
      }
      recorder.startRebuildCoverage();
      for (var i = 0; i < 5; i++) {
        recorder.add('b'); // seq 11-15: covered
      }
      recorder.endRebuildCoverage();
      for (var i = 0; i < 5; i++) {
        recorder.add('c'); // seq 16-20: not covered
      }
      expect(recorder.rebuildGaps(1, 20), [(1, 10), (16, 20)]);
      expect(recorder.rebuildGaps(11, 15), isEmpty);
      expect(recorder.rebuildGaps(12, 18), [(16, 18)]);
      recorder.startRebuildCoverage();
      recorder.add('d'); // 21: covered, still open
      expect(recorder.rebuildGaps(19, 21), [(19, 20)]);
    });

    test('a gap inside the open interval: DevTools cleared the slot for a '
        'frame', () {
      final recorder = TraceRecorder()..startRebuildCoverage();
      for (var i = 0; i < 10; i++) {
        recorder.add('a'); // seq 1-10
      }
      recorder.rebuildGap(4, 6);
      recorder.add('b'); // 11: covered
      expect(recorder.rebuildGaps(1, 11), [(4, 6)]);
      expect(recorder.rebuildsRecorded, isTrue);
      // A gap from the interval's start moves the start.
      final fresh = TraceRecorder()..startRebuildCoverage();
      for (var i = 0; i < 5; i++) {
        fresh.add('a'); // seq 1-5
      }
      fresh.rebuildGap(1, 3);
      expect(fresh.rebuildGaps(1, 5), [(1, 3)]);
      // No open interval: nothing to split.
      recorder.endRebuildCoverage();
      recorder.rebuildGap(11, 11);
      expect(recorder.rebuildGaps(1, 11), [(4, 6)]);
    });

    test('frames with nothing between fold into one event: same seq, '
        'a count, the first frame and time, total and largest own time', () {
      var now = 0;
      var frame = 0;
      final recorder = TraceRecorder(clock: () => now, frameOf: () => frame);
      recorder.add('a');
      for (var i = 1; i <= 3; i++) {
        now += 16;
        frame = i;
        recorder.addFrame(us: 10 * i, builds: 2);
      }
      expect(recorder.length, 2);
      final folded = recorder.newest!;
      expect(folded.seq, 2);
      expect(recorder.nextSeq, 3);
      expect(folded.kind, TraceKind.frame);
      expect(folded.frame, 3);
      expect(folded.t, 48);
      expect(folded.data, {
        'us': 60,
        'builds': 6,
        'n': 3,
        'from': 1,
        'since': 16,
        'max': 30,
      });

      // An event between: the next frame starts a new event.
      recorder.add('b');
      now += 16;
      frame = 4;
      final single = recorder.addFrame(us: 5, builds: 1);
      expect(single.seq, 4);
      expect(single.data, {'us': 5, 'builds': 1});
      expect(
        recorder.bytes,
        recorder.events.fold<int>(0, (n, e) => n + e.approxBytes),
      );
    });

    test('a folded frame event covers at most maxFoldMs, and frames with '
        'and without a rebuild count do not fold together', () {
      var now = 0;
      final recorder = TraceRecorder(clock: () => now);
      for (var i = 0; i < 200; i++) {
        now += 16;
        recorder.addFrame(us: 1);
      }
      // 3.2 s of frames: one event per second, not 200.
      expect(recorder.length, inInclusiveRange(3, 4));
      for (final event in recorder.events) {
        final since = event.data['since'] as int? ?? event.t;
        expect(event.t - since, lessThan(TraceRecorder.maxFoldMs));
      }
      final before = recorder.length;
      now += 16;
      recorder.addFrame(us: 1, builds: 0);
      expect(recorder.length, before + 1);
    });

    test('the recorder charges and hands back its own time', () {
      final recorder = TraceRecorder()
        ..charge(120)
        ..charge(30);
      expect(recorder.takeSelfMicros(), 150);
      expect(recorder.takeSelfMicros(), 0);
    });
  });

  test('model, recorder and format import no dart:ui or package:flutter '
      '(PLAN-v2 rule 13)', () {
    final import = RegExp(
      r'''^(?:import|export)\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );
    for (final path in [
      'lib/src/model/trace_event.dart',
      'lib/src/trace/trace_recorder.dart',
      'lib/src/trace/trace_format.dart',
    ]) {
      final source = File(path).readAsStringSync();
      for (final match in import.allMatches(source)) {
        final uri = match[1]!;
        expect(
          uri == 'dart:ui' || uri.startsWith('package:flutter'),
          isFalse,
          reason: '$path imports $uri',
        );
      }
    }
  });
}

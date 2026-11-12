import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/annotation.dart';
import 'package:pinpoint/src/model/trace_event.dart';
import 'package:pinpoint/src/trace/trace_format.dart';
import 'package:pinpoint/src/trace/trace_recorder.dart';

/// PLAN-v2 Milestone 13, step 10: the compact format and the `get_trace`
/// query, on the fixture run in `test/fixtures/runs/loop.jsonl` (a widget
/// that starts a load from `build`, twelve times).
void main() {
  late List<TraceEvent> loop;

  setUpAll(() {
    loop = TraceEvent.parseJsonl(
      File('test/fixtures/runs/loop.jsonl').readAsStringSync(),
    );
  });

  /// A recorder holding [events] as they are, with the clock at [now].
  TraceRecorder replay(List<TraceEvent> events, {int now = 2000}) {
    final recorder = TraceRecorder(clock: () => now);
    for (final e in events) {
      recorder.frameOf = () => e.frame;
      if (e.kind == TraceKind.detailOn) recorder.startRebuildCoverage();
      recorder.add(e.kind, data: e.data, widget: e.widget, source: e.source);
    }
    return recorder;
  }

  test('how to verify: the loop is readable in 20 lines', () {
    final answer = traceAnswer(replay(loop), const TraceQuery());
    final lines = (answer['lines']! as String).split('\n');
    expect(lines.length, lessThanOrEqualTo(20), reason: lines.join('\n'));
    // The repeating block shows once, with its count.
    expect(lines, contains(contains('×12 of:')));
    expect(lines, contains(contains('build  _ImproveExistingConfig')));
    expect(
      lines,
      contains(contains('probe  existing.ensureLoaded type=faq loaded=false')),
    );
    // Frames are counted, not listed.
    expect(answer['frames'], 13);
    expect(lines.where((l) => l.contains('  frame  ')), isEmpty);
  });

  test('equal lines in a row fold into one with ×n', () {
    final events = [
      for (var i = 0; i < 31; i++)
        TraceEvent(
          seq: 412 + i,
          t: 3210 + i * 16,
          frame: 100 + i,
          kind: TraceKind.build,
          widget: '_ImproveExistingConfig',
        ),
    ];
    final lines = compactTrace(events).lines;
    expect(lines, [
      '412-442  +3.21s  f100-130  build  _ImproveExistingConfig  ×31',
    ]);
  });

  test('lines are cut to 200 characters and to the newest 50', () {
    final events = [
      for (var i = 0; i < 80; i++)
        TraceEvent(
          seq: i + 1,
          t: i,
          frame: i,
          kind: TraceKind.probe,
          data: {
            'name': 'p$i',
            'values': {'v': 'w' * 300},
          },
        ),
    ];
    final compact = compactTrace(events);
    expect(compact.lines, hasLength(50));
    expect(compact.more, 30);
    expect(compact.lines.first, startsWith('31  '));
    expect(compact.lines.every((l) => l.length <= 200), isTrue);
  });

  test('since and until take a seq, seconds back or the last mark', () {
    final recorder = TraceRecorder(clock: () => 0);
    var now = 0;
    final timed = TraceRecorder(clock: () => now);
    for (var i = 0; i < 10; i++) {
      now = i * 1000;
      timed.add(TraceKind.probe, data: {'name': 'p$i'});
      recorder.add(i == 4 ? TraceKind.mark : TraceKind.probe);
    }
    now = 10000;
    int matched(TraceRecorder r, Map<String, Object?> args) =>
        traceAnswer(r, TraceQuery.fromArgs(args))['matched']! as int;
    expect(matched(recorder, {'since': 3, 'until': 6}), 4);
    expect(matched(recorder, {'since': 'mark'}), 6);
    expect(matched(recorder, {'until': 'mark'}), 5);
    // The last three seconds: events at t = 7, 8 and 9 s.
    expect(matched(timed, {'since': '3s'}), 3);
    expect(
      () => TraceQuery.fromArgs({'since': 'yesterday'}),
      throwsFormatException,
    );
    expect(
      () =>
          traceAnswer(TraceRecorder(), TraceQuery.fromArgs({'since': 'mark'})),
      throwsFormatException,
    );
  });

  test('kinds, widget and full detail filter and shape the answer', () {
    final recorder = replay(loop);
    final inputs = traceAnswer(
      recorder,
      TraceQuery.fromArgs({
        'kinds': ['input'],
      }),
    );
    expect(inputs['matched'], 2);
    final frames = traceAnswer(
      recorder,
      TraceQuery.fromArgs({
        'kinds': ['frame'],
        'detail': 'full',
        'limit': 5,
      }),
    );
    expect(frames['events'], hasLength(5));
    expect(frames['more'], contains('8 earlier events'));
    final byWidget = traceAnswer(
      recorder,
      TraceQuery.fromArgs({'widget': 'existing.dart'}),
    );
    expect(byWidget['matched'], 24);
  });

  test('acceptance: get_trace for a window before detail.on says that '
      'rebuilds were not recorded there', () {
    final recorder = replay(loop);
    final before = traceAnswer(recorder, const TraceQuery(until: SeqBound(4)));
    final notes = before['notes']! as List<Object?>;
    expect(notes.single, contains('rebuilds not recorded for seq 1-4'));
    expect(notes.single, contains('trace_detail'));
    final after = traceAnswer(recorder, const TraceQuery(since: SeqBound(6)));
    expect(after['notes'], isNull);
    // Only inputs asked: rebuilds do not matter, no note.
    final inputs = traceAnswer(
      recorder,
      const TraceQuery(kinds: ['input'], until: SeqBound(4)),
    );
    expect(inputs['notes'], isNull);
  });

  test('every kind has a short summary', () {
    String line(String kind, Map<String, Object?> data, {String? widget}) =>
        traceSummary(
          TraceEvent(
            seq: 1,
            t: 0,
            frame: 0,
            kind: kind,
            widget: widget,
            data: data,
          ),
        );
    expect(
      line(TraceKind.pointer, {
        'phase': 'down',
        'x': 10,
        'y': 20,
        'fx': 0.5,
        'fy': 0.25,
        'by': 'agent',
      }, widget: 'Counter'),
      'down Counter (0.5, 0.25) at 10,20 [agent]',
    );
    expect(
      line(TraceKind.text, {'value': '[masked]'}, widget: 'TextField'),
      'TextField "[masked]"',
    );
    expect(line(TraceKind.route, {'from': '/', 'to': '/a'}), '/ → /a');
    expect(
      line(TraceKind.state, {
        'state': '_ParentState',
        'changed': {
          'count': ['1', '2'],
        },
      }),
      '_ParentState count: 1 → 2',
    );
    expect(line(TraceKind.mark, {'text': 'here'}), '"here"');
    expect(
      line(TraceKind.detailOn, {
        'sources': ['watch'],
        'reason': 'rebuild slot taken',
      }),
      'level 3 on: watch; rebuild slot taken',
    );
    expect(shortSource('lib/screens/home.dart:120:12'), 'home.dart:120');
  });

  group('noteTrace (a note\'s "What happened")', () {
    test('keeps the window, filters builds by subtree, and names the part '
        'where level 3 was off', () {
      final recorder = replay(loop);
      final trace = noteTrace(
        recorder,
        end: 2000,
        subtree: {'lib/screens/existing.dart:120:12'},
      )!;
      final lines = (trace['lines']! as List<Object?>).cast<String>();
      expect(lines.first, '$traceNotRecorded for seq 1-4');
      expect(lines, contains(endsWith('×12 of:')));
      expect(lines, contains(contains('build  _ImproveExistingConfig')));
      expect(trace['rebuilds'], isFalse);

      // Another widget's subtree: the loop's builds are left out, its probes
      // stay.
      final other = noteTrace(
        recorder,
        end: 2000,
        subtree: {'lib/x.dart:1:1'},
      )!;
      final otherLines = (other['lines']! as List<Object?>).cast<String>();
      expect(otherLines.where((l) => l.contains('build  ')), isEmpty);
      expect(otherLines, contains(contains('existing.ensureLoaded')));
    });

    test('with level 3 off for the whole window: inputs, routes and errors '
        'only, under "rebuilds not recorded"', () {
      final recorder = TraceRecorder(clock: () => 0);
      for (final e in loop.where((e) => e.kind != TraceKind.detailOn)) {
        recorder.add(e.kind, data: e.data, widget: e.widget, source: e.source);
      }
      final lines =
          (noteTrace(recorder, end: 0, subtree: {})!['lines']! as List<Object?>)
              .cast<String>();
      expect(lines.first, traceNotRecorded);
      expect(
        lines
            .skip(1)
            .every(
              (l) =>
                  l.contains('input.') ||
                  l.contains('  route  ') ||
                  l.contains('  error  '),
            ),
        isTrue,
        reason: lines.join('\n'),
      );
    });

    test('nothing in the window: no trace', () {
      final recorder = TraceRecorder(clock: () => 60000);
      expect(noteTrace(recorder, end: 60000, subtree: {}), isNull);
    });

    test('the size budget cuts the trace first and keeps its first line', () {
      final note = Annotation(
        id: 'pp_20261113_100000_a1f3',
        createdAt: DateTime.utc(2026, 11, 13, 10),
        intent: AnnotationIntent.bug,
        comment: 'Loads twice',
        app: const AppInfo(buildMode: 'debug', platform: 'web'),
        page: const PageInfo(route: '/'),
        target: const TargetInfo(widget: 'Text', sourceUnavailable: false),
        trace: {
          'seconds': 10,
          'rebuilds': false,
          'lines': [
            traceNotRecorded,
            for (var i = 0; i < 59; i++)
              '$i  +0.0${i}s  f$i  probe  ${'p' * 150}',
          ],
        },
      );
      final fitted = note.fitToBudget();
      expect(fitted.truncated.first, 'trace');
      final lines = (fitted.trace!['lines']! as List<Object?>).cast<String>();
      expect(lines, hasLength(20));
      expect(lines.first, traceNotRecorded);
      expect(lines.last, startsWith('58  '));

      final back = Annotation.fromJson(fitted.toJson())!;
      expect(back.trace, fitted.trace);
      expect(fitted.toJson()['schema'], 7);
    });
  });
}

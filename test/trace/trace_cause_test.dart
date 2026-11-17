import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';
import 'package:pinpoint/src/trace/sources/error_source.dart';
import 'package:pinpoint/src/trace/trace_format.dart';

/// PLAN-v2 Milestone 14, build step 2: causes in the recorder. The zone
/// parts are plain `test`s with real async; widget tests only check that
/// nothing breaks (watch out for: `flutter test` has its own zone).
void main() {
  tearDown(CauseZone.debugReset);

  group('recorder', () {
    test('an event takes the cause of the zone it is added in; the cause '
        'keeps its first seq and its start in recorder time', () async {
      final recorder = TraceRecorder();
      final zone = CauseZone();
      final done = Completer<void>();
      late Zone binding;
      zone.run(() => binding = Zone.current);
      binding.run(() {
        recorder.add(TraceKind.pointer, data: const {'phase': 'down'});
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 5), () {
            recorder.add(TraceKind.state);
            done.complete();
          }),
        );
      });
      await done.future;
      final events = recorder.events.toList();
      expect(events[0].cause, isNotNull);
      expect(events[1].cause, events[0].cause);
      final cause = recorder.causeOf(events[0].cause!)!;
      expect(cause.firstSeq, events[0].seq);
      expect(cause.t, isNotNull);
      // An `other` entry takes the kind of its first input event.
      expect(cause.kind, 'pointer');
    });

    test('Pinpoint\'s own work and TraceConfig.causes false give no '
        'cause', () {
      final recorder = TraceRecorder();
      final zone = CauseZone();
      late Zone binding;
      zone.run(() => binding = Zone.current);
      binding.run(() {
        CauseZone.internal(() => recorder.add(TraceKind.probe));
        recorder.readCauses = false;
        recorder.add(TraceKind.probe);
        recorder.readCauses = true;
        recorder.add(TraceKind.probe);
      });
      final causes = [for (final e in recorder.events) e.cause];
      expect(causes[0], isNull);
      expect(causes[1], isNull);
      expect(causes[2], isNotNull);
    });

    test('a cause given to add wins over the zone (a response that arrives '
        'outside the zone of its request)', () {
      final recorder = TraceRecorder();
      final zone = CauseZone();
      zone.run(() {});
      final message = CauseZone.newCause(CauseKind.message)!;
      final event = recorder.add(TraceKind.message, cause: message);
      expect(event.cause, message.id);
      expect(recorder.causeOf(message.id), same(message));
    });

    test('the cause table is bounded', () {
      final recorder = TraceRecorder();
      CauseZone().run(() {});
      for (var i = 0; i < TraceRecorder.maxCauses + 10; i++) {
        recorder.add(TraceKind.probe, cause: CauseZone.newCause('other'));
      }
      expect(recorder.causes, hasLength(TraceRecorder.maxCauses));
    });

    test('compact lines show the cause', () {
      final recorder = TraceRecorder();
      CauseZone().run(() {});
      recorder.add(TraceKind.probe, cause: CauseZone.newCause('other'));
      final answer = traceAnswer(recorder, const TraceQuery());
      expect(answer['lines'], matches(RegExp(r'f0  c\d+  probe')));
    });
  });

  group('without PinPoint.run', () {
    test('acceptance: no error, no causes, one hint', () {
      final recorder = TraceRecorder()..add(TraceKind.probe);
      expect(recorder.events.single.cause, isNull);
      expect(recorder.causesRecorded, isFalse);
      final answer = traceAnswer(recorder, const TraceQuery());
      expect(answer['hint'], 'no causes: wrap runApp in PinPoint.run');
      expect('${answer['lines']}'.contains('hint'), isFalse);
    });

    test('with the zone running, the hint is gone', () {
      CauseZone().run(() {});
      final recorder = TraceRecorder()..add(TraceKind.probe);
      expect(recorder.causesRecorded, isTrue);
      expect(traceAnswer(recorder, const TraceQuery())['hint'], isNull);
    });
  });

  group('uncaught errors', () {
    test('an uncaught error becomes an error event with its cause', () {
      final recorder = TraceRecorder();
      final source = ErrorSource()..start(recorder);
      addTearDown(source.stop);
      CauseZone().run(() {});
      final cause = CauseZone.newCause(CauseKind.pointer);
      ErrorSource.uncaught(StateError('lost'), cause);
      final event = recorder.events.single;
      expect(event.kind, TraceKind.error);
      expect(event.cause, cause!.id);
      expect(event.data['uncaught'], isTrue);
      expect(traceSummary(event), contains('uncaught'));
    });

    test('the same error seen again by PlatformDispatcher.onError is not '
        'recorded twice', () {
      final recorder = TraceRecorder();
      final source = ErrorSource()..start(recorder);
      addTearDown(source.stop);
      final error = StateError('once');
      ErrorSource.uncaught(error, null);
      source.debugReport(error);
      source.debugReport(StateError('another'));
      expect(recorder.events, hasLength(2));
    });
  });

  group('PinPoint.run under flutter test', () {
    testWidgets('the binding exists already: the body runs with no zone and '
        'one hint is printed', (tester) async {
      final printed = <String>[];
      final saved = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      try {
        final value = PinPoint.run(() => 42);
        expect(value, 42);
        PinPoint.run(() => 0);
      } finally {
        debugPrint = saved;
      }
      expect(CauseZone.current, isNull);
      expect(CauseZone.unavailable, contains('binding'));
      expect(printed.where((p) => p.contains('PinPoint.run')), hasLength(1));
    });

    testWidgets('TraceConfig.causes false runs the body with no zone', (
      tester,
    ) async {
      expect(
        PinPoint.run(
          () => Zone.current,
          trace: const TraceConfig(causes: false),
        ),
        same(Zone.current),
      );
      expect(CauseZone.unavailable, isNull);
    });
  });
}

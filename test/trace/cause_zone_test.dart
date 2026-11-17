import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';

/// PLAN-v2 Milestone 14, build step 1: the cause zone in plain Dart, with
/// real async and no Flutter. `flutter test` has its own zone and a fake
/// clock in `testWidgets` (watch out for), so these are plain `test`s.
///
/// A fake engine stands in for `dart:ui`: it calls a callback through the
/// zone that was current when the callback was set, and directly when that
/// zone is already current (`hooks.dart:452`, `_invoke1`).
void main() {
  tearDown(CauseZone.debugReset);

  test('each engine entry gets its own cause; its kind comes from the '
      'argument', () {
    final engine = _Engine();
    final seen = <TraceCause?>[];
    engine.start(
      (_) => seen.add(CauseZone.currentCause),
      onFrame: (_) => seen.add(CauseZone.currentCause),
    );
    engine.pointer();
    engine.pointer();
    engine.frame();
    expect(seen, hasLength(3));
    expect(seen.every((c) => c != null), isTrue);
    expect({for (final c in seen) c!.id}, hasLength(3));
    expect([for (final c in seen) c!.kind], ['pointer', 'pointer', 'frame']);
    expect(engine.zone.forks, 3);
  });

  test('a timer and a microtask made inside a cause keep it when they '
      'fire', () async {
    final engine = _Engine();
    final done = Completer<void>();
    TraceCause? entry;
    TraceCause? inTimer;
    TraceCause? inMicrotask;
    engine.start((_) {
      entry = CauseZone.currentCause;
      scheduleMicrotask(() => inMicrotask = CauseZone.currentCause);
      Timer(const Duration(milliseconds: 5), () {
        inTimer = CauseZone.currentCause;
        done.complete();
      });
    });
    engine.pointer();
    await done.future;
    expect(entry, isNotNull);
    expect(inMicrotask, same(entry));
    expect(inTimer, same(entry));
    expect(entry!.timers, 1);
  });

  test('acceptance: a tap whose handler awaits a 300 ms timer and then '
      'sets state keeps the cause of the tap', () async {
    final engine = _Engine();
    final done = Completer<void>();
    late TraceCause tap;
    TraceCause? atSetState;
    engine.start((_) async {
      tap = CauseZone.currentCause!;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      atSetState = CauseZone.currentCause;
      done.complete();
    });
    engine.pointer();
    // A frame in between is a cause of its own.
    engine.frame();
    await done.future;
    expect(atSetState, same(tap));
    expect(tap.kind, 'pointer');
  });

  test('acceptance: two taps in a row with overlapping awaits keep their '
      'own causes', () async {
    final engine = _Engine();
    final log = <(String, TraceCause?)>[];
    final done = Completer<void>();
    var taps = 0;
    engine.start((_) async {
      final n = ++taps;
      log.add(('tap $n', CauseZone.currentCause));
      // The first tap waits longer, so the second finishes first.
      await Future<void>.delayed(Duration(milliseconds: n == 1 ? 60 : 10));
      log.add(('done $n', CauseZone.currentCause));
      if (log.length == 4) done.complete();
    });
    engine.pointer();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    engine.pointer();
    await done.future;
    expect(
      [for (final (what, _) in log) what],
      ['tap 1', 'tap 2', 'done 2', 'done 1'],
    );
    final first = log[0].$2;
    final second = log[1].$2;
    expect(first, isNot(same(second)));
    expect(log[2].$2, same(second));
    expect(log[3].$2, same(first));
  });

  test('watch out for: a nested dispatch makes no new cause, it belongs to '
      'the cause that is running', () {
    final engine = _Engine();
    final seen = <TraceCause?>[];
    var nested = false;
    engine.start((_) {
      seen.add(CauseZone.currentCause);
      if (!nested) {
        nested = true;
        // Dispatched from inside the handler, as a DOM event that fires
        // during a call into the browser: same cause.
        engine.pointer();
      }
    });
    engine.pointer();
    expect(seen, hasLength(2));
    expect(seen[1], same(seen[0]));
  });

  test('a frame begin and its draw call are one cause', () {
    final engine = _Engine();
    final seen = <TraceCause?>[];
    engine.startFrame(
      begin: (_) => seen.add(CauseZone.currentCause),
      draw: () => seen.add(CauseZone.currentCause),
    );
    engine.fullFrame();
    engine.fullFrame();
    expect(seen, hasLength(4));
    expect(seen[1], same(seen[0]));
    expect(seen[3], same(seen[2]));
    expect(seen[2], isNot(same(seen[0])));
    expect(seen[0]!.kind, 'frame');
  });

  test('no cause before the app is ready, so runApp after an await stays in '
      'the binding zone (no "Zone mismatch")', () async {
    var ready = false;
    final zone = CauseZone(ready: () => ready);
    late Zone bindingZone;
    Zone? runAppZone;
    final done = Completer<void>();
    unawaited(
      zone.run(() async {
        bindingZone = Zone.current; // ensureInitialized
        await Future<void>.delayed(const Duration(milliseconds: 5));
        runAppZone = Zone.current; // runApp
        done.complete();
      }),
    );
    await done.future;
    expect(runAppZone, same(bindingZone));
    expect(CauseZone.currentCause, isNull);
    // After runApp, entries fork.
    ready = true;
    TraceCause? later;
    bindingZone.runUnaryGuarded<Object?>(
      (_) => later = CauseZone.currentCause,
      _Packet(),
    );
    expect(later, isNotNull);
  });

  test("acceptance: an app's own runZonedGuarded inside the cause zone gets "
      'causes and keeps its error handler', () async {
    final errors = <Object>[];
    final uncaught = <(Object, TraceCause?)>[];
    final zone = CauseZone(
      kindOf: _Engine.kindOf,
      onUncaught: (e, s, c) => uncaught.add((e, c)),
    );
    late Zone appZone;
    zone.run(() {
      runZonedGuarded(() {
        appZone = Zone.current;
      }, (error, stack) => errors.add(error));
    });
    final done = Completer<void>();
    TraceCause? cause;
    appZone.runUnaryGuarded<Object?>((_) {
      cause = CauseZone.currentCause;
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 5),
          () => throw StateError('boom'),
        ).whenComplete(done.complete),
      );
    }, _Packet());
    await done.future;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(cause, isNotNull);
    expect(cause!.kind, 'pointer');
    // The app's handler got it. It sits below Pinpoint's zone, so
    // Pinpoint's handler does not see it.
    expect(errors, [isA<StateError>()]);
    expect(uncaught, isEmpty);
  });

  test('acceptance: an error thrown in an unawaited async handler is '
      "reported with its cause and still reaches the parent's handler", () {
    final parentErrors = <Object>[];
    final reported = <(Object, TraceCause?)>[];
    final done = Completer<void>();
    runZonedGuarded(() {
      final engine = _Engine(onUncaught: (e, s, c) => reported.add((e, c)));
      TraceCause? tap;
      engine.start((_) {
        tap = CauseZone.currentCause;
        unawaited(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          throw StateError('unawaited');
        }());
      });
      engine.pointer();
      Timer(const Duration(milliseconds: 40), () {
        expect(reported, hasLength(1));
        expect(reported.single.$2, same(tap));
        done.complete();
      });
    }, (error, stack) => parentErrors.add(error));
    return done.future.then((_) {
      expect(parentErrors, [isA<StateError>()]);
    });
  });

  test('a throw inside the error listener never hides the app error: the '
      'parent is still called', () {
    final parentErrors = <Object>[];
    final done = Completer<void>();
    runZonedGuarded(() {
      final engine = _Engine(
        onUncaught: (e, s, c) => throw StateError('listener broke'),
      );
      engine.start((_) {
        unawaited(Future<void>(() => throw ArgumentError('app')));
      });
      engine.pointer();
      Timer(const Duration(milliseconds: 20), done.complete);
    }, (error, stack) => parentErrors.add(error));
    return done.future.then((_) {
      expect(parentErrors, [isA<ArgumentError>()]);
    });
  });

  test('enter, internal and newCause do nothing without a cause zone', () {
    expect(CauseZone.current, isNull);
    expect(
      CauseZone.enter(CauseKind.agent, () => CauseZone.currentCause),
      isNull,
    );
    expect(CauseZone.internal(() => CauseZone.currentCause), isNull);
    expect(CauseZone.newCause(CauseKind.message), isNull);
  });

  test('enter makes a new cause even inside one; internal work is not an '
      'entry', () async {
    final engine = _Engine();
    TraceCause? agent;
    TraceCause? outer;
    TraceCause? inInternal;
    engine.start((_) {
      outer = CauseZone.currentCause;
      agent = CauseZone.enter(CauseKind.agent, () => CauseZone.currentCause);
    });
    engine.pointer();
    expect(agent, isNotNull);
    expect(agent!.kind, CauseKind.agent);
    expect(agent, isNot(same(outer)));

    final done = Completer<void>();
    engine.zone.zone.run(() {
      CauseZone.internal(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inInternal = CauseZone.currentCause;
        done.complete();
      });
    });
    await done.future;
    expect(inInternal, same(CauseZone.pinpoint));
    expect(inInternal!.internal, isTrue);
  });

  test('a periodic timer keeps its first cause, and the cause knows when '
      'it started', () async {
    final engine = _Engine();
    final seen = <TraceCause?>[];
    final done = Completer<void>();
    engine.start((_) {
      Timer.periodic(const Duration(milliseconds: 5), (timer) {
        seen.add(CauseZone.currentCause);
        if (seen.length == 3) {
          timer.cancel();
          done.complete();
        }
      });
    });
    engine.pointer();
    await done.future;
    expect(seen.toSet(), hasLength(1));
    expect(seen.first!.timers, 1);
    expect(seen.first!.startedMs, lessThanOrEqualTo(CauseZone.clockMs));
  });
}

/// Stands for `ui.PointerDataPacket`.
class _Packet {}

/// A fake engine: callbacks are set inside the cause zone, as the binding
/// sets them, and called through the zone they were set in.
class _Engine {
  _Engine({void Function(Object, StackTrace, TraceCause?)? onUncaught})
    : zone = CauseZone(
        kindOf: kindOf,
        inFrame: () => _midFrame,
        onUncaught: onUncaught,
      );

  static String? kindOf(Object? arg) => switch (arg) {
    _Packet() => CauseKind.pointer,
    Duration() => CauseKind.frame,
    _ => null,
  };

  static bool _midFrame = false;

  final CauseZone zone;
  late Zone _bindingZone;
  void Function(Object?)? _onPointer;
  void Function(Duration)? _onBegin;
  void Function()? _onDraw;

  void start(
    void Function(Object?) onPointer, {
    void Function(Duration)? onFrame,
  }) {
    zone.run(() {
      _bindingZone = Zone.current;
      _onPointer = onPointer;
      _onBegin = onFrame ?? (_) {};
    });
  }

  void startFrame({
    required void Function(Duration) begin,
    required void Function() draw,
  }) {
    zone.run(() {
      _bindingZone = Zone.current;
      _onBegin = begin;
      _onDraw = draw;
    });
  }

  /// Calls the pointer callback as `_invoke1` does.
  void pointer() {
    final callback = _onPointer!;
    if (identical(_bindingZone, Zone.current)) {
      callback(_Packet());
    } else {
      _bindingZone.runUnaryGuarded<Object?>(callback, _Packet());
    }
  }

  void frame() =>
      _bindingZone.runUnaryGuarded<Duration>(_onBegin!, Duration.zero);

  void fullFrame() {
    _bindingZone.runUnaryGuarded<Duration>(_onBegin!, Duration.zero);
    _midFrame = true;
    try {
      _bindingZone.runGuarded(_onDraw!);
    } finally {
      _midFrame = false;
    }
  }
}

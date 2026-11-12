// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13), so
// the zone is tested with real async and no widget tree. `PinPoint.run`
// (probe.dart) gives it the Flutter parts: which argument is a pointer
// packet or a frame, and when the app is ready.

import 'dart:async';

/// The zone value that holds the [TraceCause] of the running work.
const Symbol causeKey = #pinpointCause;

/// What started a cause (PLAN-v2 Milestone 14, step 5).
abstract final class CauseKind {
  /// One pointer packet from the engine.
  static const String pointer = 'pointer';

  /// One frame: begin frame and draw frame together.
  static const String frame = 'frame';

  /// One key event (set from the first event of an `other` entry).
  static const String key = 'key';

  /// One `message` event on `window`, or a platform message.
  static const String message = 'message';

  /// One agent command (`tap`, `navigate`, ...).
  static const String agent = 'agent';

  /// Any other entry: a timer made outside every cause, a platform
  /// message, a DOM callback.
  static const String other = 'other';

  /// Pinpoint's own work (the long poll). Never on an event (rule 14).
  static const String pinpoint = 'pinpoint';
}

/// One entry from outside that started a chain of work.
class TraceCause {
  TraceCause(this.id, this.kind, this.startedMs);

  /// Never reused. 0 is [CauseZone.pinpoint].
  final int id;

  /// See [CauseKind]. An `other` cause takes the kind of its first input
  /// event (`key`, `text`, `message`).
  String kind;

  /// When it started, on [CauseZone.clockMs].
  final int startedMs;

  /// The seq of its first event; null until it has one.
  int? firstSeq;

  /// When it started, in recorder time (ms since the run started). Set
  /// with [firstSeq]; negative for a cause older than the recorder.
  int? t;

  /// Timers made inside it, periodic ones included.
  int timers = 0;

  /// For a frame: the causes that ran since the frame before it, oldest
  /// first ("near" links, PLAN-v2 Milestone 14, step 9). One of them made
  /// this frame dirty.
  List<int> after = const <int>[];

  /// Pinpoint's own work.
  bool get internal => id == 0;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    't': ?t,
    'first': ?firstSeq,
    if (timers > 0) 'timers': timers,
    if (after.isNotEmpty) 'after': after,
  };
}

/// The zone of `PinPoint.run` (PLAN-v2 Milestone 14, steps 1 to 4).
///
/// The engine calls every binding callback through the zone that was
/// current when the binding set it (`dart:ui` `hooks.dart:452`; web
/// `platform_dispatcher.dart:1740`). So each pointer packet, frame and
/// platform message enters through `run` or `runUnary` of this zone. On
/// such an entry the handler forks a child zone with a new [TraceCause] in
/// `zoneValues` and runs the callback there.
///
/// The test for "this is an entry" is on the target zone: no cause value,
/// fork; a value, run as is. A timer or a microtask made inside a cause
/// belongs to a zone that has the value, so it keeps the cause when it
/// fires. An `await` needs nothing more: its continuation is not registered
/// with the zone (`future_impl.dart:420`), but it runs in the zone where
/// the `await` was. The same test lets an app's own `runZonedGuarded`
/// inside `PinPoint.run` keep its error handler: the child is forked from
/// the app's zone.
///
/// The child zones never get an error handler of their own. A future that
/// fails in one error zone does not deliver its error to a listener in
/// another, so a handler per cause would change what the app sees (rule
/// 11). Errors go to this zone's one handler, as they would go to the root.
class CauseZone {
  CauseZone({this.kindOf, this.inFrame, this.ready, this.onUncaught});

  /// The kind of an entry from its argument (a pointer packet, a frame's
  /// time stamp), or null for [CauseKind.other].
  final String? Function(Object? argument)? kindOf;

  /// Whether a frame is between its begin and its draw call: the draw
  /// call then joins the frame's cause.
  final bool Function()? inFrame;

  /// Whether the app runs. Before that, entries make no cause: the
  /// binding is set up in this zone, and `runApp` after an `await` must
  /// run in the same zone, or Flutter prints "Zone mismatch"
  /// (`foundation/binding.dart:438`). Null: ready at once.
  final bool Function()? ready;

  /// Told of each uncaught error with the cause it happened in. A throw
  /// inside it is dropped; the parent's handler still runs.
  void Function(Object error, StackTrace stack, TraceCause? cause)? onUncaught;

  /// The running cause zone, or null without `PinPoint.run`.
  static CauseZone? get current => _current;
  static CauseZone? _current;

  /// Why there are no causes, when `PinPoint.run` ran but could not start
  /// the zone; null otherwise.
  static String? unavailable;

  static int _nextId = 1;
  static final Stopwatch _clock = Stopwatch()..start();

  /// Milliseconds on the causes' own clock.
  static int get clockMs => _clock.elapsedMilliseconds;

  /// The cause of Pinpoint's own work. Not an entry, never on an event.
  static final TraceCause pinpoint = TraceCause(0, CauseKind.pinpoint, 0);

  /// The cause of the running code, or null outside every cause.
  static TraceCause? get currentCause {
    final cause = Zone.current[causeKey];
    return cause is TraceCause ? cause : null;
  }

  /// Runs [body] as a new cause of [kind], even inside another cause: an
  /// agent command is its own entry. Without a cause zone, just runs it.
  static R enter<R>(String kind, R Function() body) {
    final cause = newCause(kind);
    if (cause == null) return body();
    return Zone.current.fork(zoneValues: {causeKey: cause}).run(body);
  }

  /// Runs [body] as Pinpoint's own work: what it starts is not an entry
  /// and makes no cause.
  static R internal<R>(R Function() body) {
    if (_current == null) return body();
    return Zone.current.fork(zoneValues: {causeKey: pinpoint}).run(body);
  }

  /// A new cause of [kind], for an entry the zone does not see (a DOM
  /// listener called from the browser's event loop). Null without a cause
  /// zone.
  static TraceCause? newCause(String kind) =>
      _current == null ? null : TraceCause(_nextId++, kind, clockMs);

  /// Forgets the running zone, for tests.
  static void debugReset() {
    _current = null;
    unavailable = null;
  }

  /// The zone [run] made: the one the binding is set up in.
  Zone get zone => _zone!;
  Zone? _zone;

  /// Child zones forked so far: one per entry. For the cost check.
  int forks = 0;

  bool _starting = false;
  bool _ready = false;
  TraceCause? _openFrame;

  /// Most causes a frame is linked to; the newest are kept.
  static const int maxLinks = 8;

  // The causes that ran since the last frame began, oldest first.
  final List<TraceCause> _ran = <TraceCause>[];
  Object? _lastRan;

  /// Runs [body] in this zone. Call it once, around the binding's set-up
  /// and `runApp`.
  R run<R>(R Function() body) {
    _current = this;
    final zone = _zone ??= Zone.current.fork(
      specification: ZoneSpecification(
        run: _run,
        runUnary: _runUnary,
        runBinary: _runBinary,
        handleUncaughtError: _uncaught,
        createTimer: _createTimer,
        createPeriodicTimer: _createPeriodicTimer,
      ),
    );
    // The body itself is not an entry: the binding is set up here.
    _starting = true;
    try {
      return zone.run(body);
    } finally {
      _starting = false;
    }
  }

  bool _isReady() => _ready || (_ready = ready?.call() ?? true);

  /// The cause for a call into [zone], or null to run it as is.
  TraceCause? _entry(Zone zone, String? kind) {
    if (zone[causeKey] != null || _starting || !_isReady()) return null;
    // Watch out for: a nested dispatch (the browser fires an event during
    // a call from Dart) reaches here from inside a cause, because the
    // current zone is that cause's child, not the binding zone the engine
    // compares with. It belongs to the cause that is running.
    final running = Zone.current[causeKey];
    if (running is TraceCause) return running;
    if (kind == CauseKind.frame) {
      final frame = _openFrame = TraceCause(
        _nextId++,
        CauseKind.frame,
        clockMs,
      );
      // From frame to frame, the "near" way (PLAN-v2 Milestone 14, step
      // 9): the frame is linked to every cause that ran since the frame
      // before it. One of them made it dirty. The exact way
      // (`debugPrintScheduleBuildForStacks`) costs a stack per setState and
      // takes the `debugPrint` slot.
      frame.after = [for (final c in _ran) c.id];
      _ran.clear();
      _lastRan = null;
      return frame;
    }
    final frame = _openFrame;
    if (frame != null && (inFrame?.call() ?? false)) return frame;
    return TraceCause(_nextId++, kind ?? CauseKind.other, clockMs);
  }

  /// Notes that [cause] ran, for the next frame's links. Called for every
  /// callback in a cause, so the common case (the same cause again) is one
  /// `identical`.
  void _noteRan(Object? cause) {
    if (identical(cause, _lastRan)) return;
    _lastRan = cause;
    if (cause is! TraceCause || cause.internal) return;
    _ran.remove(cause);
    _ran.add(cause);
    if (_ran.length > maxLinks) _ran.removeAt(0);
  }

  Zone _fork(Zone zone, TraceCause cause) {
    forks++;
    return zone.fork(zoneValues: {causeKey: cause});
  }

  R _run<R>(Zone self, ZoneDelegate parent, Zone zone, R Function() f) {
    final Object? value = zone[causeKey];
    if (value != null) {
      _noteRan(value);
      return parent.run(zone, f);
    }
    final cause = _entry(zone, null);
    if (cause == null) return parent.run(zone, f);
    _noteRan(cause);
    return parent.run(_fork(zone, cause), f);
  }

  R _runUnary<R, T>(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    R Function(T arg) f,
    T arg,
  ) {
    final Object? value = zone[causeKey];
    if (value != null) {
      _noteRan(value);
      return parent.runUnary(zone, f, arg);
    }
    final cause = _entry(zone, kindOf?.call(arg));
    if (cause == null) return parent.runUnary(zone, f, arg);
    _noteRan(cause);
    return parent.runUnary(_fork(zone, cause), f, arg);
  }

  R _runBinary<R, T1, T2>(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    R Function(T1 arg1, T2 arg2) f,
    T1 arg1,
    T2 arg2,
  ) {
    final Object? value = zone[causeKey];
    if (value != null) {
      _noteRan(value);
      return parent.runBinary(zone, f, arg1, arg2);
    }
    final cause = _entry(zone, null);
    if (cause == null) return parent.runBinary(zone, f, arg1, arg2);
    _noteRan(cause);
    return parent.runBinary(_fork(zone, cause), f, arg1, arg2);
  }

  // Watch out for: an uncaught error now passes through Pinpoint before
  // the app's handler. A throw here would hide the app's error, so the
  // body is one guarded call and then the parent, always. There is no
  // `print` handler, and this one prints nothing: a print from inside a
  // zone's handler would come back to the zone.
  void _uncaught(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    Object error,
    StackTrace stack,
  ) {
    try {
      final cause = zone[causeKey];
      onUncaught?.call(error, stack, cause is TraceCause ? cause : null);
    } catch (_) {
      // Dropped: the app's error matters, not Pinpoint's.
    }
    parent.handleUncaughtError(zone, error, stack);
  }

  Timer _createTimer(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    Duration duration,
    void Function() f,
  ) {
    final cause = zone[causeKey];
    if (cause is TraceCause) cause.timers++;
    return parent.createTimer(zone, duration, f);
  }

  Timer _createPeriodicTimer(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    Duration period,
    void Function(Timer timer) f,
  ) {
    final cause = zone[causeKey];
    if (cause is TraceCause) cause.timers++;
    return parent.createPeriodicTimer(zone, period, f);
  }
}

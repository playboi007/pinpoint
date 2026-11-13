// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13), so
// the limits are tested without a widget tree.

import 'dart:collection';

import '../model/trace_event.dart';
import 'cause_zone.dart';

/// A bounded record of what the app did (PLAN-v2 Milestone 13).
///
/// A ring buffer, bounded twice (rule 12): by [maxEvents] and by [maxBytes].
/// When a limit is reached the oldest events go, [dropped] counts them and
/// every answer built on the record says `partial`.
///
/// [add] is O(1): it writes into a list made once, and allocates only the
/// event. The recorder only observes (rule 11): it never awaits, schedules
/// nothing and throws nothing at its callers.
class TraceRecorder {
  TraceRecorder({
    this.maxEvents = defaultMaxEvents,
    this.maxBytes = defaultMaxBytes,
    int Function()? clock,
    int Function()? frameOf,
  }) : assert(maxEvents > 0),
       assert(maxBytes > 0),
       _ring = List<TraceEvent?>.filled(maxEvents, null),
       // ignore: prefer_initializing_formals, the parameter name is public
       _clock = clock,
       frameOf = frameOf ?? _noFrame;

  /// A recorder that holds [events] as they were recorded, with their
  /// seqs, for reading a stored run with the same queries as the live one
  /// (PLAN-v2 Milestone 15, `get_trace({run})`). Its clock stands at the
  /// last event.
  factory TraceRecorder.of(List<TraceEvent> events) {
    final last = events.isEmpty ? 0 : events.last.t;
    final recorder = TraceRecorder(
      maxEvents: events.isEmpty ? 1 : events.length,
      maxBytes: 1 << 40,
      clock: () => last,
    )..readCauses = false;
    for (final event in events) {
      recorder._ring[recorder._length++] = event;
      recorder._bytes += event.approxBytes;
      recorder._nextSeq = event.seq + 1;
    }
    return recorder;
  }

  static const int defaultMaxEvents = 20000;
  static const int defaultMaxBytes = 4 * 1024 * 1024;

  /// Most intervals of rebuild coverage kept. Older ones are forgotten,
  /// and the seqs before the oldest kept count as not covered.
  static const int maxCoverage = 64;

  final int maxEvents;
  final int maxBytes;

  final List<TraceEvent?> _ring;
  final int Function()? _clock;

  /// The frame number for a new event. The frame source sets it.
  int Function() frameOf;

  /// Whether an event takes its cause from the zone it is added in
  /// (`TraceConfig.causes`).
  bool readCauses = true;

  /// Most causes kept; the oldest go first. Only causes with an event are
  /// kept, so this grows with what was recorded, not with every entry.
  static const int maxCauses = 4096;

  final LinkedHashMap<int, TraceCause> _causes =
      LinkedHashMap<int, TraceCause>();

  /// The cause [id], or null when it is not kept.
  TraceCause? causeOf(int id) => _causes[id];

  /// The causes kept, oldest first.
  Iterable<TraceCause> get causes => _causes.values;

  /// Whether events get causes: `PinPoint.run` started the cause zone and
  /// `TraceConfig.causes` is on (PLAN-v2 Milestone 14, step 7).
  bool get causesRecorded => readCauses && CauseZone.current != null;

  /// Why events have no cause, for the tools; null when they do.
  String? get causeHint {
    if (causesRecorded) return null;
    if (!readCauses) return 'no causes: TraceConfig.causes is false';
    final reason = CauseZone.unavailable;
    return reason == null
        ? 'no causes: wrap runApp in PinPoint.run'
        : 'no causes: $reason';
  }

  // The run's own clock: a recorder made on start counts from zero.
  final Stopwatch _watch = Stopwatch()..start();
  int _ms() => _clock?.call() ?? _watch.elapsedMilliseconds;
  static int _noFrame() => 0;

  int _head = 0; // index of the oldest event
  int _length = 0;
  int _bytes = 0;
  int _nextSeq = 1;
  int _dropped = 0;
  int _selfMicros = 0;

  /// Milliseconds since the run started.
  int get now => _ms();

  /// Events held now.
  int get length => _length;

  /// Approximate bytes held now.
  int get bytes => _bytes;

  /// Events dropped because a limit was reached.
  int get dropped => _dropped;

  /// Whether a limit dropped data from this run (rule 19).
  bool get partial => _dropped > 0;

  /// Why the record is partial, or null.
  String? get partialReason => _dropped == 0
      ? null
      : 'the oldest $_dropped events were dropped (limits: $maxEvents '
            'events, ${maxBytes ~/ 1024} KB)';

  /// The seq the next event gets. Also a revision: it changes on every
  /// [add].
  int get nextSeq => _nextSeq;

  /// The oldest event held, or null when empty.
  TraceEvent? get oldest => _length == 0 ? null : _ring[_head];

  /// The newest event held, or null when empty.
  TraceEvent? get newest =>
      _length == 0 ? null : _ring[(_head + _length - 1) % maxEvents];

  /// Every event held, oldest first.
  Iterable<TraceEvent> get events sync* {
    for (var i = 0; i < _length; i++) {
      yield _ring[(_head + i) % maxEvents]!;
    }
  }

  /// The events held, newest first.
  Iterable<TraceEvent> get newestFirst sync* {
    for (var i = _length - 1; i >= 0; i--) {
      yield _ring[(_head + i) % maxEvents]!;
    }
  }

  /// The event [seq], or null when it is not held. Seqs are consecutive
  /// and the oldest go first, so this is one index.
  TraceEvent? at(int seq) {
    final first = oldest;
    if (first == null) return null;
    final i = seq - first.seq;
    if (i < 0 || i >= _length) return null;
    return _ring[(_head + i) % maxEvents];
  }

  /// The newest event of [kind], or null.
  TraceEvent? lastOf(String kind) {
    for (final event in newestFirst) {
      if (event.kind == kind) return event;
    }
    return null;
  }

  /// Records one event. [data] must already be small JSON values (see
  /// [traceValues]); it is kept as given.
  ///
  /// The event's cause is [cause], or the cause of the zone it is added in
  /// (PLAN-v2 Milestone 14, step 5). Give [cause] for work that runs
  /// outside the zone of what started it, such as a response that a
  /// browser callback reports.
  TraceEvent add(
    String kind, {
    Map<String, Object?> data = const <String, Object?>{},
    String? widget,
    String? source,
    TraceCause? cause,
  }) {
    final from = readCauses ? (cause ?? CauseZone.currentCause) : null;
    // Pinpoint's own work is not a cause (rule 14).
    final owner = from == null || from.internal ? null : from;
    final event = TraceEvent(
      seq: _nextSeq++,
      t: _ms(),
      frame: frameOf(),
      kind: kind,
      cause: owner?.id,
      widget: widget,
      source: source,
      data: data,
    );
    if (owner != null && owner.firstSeq == null) _keep(owner, event);
    if (_length == maxEvents) _dropOldest();
    _ring[(_head + _length) % maxEvents] = event;
    _length++;
    _bytes += event.approxBytes;
    // Keep at least the new event, even when it alone is over the limit.
    while (_bytes > maxBytes && _length > 1) {
      _dropOldest();
    }
    for (final listener in _listeners) {
      try {
        listener(event);
      } catch (_) {
        // A listener only observes too.
      }
    }
    return event;
  }

  final List<void Function(TraceEvent event)> _listeners =
      <void Function(TraceEvent event)>[];

  /// Calls [listener] with each new event, after it is held. The tape
  /// recorder keeps inputs this way, apart from the ring buffer
  /// (Milestone 15, step 3). A listener must be as cheap as [add].
  void addListener(void Function(TraceEvent event) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(TraceEvent event) listener) =>
      _listeners.remove(listener);

  void _keep(TraceCause cause, TraceEvent first) {
    cause
      ..firstSeq = first.seq
      ..t = first.t - (CauseZone.clockMs - cause.startedMs);
    // An entry the zone could not name (a key event on web comes through
    // `run`) is named by its first input.
    if (cause.kind == CauseKind.other && TraceKind.isInput(first.kind)) {
      cause.kind = first.kind.substring('input.'.length);
    }
    _causes[cause.id] = cause;
    if (_causes.length > maxCauses) _causes.remove(_causes.keys.first);
  }

  void _dropOldest() {
    final old = _ring[_head]!;
    _ring[_head] = null;
    _head = (_head + 1) % maxEvents;
    _length--;
    _bytes -= old.approxBytes;
    _dropped++;
  }

  // Rebuild coverage: the seq intervals in which the rebuild source ran.
  // Outside them, "no build event" means "not recorded".

  final List<List<int?>> _coverage = <List<int?>>[];

  /// Whether rebuilds are recorded now.
  bool get rebuildsRecorded =>
      _coverage.isNotEmpty && _coverage.last[1] == null;

  /// Rebuilds are recorded from the next event on.
  void startRebuildCoverage() {
    if (rebuildsRecorded) return;
    _coverage.add(<int?>[_nextSeq, null]);
    // A forgotten interval reads as a gap: what it covered is unknown now.
    if (_coverage.length > maxCoverage) _coverage.removeAt(0);
  }

  /// Rebuilds are not recorded after the last event.
  void endRebuildCoverage() {
    if (!rebuildsRecorded) return;
    _coverage.last[1] = _nextSeq - 1;
  }

  /// The parts of the seq range [from] to [to] (both included) in which
  /// rebuilds were not recorded, oldest first.
  List<(int, int)> rebuildGaps(int from, int to) {
    if (to < from) return const <(int, int)>[];
    final gaps = <(int, int)>[];
    var cursor = from;
    for (final interval in _coverage) {
      final start = interval[0]!;
      final end = interval[1] ?? to;
      if (end < cursor) continue;
      if (start > to) break;
      if (start > cursor) gaps.add((cursor, start - 1));
      cursor = end + 1;
      if (cursor > to) break;
    }
    if (cursor <= to) gaps.add((cursor, to));
    return gaps;
  }

  /// Adds [micros] to the recorder's own time in this frame.
  void charge(int micros) => _selfMicros += micros;

  /// The recorder's own time since the last call, in microseconds.
  int takeSelfMicros() {
    final value = _selfMicros;
    _selfMicros = 0;
    return value;
  }

  /// Drops every event and the counters. The seq keeps counting: a seq is
  /// never reused.
  void clear() {
    for (var i = 0; i < maxEvents; i++) {
      _ring[i] = null;
    }
    _head = 0;
    _length = 0;
    _bytes = 0;
    _dropped = 0;
    _coverage.clear();
    _causes.clear();
  }
}

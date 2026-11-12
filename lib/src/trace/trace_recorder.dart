// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13), so
// the limits are tested without a widget tree.

import '../model/trace_event.dart';

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

  /// The newest event of [kind], or null.
  TraceEvent? lastOf(String kind) {
    for (final event in newestFirst) {
      if (event.kind == kind) return event;
    }
    return null;
  }

  /// Records one event. [data] must already be small JSON values (see
  /// [traceValues]); it is kept as given.
  TraceEvent add(
    String kind, {
    Map<String, Object?> data = const <String, Object?>{},
    String? widget,
    String? source,
    int? cause,
  }) {
    final event = TraceEvent(
      seq: _nextSeq++,
      t: _ms(),
      frame: frameOf(),
      kind: kind,
      cause: cause,
      widget: widget,
      source: source,
      data: data,
    );
    if (_length == maxEvents) _dropOldest();
    _ring[(_head + _length) % maxEvents] = event;
    _length++;
    _bytes += event.approxBytes;
    // Keep at least the new event, even when it alone is over the limit.
    while (_bytes > maxBytes && _length > 1) {
      _dropOldest();
    }
    return event;
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
  }
}

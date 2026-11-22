// Plain Dart: no `dart:ui` and no `package:flutter`.
// `why` and `caused_by`: the agent asks "why did this happen" and "what did
// this widget start".

import '../model/trace_event.dart';
import 'cause_zone.dart';
import 'pointer_phase.dart';
import 'trace_format.dart';
import 'trace_recorder.dart';

/// What the cause links can and cannot say, for the tool descriptions.
const String whyLimits =
    'A post-frame callback runs with the cause of the frame that calls it, '
    'which is right for a callback added during build of the same frame. '
    'A frame is linked to every cause that ran since the frame before it '
    '("near" links): one of them made it dirty, and why picks the one '
    'that set state, answered a request or took input. A timer or a stream '
    'keeps the cause of the moment it was made, for as long as it runs.';

/// Most frames `why` walks back.
const int maxWhyHops = 4;

/// `state`, `state.notify` and `state.setState`: a state change. (A watch's
/// `state` and the lens' kinds; `state.dropped` only counts.)
bool _isState(String kind) =>
    kind == TraceKind.state ||
    kind == TraceKind.stateNotify ||
    kind == TraceKind.stateSetState;

/// Kinds that say what a cause did, in a chain.
bool _notable(String kind) =>
    kind == TraceKind.build ||
    _isState(kind) ||
    kind == TraceKind.probe ||
    kind == TraceKind.route ||
    kind == TraceKind.error ||
    kind == TraceKind.finding ||
    kind == TraceKind.mark ||
    kind.startsWith('net.') ||
    TraceKind.isInput(kind);

/// How strongly an event of [kind] suggests that its cause made the next
/// frame dirty.
int _dirtyScore(String kind) {
  if (_isState(kind) ||
      kind == TraceKind.netResponse ||
      kind == TraceKind.netError ||
      TraceKind.isInput(kind)) {
    return 3;
  }
  if (kind == TraceKind.netRequest || kind == TraceKind.probe) return 2;
  if (kind == TraceKind.frame) return 0;
  return 1;
}

/// The `why` answer for the event [seq]: its cause, the entry of that cause,
/// and for a frame the cause that most likely made it dirty, walked back up
/// to [maxWhyHops] frames. Throws a [FormatException] when [seq] is not held.
Map<String, Object?> whyAnswer(TraceRecorder recorder, int seq) {
  final event = recorder.at(seq) ?? (throw _notHeld(recorder, seq));
  final walk = _WhyWalk(recorder)
    ..chain.add('event: ${traceLine(event, width: 160)}');
  final answer = <String, Object?>{'seq': seq, 'chain': walk.chain};
  final causeId = event.cause;
  if (causeId == null) {
    if (recorder.causeHint case final hint?) {
      answer['hint'] = hint;
    } else {
      walk.chain.add('no cause: it ran outside every entry (app start)');
    }
    return answer;
  }
  walk.follow(causeId, seq);
  return answer
    ..['loop'] = walk.loop
    ..addAll({
      if (walk.notes.isNotEmpty) 'notes': walk.notes.take(2).toList(),
      if (recorder.partial) 'partial': true,
      if (recorder.partial) 'reason': recorder.partialReason,
    });
}

FormatException _notHeld(TraceRecorder recorder, int seq) {
  final oldest = recorder.oldest?.seq;
  return FormatException(
    'seq $seq is not held'
    '${oldest == null ? '' : ' (held: $oldest-${recorder.nextSeq - 1})'}',
  );
}

/// The walk back from an event through the causes that led to it.
final class _WhyWalk {
  _WhyWalk(this.recorder);

  final TraceRecorder recorder;
  final List<String> chain = [];
  final List<String> notes = [];
  final Set<int> _seen = {};
  final List<String> _shapes = [];
  bool loop = false;

  /// Follows [causeId] back, one frame per hop, from the event at [seq].
  void follow(int causeId, int seq) {
    var current = (causeId: causeId, before: seq);
    for (var hop = 0; hop <= maxWhyHops; hop++) {
      if (!_seen.add(current.causeId)) return;
      final next = _hop(current.causeId, current.before);
      if (next == null) return;
      current = next;
    }
  }

  /// One hop. Null when the walk ends here, else the next cause to follow.
  ({int causeId, int before})? _hop(int causeId, int before) {
    final cause = recorder.causeOf(causeId);
    if (cause == null) {
      chain.add('cause c$causeId: not held any more');
      return null;
    }
    chain.add('cause ${_describe(recorder, cause)}');
    final did = _eventsOf(recorder, cause, before);
    for (final e in did.length <= 4 ? did : did.sublist(did.length - 4)) {
      chain.add('  ${traceLine(e, width: 160)}');
    }
    _noteGap(cause, before);
    if (cause.kind != CauseKind.frame) {
      chain.add(_entryLine(cause));
      return null;
    }
    if (_seenShapeBefore(did)) {
      loop = true;
      chain.add('  the same work as in the frame after it: a loop');
      return null;
    }
    final next = _dirtiedBy(recorder, cause);
    if (next == null) {
      chain.add(_noCauseLine(cause));
      return null;
    }
    chain.add(_madeDirtyLine(cause, next));
    return (causeId: next.id, before: cause.firstSeq ?? before);
  }

  void _noteGap(TraceCause cause, int before) {
    final first = cause.firstSeq;
    if (first == null) return;
    if (recorder.rebuildGaps(first, before).firstOrNull case (
      final a,
      final b,
    )) {
      notes.add(
        'rebuilds not recorded for seq $a-$b, so a build in c${cause.id} '
        'may be missing; call trace_detail({on: true}) and run it again',
      );
    }
  }

  String _entryLine(TraceCause cause) {
    final first = cause.firstSeq == null ? null : recorder.at(cause.firstSeq!);
    return first == null
        ? '  entry: ${cause.kind}'
        : '  entry: ${traceLine(first, width: 160)}';
  }

  /// Records the work of this frame and says whether the frame after it did
  /// the same work: a loop.
  bool _seenShapeBefore(List<TraceEvent> did) {
    final shape = [for (final e in did) traceFoldKey(e)].join('|');
    if (shape.isNotEmpty && _shapes.contains(shape)) return true;
    _shapes.add(shape);
    return false;
  }

  static String _noCauseLine(TraceCause frame) => frame.after.isEmpty
      ? '  no recorded cause ran since the frame before'
      : '  ran since the frame before: '
            '${[for (final id in frame.after) 'c$id'].join(', ')} '
            '(no events recorded)';

  static String _madeDirtyLine(TraceCause frame, TraceCause next) {
    final others = [
      for (final id in frame.after)
        if (id != next.id) 'c$id',
    ];
    return '  made dirty by c${next.id} (${next.kind})'
        '${others.isEmpty ? '' : '; also ran: ${others.join(', ')}'}';
  }
}

/// `c37 frame f233, started 0.4 s ago`.
String _describe(TraceRecorder recorder, TraceCause cause) {
  final first = cause.firstSeq == null ? null : recorder.at(cause.firstSeq!);
  final frame = cause.kind == CauseKind.frame && first != null
      ? ' f${first.frame}'
      : '';
  final t = cause.t;
  if (t == null) return 'c${cause.id} ${cause.kind}$frame';
  final age = recorder.now - t;
  // A periodic timer keeps its first cause forever. The age keeps a chain
  // that starts at app start from reading as "the first tap did it".
  final old = age > 60000 && cause.kind != CauseKind.frame
      ? ' (a timer or stream made then keeps the cause while it runs)'
      : '';
  return 'c${cause.id} ${cause.kind}$frame, started ${_ago(age)}$old';
}

String _ago(int ms) => ms < 60000
    ? '${(ms / 1000).toStringAsFixed(1)} s ago'
    : '${ms ~/ 60000} min ago';

/// The notable events of [cause] before [before], oldest first. Walks
/// back at most 2000 events.
List<TraceEvent> _eventsOf(
  TraceRecorder recorder,
  TraceCause cause,
  int before,
) {
  final out = <TraceEvent>[];
  final from = cause.firstSeq ?? before;
  for (var s = before - 1; s >= from && before - s <= 2000; s--) {
    final e = recorder.at(s);
    if (e == null) break;
    if (e.cause == cause.id && _notable(e.kind)) out.add(e);
  }
  return out.reversed.toList();
}

/// Of the causes a frame is linked to, the one that most likely made it
/// dirty: the one whose last events before the frame set state, answered
/// a request or took input. Ties go to the one that ran last.
TraceCause? _dirtiedBy(TraceRecorder recorder, TraceCause frame) {
  if (frame.after.isEmpty || frame.firstSeq == null) return null;
  final linked = frame.after.toSet();
  final best = <int, int>{};
  for (var s = frame.firstSeq! - 1; s > frame.firstSeq! - 500; s--) {
    final e = recorder.at(s);
    if (e == null) break;
    final c = e.cause;
    if (c == null || !linked.contains(c)) continue;
    final score = _dirtyScore(e.kind);
    if (score > (best[c] ?? -1)) best[c] = score;
  }
  TraceCause? pick;
  var top = -1;
  for (final id in frame.after) {
    final score = best[id];
    final cause = recorder.causeOf(id);
    if (score == null || cause == null) continue;
    if (score >= top) {
      top = score;
      pick = cause;
    }
  }
  return pick;
}

/// The `caused_by` answer: everything the subtree of a widget started, as
/// counts and the first few of each.
///
/// [sources] are the creation locations (`file:line:column`) of the local
/// widgets in the subtree. A cause counts when its input landed on one of
/// them (a tap) or one of them rebuilt in it (a frame), and a frame counts
/// when it followed such a tap. Work in a frame is shared by every widget
/// that rebuilt in it; the answer says so.
Map<String, Object?> causedByAnswer(
  TraceRecorder recorder, {
  required Set<String> sources,
  required String widget,
  TraceBound? since,
}) {
  final now = recorder.now;
  final (:fromSeq, :fromT) = _windowStartOf(
    since ?? const SecondsBound(10),
    recorder,
    now,
  );
  bool inWindow(TraceEvent e) =>
      (fromSeq == null || e.seq >= fromSeq) && (fromT == null || e.t >= fromT);

  final window = [
    for (final e in recorder.events)
      if (inWindow(e)) e,
  ];
  final scan = _scanSubtree(recorder, sources, inWindow);
  final work = _workOf(window, scan.roots);
  final timers = scan.roots.fold<int>(
    0,
    (sum, id) => sum + (recorder.causeOf(id)?.timers ?? 0),
  );
  final parts = [
    if (work.requests.isNotEmpty) '${work.requests.length} requests',
    if (scan.rebuilds > 0) '${scan.rebuilds} rebuilds',
    if (work.state.isNotEmpty) '${work.state.length} state changes',
    if (timers > 0) '$timers timers',
    if (work.errors.isNotEmpty) '${work.errors.length} errors',
  ];
  final windowText = fromT != null
      ? 'in the last ${((now - fromT) / 1000).toStringAsFixed(0)} s'
      : 'since seq $fromSeq';
  final notes = _causedByNotes(recorder, window, scan);
  return {
    'widget': widget,
    'summary': parts.isEmpty
        ? 'nothing recorded for $widget in the window'
        : '${parts.join(', ')} $windowText',
    'causes': scan.roots.length,
    'counts': {
      'requests': work.requests.length,
      'rebuilds': scan.rebuilds,
      'state': work.state.length,
      'timers': timers,
      'errors': work.errors.length,
      'taps': scan.taps,
    },
    'first': {
      if (work.requests.isNotEmpty) 'requests': _firstLines(work.requests),
      if (work.state.isNotEmpty) 'state': _firstLines(work.state),
      if (work.errors.isNotEmpty) 'errors': _firstLines(work.errors),
    },
    if (notes.isNotEmpty) 'notes': notes,
    if (recorder.partial) 'partial': true,
  };
}

/// Where the window of [bound] starts: at a seq, or at a recorder time.
({int? fromSeq, int? fromT}) _windowStartOf(
  TraceBound bound,
  TraceRecorder recorder,
  int now,
) => switch (bound) {
  SeqBound(:final seq) => (fromSeq: seq, fromT: null),
  SecondsBound(:final seconds) => (
    fromSeq: null,
    fromT: now - (seconds * 1000).round(),
  ),
  MarkBound() => (
    fromSeq: recorder.lastOf(TraceKind.mark)?.seq ?? recorder.nextSeq,
    fromT: null,
  ),
};

/// The causes that started work in the subtree: [roots], with the number of
/// [rebuilds] and [taps] inside the window.
({Set<int> roots, int rebuilds, int taps}) _scanSubtree(
  TraceRecorder recorder,
  Set<String> sources,
  bool Function(TraceEvent event) inWindow,
) {
  final roots = <int>{};
  final tapCauses = <int>{};
  var rebuilds = 0;
  var taps = 0;
  // Roots come from every event held: a request in the window may come
  // from a frame whose build was just before it.
  for (final e in recorder.events) {
    if (!sources.contains(e.source)) continue;
    if (inWindow(e)) {
      if (e.kind == TraceKind.build) {
        final n = e.data['n'];
        rebuilds += n is int ? n : 1;
      }
      if (e.kind == TraceKind.pointer && e.pointerPhase == PointerPhase.down) {
        taps++;
      }
    }
    final c = e.cause;
    if (c == null) continue;
    roots.add(c);
    if (TraceKind.isInput(e.kind)) tapCauses.add(c);
  }
  // A frame that followed a tap on the subtree is its work too.
  for (final cause in recorder.causes) {
    if (cause.kind == CauseKind.frame && cause.after.any(tapCauses.contains)) {
      roots.add(cause.id);
    }
  }
  return (roots: roots, rebuilds: rebuilds, taps: taps);
}

/// What the [roots] started inside [window].
({List<TraceEvent> requests, List<TraceEvent> state, List<TraceEvent> errors})
_workOf(List<TraceEvent> window, Set<int> roots) {
  final mine = [
    for (final e in window)
      if (e.cause != null && roots.contains(e.cause)) e,
  ];
  return (
    requests: [
      for (final e in mine)
        if (e.kind == TraceKind.netRequest) e,
    ],
    state: [
      for (final e in mine)
        if (e.kind == TraceKind.state) e,
    ],
    errors: [
      for (final e in mine)
        if (e.kind == TraceKind.error || e.kind == TraceKind.netError) e,
    ],
  );
}

List<String> _firstLines(List<TraceEvent> events) => [
  for (final e in events.take(3)) traceLine(e, width: 160),
];

List<String> _causedByNotes(
  TraceRecorder recorder,
  List<TraceEvent> window,
  ({Set<int> roots, int rebuilds, int taps}) scan,
) {
  final gaps = recorder.rebuildGaps(
    window.isEmpty ? recorder.nextSeq : window.first.seq,
    recorder.nextSeq - 1,
  );
  return [
    ?recorder.causeHint,
    if (scan.rebuilds == 0 && gaps.isNotEmpty)
      'rebuilds not recorded for part of the window; call '
          'trace_detail({on: true}) to record them',
    if (scan.roots.isNotEmpty)
      'a frame is shared: work in a frame where this subtree rebuilt '
          'counts here even if another widget started it',
  ];
}

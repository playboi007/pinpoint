// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13).
// `why` and `caused_by` of PLAN-v2 Milestone 14: the agent asks "why did
// this happen" and "what did this widget start".

import '../model/trace_event.dart';
import 'cause_zone.dart';
import 'trace_format.dart';
import 'trace_recorder.dart';

/// What the cause links can and cannot say, for the tool descriptions
/// (PLAN-v2 Milestone 14, step 10).
const String whyLimits =
    'A post-frame callback runs with the cause of the frame that calls it, '
    'which is right for a callback added during build of the same frame. '
    'A frame is linked to every cause that ran since the frame before it '
    '("near" links): one of them made it dirty, and why picks the one '
    'that set state, answered a request or took input. A timer or a stream '
    'keeps the cause of the moment it was made, for as long as it runs.';

/// Most frames `why` walks back.
const int maxWhyHops = 4;

/// Kinds that say what a cause did, in a chain.
bool _notable(String kind) =>
    kind == TraceKind.build ||
    kind == TraceKind.state ||
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
  if (kind == TraceKind.state ||
      kind == TraceKind.netResponse ||
      kind == TraceKind.netError ||
      TraceKind.isInput(kind)) {
    return 3;
  }
  if (kind == TraceKind.netRequest || kind == TraceKind.probe) return 2;
  if (kind == TraceKind.frame) return 0;
  return 1;
}

/// The `why` answer for the event [seq] (PLAN-v2 Milestone 14, tools):
/// its cause, the entry of that cause, and for a frame the cause that most
/// likely made it dirty, walked back up to [maxWhyHops] frames. Throws a
/// [FormatException] when [seq] is not held.
Map<String, Object?> whyAnswer(TraceRecorder recorder, int seq) {
  final event = recorder.at(seq);
  if (event == null) {
    final oldest = recorder.oldest?.seq;
    throw FormatException(
      'seq $seq is not held'
      '${oldest == null ? '' : ' (held: $oldest-${recorder.nextSeq - 1})'}',
    );
  }
  final chain = <String>['event: ${traceLine(event, width: 160)}'];
  final notes = <String>[];
  final answer = <String, Object?>{'seq': seq, 'chain': chain};
  final hint = recorder.causeHint;
  if (event.cause == null) {
    if (hint != null) {
      answer['hint'] = hint;
    } else {
      chain.add('no cause: it ran outside every entry (app start)');
    }
    return answer;
  }
  var causeId = event.cause!;
  var before = seq;
  final seen = <int>{};
  final shapes = <String>[];
  var loop = false;
  for (var hop = 0; hop <= maxWhyHops; hop++) {
    if (!seen.add(causeId)) break;
    final cause = recorder.causeOf(causeId);
    if (cause == null) {
      chain.add('cause c$causeId: not held any more');
      break;
    }
    chain.add('cause ${_describe(recorder, cause)}');
    final did = _eventsOf(recorder, cause, before);
    for (final e in did.length <= 4 ? did : did.sublist(did.length - 4)) {
      chain.add('  ${traceLine(e, width: 160)}');
    }
    if (cause.firstSeq != null) {
      for (final (a, b) in recorder.rebuildGaps(cause.firstSeq!, before)) {
        notes.add(
          'rebuilds not recorded for seq $a-$b, so a build in c${cause.id} '
          'may be missing; call trace_detail({on: true}) and run it again',
        );
        break;
      }
    }
    if (cause.kind != CauseKind.frame) {
      final first = cause.firstSeq == null
          ? null
          : recorder.at(cause.firstSeq!);
      chain.add(
        first == null
            ? '  entry: ${cause.kind}'
            : '  entry: ${traceLine(first, width: 160)}',
      );
      break;
    }
    // The same work in this frame as in the one after it: a loop.
    final shape = [for (final e in did) traceFoldKey(e)].join('|');
    if (shape.isNotEmpty && shapes.contains(shape)) {
      loop = true;
      chain.add('  the same work as in the frame after it: a loop');
      break;
    }
    shapes.add(shape);
    final next = _dirtiedBy(recorder, cause);
    if (next == null) {
      chain.add(
        cause.after.isEmpty
            ? '  no recorded cause ran since the frame before'
            : '  ran since the frame before: '
                  '${[for (final id in cause.after) 'c$id'].join(', ')} '
                  '(no events recorded)',
      );
      break;
    }
    final others = [
      for (final id in cause.after)
        if (id != next.id) 'c$id',
    ];
    chain.add(
      '  made dirty by c${next.id} (${next.kind})'
      '${others.isEmpty ? '' : '; also ran: ${others.join(', ')}'}',
    );
    causeId = next.id;
    before = cause.firstSeq ?? before;
  }
  answer['loop'] = loop;
  if (notes.isNotEmpty) answer['notes'] = notes.take(2).toList();
  if (recorder.partial) {
    answer['partial'] = true;
    answer['reason'] = recorder.partialReason;
  }
  return answer;
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
  // Watch out for: a periodic timer keeps its first cause forever. Show
  // the age, so a chain that starts at app start is not read as "the
  // first tap did it".
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

/// The `caused_by` answer (PLAN-v2 Milestone 14, tools): everything the
/// subtree of a widget started, as counts and the first few of each.
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
  int? fromSeq;
  int? fromT;
  switch (since ?? const SecondsBound(10)) {
    case SeqBound(:final seq):
      fromSeq = seq;
    case SecondsBound(:final seconds):
      fromT = now - (seconds * 1000).round();
    case MarkBound():
      fromSeq = recorder.lastOf(TraceKind.mark)?.seq ?? recorder.nextSeq;
  }
  bool inWindow(TraceEvent e) =>
      (fromSeq == null || e.seq >= fromSeq) && (fromT == null || e.t >= fromT);

  final window = [
    for (final e in recorder.events)
      if (inWindow(e)) e,
  ];
  final roots = <int>{};
  final taps = <int>{};
  var rebuilds = 0;
  var taps0 = 0;
  // Roots come from every event held: a request in the window may come
  // from a frame whose build was just before it.
  for (final e in recorder.events) {
    if (!sources.contains(e.source)) continue;
    if (inWindow(e)) {
      if (e.kind == TraceKind.build) {
        final n = e.data['n'];
        rebuilds += n is int ? n : 1;
      }
      if (e.kind == TraceKind.pointer && e.data['phase'] == 'down') taps0++;
    }
    final c = e.cause;
    if (c == null) continue;
    roots.add(c);
    if (TraceKind.isInput(e.kind)) taps.add(c);
  }
  // A frame that followed a tap on the subtree is its work too.
  for (final cause in recorder.causes) {
    if (cause.kind == CauseKind.frame && cause.after.any(taps.contains)) {
      roots.add(cause.id);
    }
  }
  final requests = <TraceEvent>[];
  final state = <TraceEvent>[];
  final errors = <TraceEvent>[];
  for (final e in window) {
    if (e.cause == null || !roots.contains(e.cause)) continue;
    switch (e.kind) {
      case TraceKind.netRequest:
        requests.add(e);
      case TraceKind.state:
        state.add(e);
      case TraceKind.error || TraceKind.netError:
        errors.add(e);
    }
  }
  var timers = 0;
  for (final id in roots) {
    timers += recorder.causeOf(id)?.timers ?? 0;
  }
  final counts = <String, Object?>{
    'requests': requests.length,
    'rebuilds': rebuilds,
    'state': state.length,
    'timers': timers,
    'errors': errors.length,
    'taps': taps0,
  };
  final parts = [
    if (requests.isNotEmpty) '${requests.length} requests',
    if (rebuilds > 0) '$rebuilds rebuilds',
    if (state.isNotEmpty) '${state.length} state changes',
    if (timers > 0) '$timers timers',
    if (errors.isNotEmpty) '${errors.length} errors',
  ];
  final windowText = fromT != null
      ? 'in the last ${((now - fromT) / 1000).toStringAsFixed(0)} s'
      : 'since seq $fromSeq';
  List<String> firstLines(List<TraceEvent> events) => [
    for (final e in events.take(3)) traceLine(e, width: 160),
  ];
  final notes = <String>[
    ?recorder.causeHint,
    if (rebuilds == 0 &&
        recorder
            .rebuildGaps(
              window.isEmpty ? recorder.nextSeq : window.first.seq,
              recorder.nextSeq - 1,
            )
            .isNotEmpty)
      'rebuilds not recorded for part of the window; call '
          'trace_detail({on: true}) to record them',
    if (roots.isNotEmpty)
      'a frame is shared: work in a frame where this subtree rebuilt '
          'counts here even if another widget started it',
  ];
  return {
    'widget': widget,
    'summary': parts.isEmpty
        ? 'nothing recorded for $widget in the window'
        : '${parts.join(', ')} $windowText',
    'causes': roots.length,
    'counts': counts,
    'first': {
      if (requests.isNotEmpty) 'requests': firstLines(requests),
      if (state.isNotEmpty) 'state': firstLines(state),
      if (errors.isNotEmpty) 'errors': firstLines(errors),
    },
    if (notes.isNotEmpty) 'notes': notes,
    if (recorder.partial) 'partial': true,
  };
}

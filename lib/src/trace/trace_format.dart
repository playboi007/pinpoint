// Plain Dart: no `dart:ui` and no `package:flutter`. The compact text an agent
// reads, and the `get_trace` query.

import '../model/annotation.dart' show clipText, traceNotRecorded;
import '../model/trace_event.dart';
import 'pointer_phase.dart';
import 'trace_recorder.dart';

/// `+3.21s`: [ms] since the run started.
String formatTraceTime(int ms) => '+${(ms / 1000).toStringAsFixed(2)}s';

/// `1.2 KB` for 1234 bytes.
String formatBytes(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// A URL without its scheme, and without the host when it is the page's
/// own: `/existing?type=faq`, `api.test/items`.
String shortUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !uri.hasScheme ||
      uri.scheme == 'data' ||
      uri.scheme == 'blob') {
    return url;
  }
  final path =
      '${uri.path.isEmpty ? '/' : uri.path}'
      '${uri.hasQuery ? '?${uri.query}' : ''}';
  final base = Uri.base;
  if (base.hasAuthority && uri.authority == base.authority) return path;
  return '${uri.authority}$path';
}

/// `home.dart:120` from `lib/screens/home.dart:120:12`.
String shortSource(String source) {
  final parts = source.split(':');
  // Drop the column, keep the line.
  final withoutColumn = parts.length >= 3 && int.tryParse(parts.last) != null
      ? parts.sublist(0, parts.length - 1).join(':')
      : source;
  final slash = withoutColumn.lastIndexOf('/');
  return slash < 0 ? withoutColumn : withoutColumn.substring(slash + 1);
}

/// `file`, `line` and `column` from a source such as
/// `lib/home.dart:120:12`, or null when it has no line.
({String file, int line, int? column})? parseTraceSource(String source) {
  final parts = source.split(':');
  if (parts.length < 2) return null;
  final last = int.tryParse(parts.last);
  final before = parts.length >= 3
      ? int.tryParse(parts[parts.length - 2])
      : null;
  if (last == null) return null;
  if (before != null) {
    return (
      file: parts.sublist(0, parts.length - 2).join(':'),
      line: before,
      column: last,
    );
  }
  return (
    file: parts.sublist(0, parts.length - 1).join(':'),
    line: last,
    column: null,
  );
}

/// What [event] says, after its kind: the part of a compact line that is
/// not seq, time or frame.
String traceSummary(TraceEvent event) {
  final d = event.data;
  final widget = event.widget;
  final where = _where(event);
  return switch (event.kind) {
    TraceKind.pointer => _pointerSummary(event),
    TraceKind.key => _keySummary(event),
    TraceKind.text => '${widget ?? 'field'} "${d['value'] ?? ''}"$where',
    TraceKind.frame => _frameSummary(d),
    TraceKind.build => _buildSummary(event),
    TraceKind.route => '${d['from'] ?? '(none)'} → ${d['to'] ?? '(none)'}',
    TraceKind.state => _stateSummary(event),
    TraceKind.stateNotify => _notifySummary(event),
    TraceKind.stateSetState => '${widget ?? '?'} setState${_method(d)}$where',
    TraceKind.stateDropped => '${d['n'] ?? '?'} setState stacks dropped (cap)',
    TraceKind.probe => '${d['name'] ?? '?'} ${_pairs(d['values'])}$where',
    TraceKind.error => _errorSummary(event),
    TraceKind.finding => '${d['kind'] ?? '?'}: ${d['summary'] ?? ''}',
    TraceKind.netRequest => _requestSummary(event),
    TraceKind.netResponse => _responseSummary(d),
    TraceKind.netError =>
      '${d['error'] ?? 'failed'} ${d['method'] ?? '?'} '
          '${shortUrl('${d['url'] ?? ''}')}${_reqText(d)}',
    TraceKind.message =>
      'from ${d['origin'] ?? '?'}${_sizeText(d)} ${d['data'] ?? ''}'
          .trimRight(),
    TraceKind.mark => _markSummary(d),
    TraceKind.detailOn => _detailSummary('level 3 on', d),
    TraceKind.detailOff => _detailSummary('level 3 off', d),
    _ => '${widget ?? ''}${_pairs(d)}$where'.trim(),
  };
}

String _where(TraceEvent event) {
  final source = event.source;
  return source == null ? '' : ' (${shortSource(source)})';
}

String _agentTag(TraceEvent event) => event.byAgent ? ' [agent]' : '';

String _method(Map<String, Object?> d) =>
    d['method'] is String ? ' in ${d['method']}' : '';

String _sizeText(Map<String, Object?> d) =>
    d['size'] is int ? ' ${formatBytes(d['size']! as int)}' : '';

String _reqText(Map<String, Object?> d) =>
    d['req'] is int ? ' (req ${d['req']})' : '';

String _pointerSummary(TraceEvent event) {
  final d = event.data;
  final phase = d['phase'] ?? '?';
  final widget = event.widget == null ? '' : ' ${event.widget}';
  final at = d['x'] is num && d['y'] is num ? ' at ${d['x']},${d['y']}' : '';
  final inside = d['fx'] is num && d['fy'] is num
      ? ' (${d['fx']}, ${d['fy']})'
      : '';
  final scroll = event.pointerPhase == PointerPhase.scroll
      ? ' dx=${d['dx']} dy=${d['dy']}'
      : '';
  return '$phase$widget$inside$scroll$at${_where(event)}${_agentTag(event)}';
}

String _keySummary(TraceEvent event) {
  final d = event.data;
  final char = d['char'] is String ? ' "${d['char']}"' : '';
  return '${d['phase'] ?? '?'} ${d['key'] ?? '?'}$char${_agentTag(event)}';
}

String _frameSummary(Map<String, Object?> d) {
  final builds = d['builds'] is int ? ' builds=${d['builds']}' : '';
  final self = d['us'] is int && (d['us']! as int) > 0
      ? ' rec=${((d['us']! as int) / 1000).toStringAsFixed(2)}ms'
      : '';
  final n = d['n'] is int ? ' ×${d['n']} from f${d['from']}' : '';
  return 'drawn$n$builds$self';
}

String _buildSummary(TraceEvent event) {
  final n = event.data['n'];
  return '${event.widget ?? '?'}${n is int && n > 1 ? ' n=$n' : ''}'
      '${_where(event)}';
}

String _stateSummary(TraceEvent event) {
  final d = event.data;
  final changed = d['changed'];
  final parts = <String>[
    if (changed is Map<String, Object?>)
      for (final MapEntry(:key, :value) in changed.entries)
        switch (value) {
          [final before, final after] => '$key: $before → $after',
          _ => '$key: $value',
        },
  ];
  final first = d['initial'] == true ? ' (first read)' : '';
  return '${d['state'] ?? event.widget ?? '?'}$first ${parts.join(', ')}';
}

String _notifySummary(TraceEvent event) {
  final d = event.data;
  final values = d.containsKey('after')
      ? ' ${d['before']} → ${d['after']}'
      : '';
  return '${d['owner'] ?? event.widget ?? '?'} ${d['tag'] ?? ''}'
      '$values${_method(d)}${_where(event)}';
}

String _errorSummary(TraceEvent event) {
  final d = event.data;
  final uncaught = d['uncaught'] == true ? ' (uncaught)' : '';
  return '${d['type'] ?? 'error'}$uncaught: ${d['message'] ?? ''}'
      '${_where(event)}';
}

String _requestSummary(TraceEvent event) {
  final d = event.data;
  return '${d['method'] ?? '?'} ${shortUrl('${d['url'] ?? ''}')}${_sizeText(d)}'
      '${_agentTag(event)}';
}

String _responseSummary(Map<String, Object?> d) {
  final cut = d['truncated'] == true ? ' (truncated)' : '';
  return '${d['status'] ?? '?'} ${d['method'] ?? '?'} '
      '${shortUrl('${d['url'] ?? ''}')} ${d['ms'] ?? '?'}ms${_sizeText(d)}$cut'
      '${_reqText(d)}';
}

String _markSummary(Map<String, Object?> d) {
  final text = d['text'];
  final by = d['by'] is String ? ' by ${d['by']}' : '';
  return '${text is String && text.isNotEmpty ? '"$text"' : '(no text)'}$by';
}

String _detailSummary(String label, Map<String, Object?> d) {
  final sources = d['sources'];
  final reason = d['reason'] is String ? '; ${d['reason']}' : '';
  return '$label${sources is List<Object?> ? ': ${sources.join(', ')}' : ''}'
      '$reason';
}

/// What makes two events "equal" for folding: the kind and the summary
/// without values that change on every event (positions, times).
String traceFoldKey(TraceEvent event) => switch (event.kind) {
  TraceKind.frame => 'frame ${event.data['builds'] ?? ''}',
  TraceKind.pointer when event.pointerPhase == PointerPhase.move =>
    'move ${event.widget ?? ''}',
  // A loop asks the same thing again: fold on method and URL, not on the
  // time it took or the request it answers.
  TraceKind.netRequest || TraceKind.netError =>
    '${event.kind} ${event.data['method']} '
        '${event.data['url']}',
  TraceKind.netResponse =>
    'net.response ${event.data['status']} '
        '${event.data['method']} ${event.data['url']} ${event.data['hash']}',
  _ => '${event.kind} ${traceSummary(event)}',
};

String _pairs(Object? values) {
  if (values is! Map<String, Object?>) return '';
  return [
    for (final MapEntry(:key, :value) in values.entries) '$key=$value',
  ].join(' ');
}

/// One compact line: `412  +3.21s  f233  c37  build  Counter
/// (counter.dart:12)`. The cause (`c37`) shows when there is one.
String traceLine(TraceEvent event, {int width = 200}) => clipText(
  '${event.seq}  ${formatTraceTime(event.t)}  f${event.frame}  '
  '${event.cause == null ? '' : 'c${event.cause}  '}'
  '${event.kind}  ${traceSummary(event)}',
  width,
);

/// [events] as compact lines, at most [limit] of them, each at most [width]
/// characters.
///
/// Equal lines in a row fold into one with `×n` and the seq range. A short
/// block of two to four lines that repeats folds too, which is what a loop
/// looks like: the block once, headed by `×n of:`.
///
/// When there are more lines than [limit], the newest are kept; [more]
/// counts the rest.
({List<String> lines, int more}) compactTrace(
  List<TraceEvent> events, {
  int limit = 50,
  int width = 200,
}) {
  final keys = [for (final e in events) traceFoldKey(e)];
  final lines = <String>[];
  var i = 0;
  while (i < events.length) {
    var period = 1;
    var reps = 1;
    for (var p = 1; p <= 4 && i + 2 * p <= events.length; p++) {
      var r = 1;
      while (i + (r + 1) * p <= events.length && _repeats(keys, i, p, r)) {
        r++;
      }
      if (r >= 2 && r * p > reps * period) {
        period = p;
        reps = r;
      }
    }
    final first = events[i];
    final last = events[i + period * reps - 1];
    if (reps == 1) {
      lines.add(traceLine(first, width: width));
    } else if (period == 1) {
      lines.add(
        clipText(
          '${first.seq}-${last.seq}  ${formatTraceTime(first.t)}  '
          'f${first.frame}-${last.frame}  ${first.kind}  '
          '${traceSummary(first)}  ×$reps',
          width,
        ),
      );
    } else {
      lines.add(
        clipText(
          '${first.seq}-${last.seq}  ${formatTraceTime(first.t)}  '
          'f${first.frame}-${last.frame}  ×$reps of:',
          width,
        ),
      );
      for (var j = 0; j < period; j++) {
        final e = events[i + j];
        lines.add(clipText('    ${e.kind}  ${traceSummary(e)}', width));
      }
    }
    i += period * reps;
  }
  if (lines.length <= limit) return (lines: lines, more: 0);
  return (
    lines: lines.sublist(lines.length - limit),
    more: lines.length - limit,
  );
}

/// Whether block `r` (of length [p], from [i]) equals the first block.
bool _repeats(List<String> keys, int i, int p, int r) {
  for (var j = 0; j < p; j++) {
    if (keys[i + r * p + j] != keys[i + j]) return false;
  }
  return true;
}

/// A `get_trace` request.
class TraceQuery {
  const TraceQuery({
    this.since,
    this.until,
    this.kinds = const <String>[],
    this.widget,
    this.cause,
    this.limit = 50,
    this.full = false,
  });

  /// Reads the tool's arguments. Throws a [FormatException] with a message
  /// for the agent on a bad value.
  factory TraceQuery.fromArgs(Map<String, Object?> args) {
    final kinds = args['kinds'];
    final limit = args['limit'];
    final cause = args['cause'];
    final widget = args['widget'];
    final detail = args['detail'];
    if (detail != null && detail != 'compact' && detail != 'full') {
      throw const FormatException('detail is compact or full');
    }
    return TraceQuery(
      since: TraceBound.parse(args['since'], 'since'),
      until: TraceBound.parse(args['until'], 'until'),
      kinds: switch (kinds) {
        null => const <String>[],
        final String one => [one],
        final List<Object?> list => [for (final k in list) '$k'],
        _ => throw const FormatException('kinds is a list of kinds'),
      },
      widget: widget is String && widget.isNotEmpty ? widget : null,
      cause: cause is int ? cause : null,
      limit: limit is num ? limit.round().clamp(1, 200) : 50,
      full: detail == 'full',
    );
  }

  final TraceBound? since;
  final TraceBound? until;

  /// Kinds or kind prefixes; empty: every kind except `frame`.
  final List<String> kinds;

  /// Part of a widget's type name, or of its source.
  final String? widget;
  final int? cause;

  /// Most lines (compact) or events (full).
  final int limit;

  /// Whole events as JSON instead of compact lines.
  final bool full;

  /// Whether [event] passes the kind, widget and cause filters.
  bool matches(TraceEvent event) {
    if (kinds.isEmpty) {
      // Frames are counted, not listed, unless asked for: a spinner draws
      // sixty a second.
      if (event.kind == TraceKind.frame) return false;
    } else if (!kinds.any((k) => TraceKind.matches(event.kind, k))) {
      return false;
    }
    final w = widget;
    if (w != null &&
        !(event.widget?.contains(w) ?? false) &&
        !(event.source?.contains(w) ?? false)) {
      return false;
    }
    if (cause != null && event.cause != cause) return false;
    return true;
  }

  /// Whether the answer can contain events that only level 3 records.
  bool get wantsDetail =>
      kinds.isEmpty ||
      kinds.any((k) => k == TraceKind.build || k == TraceKind.state);
}

/// One end of a `get_trace` window: a seq, seconds back from now, or the
/// last mark.
sealed class TraceBound {
  const TraceBound();

  /// `412` (a seq), `"30s"` (seconds back) or `"mark"` (the last mark).
  /// Null for null.
  static TraceBound? parse(Object? value, String name) {
    switch (value) {
      case null:
        return null;
      case final int seq:
        return SeqBound(seq);
      case final num seq:
        return SeqBound(seq.round());
      case 'mark':
        return const MarkBound();
      case final String text:
        final seconds = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(text.trim());
        if (seconds != null) {
          return SecondsBound(double.parse(seconds[1]!));
        }
        final seq = int.tryParse(text.trim());
        if (seq != null) return SeqBound(seq);
    }
    throw FormatException(
      '$name takes a seq (412), seconds back ("30s") or "mark"',
    );
  }
}

class SeqBound extends TraceBound {
  const SeqBound(this.seq);
  final int seq;
}

class SecondsBound extends TraceBound {
  const SecondsBound(this.seconds);
  final double seconds;
}

class MarkBound extends TraceBound {
  const MarkBound();
}

/// The `get_trace` answer for [query] over [recorder].
///
/// Says `partial: true` with the reason when a limit dropped events from
/// the window, and adds a note for each part of the window where rebuilds
/// were not recorded, so a missing `build` is never read as "no rebuild".
Map<String, Object?> traceAnswer(TraceRecorder recorder, TraceQuery query) {
  final window = _Window(
    _cutOf(query.since, recorder),
    _cutOf(query.until, recorder),
  );
  final (inWindow, frames) = _eventsIn(recorder, query, window);

  final oldest = recorder.oldest?.seq ?? recorder.nextSeq;
  final windowStart = _windowStart(recorder, window, inWindow);
  final windowEnd = window.until.seq ?? (recorder.nextSeq - 1);
  // The window reaches back before the oldest event held.
  final partial = recorder.partial && windowStart < oldest;
  final notes = query.wantsDetail
      ? _rebuildNotes(
          recorder,
          windowStart < oldest ? oldest : windowStart,
          windowEnd,
        )
      : const <String>[];

  return {
    'matched': inWindow.length,
    'frames': frames,
    'partial': partial,
    if (partial) 'reason': recorder.partialReason,
    if (notes.isNotEmpty) 'notes': notes,
    // Said once per answer, not per event.
    'hint': ?recorder.causeHint,
    ...query.full
        ? _fullListing(inWindow, query.limit)
        : _compactListing(inWindow, query.limit),
  };
}

/// Where one end of a window cuts: at a seq, or at a recorder time.
typedef _Cut = ({int? seq, int? t});

_Cut _cutOf(TraceBound? bound, TraceRecorder recorder) => switch (bound) {
  null => (seq: null, t: null),
  SeqBound(:final seq) => (seq: seq, t: null),
  SecondsBound(:final seconds) => (
    seq: null,
    t: recorder.now - (seconds * 1000).round(),
  ),
  MarkBound() => (seq: _lastMarkSeq(recorder), t: null),
};

int _lastMarkSeq(TraceRecorder recorder) {
  final mark = recorder.lastOf(TraceKind.mark);
  if (mark == null) {
    throw const FormatException('no mark yet; make one with mark');
  }
  return mark.seq;
}

/// The two ends of a `get_trace` window.
final class _Window {
  const _Window(this.since, this.until);

  final _Cut since;
  final _Cut until;

  bool contains(TraceEvent event) {
    final (fromSeq, fromT) = (since.seq, since.t);
    final (toSeq, toT) = (until.seq, until.t);
    return (fromSeq == null || event.seq >= fromSeq) &&
        (toSeq == null || event.seq <= toSeq) &&
        (fromT == null || event.t >= fromT) &&
        (toT == null || event.t <= toT);
  }
}

/// The events of [window] that [query] matches, and how many frames the
/// window covers (a folded frame event counts every frame it covers).
(List<TraceEvent>, int) _eventsIn(
  TraceRecorder recorder,
  TraceQuery query,
  _Window window,
) {
  final matched = <TraceEvent>[];
  var frames = 0;
  for (final event in recorder.events.where(window.contains)) {
    if (event.kind == TraceKind.frame) {
      frames += event.data['n'] is int ? event.data['n']! as int : 1;
    }
    if (query.matches(event)) matched.add(event);
  }
  return (matched, frames);
}

int _windowStart(
  TraceRecorder recorder,
  _Window window,
  List<TraceEvent> inWindow,
) {
  if (window.since.seq case final seq?) return seq;
  if (window.since.t == null) return 1;
  return inWindow.isEmpty ? recorder.nextSeq : inWindow.first.seq;
}

List<String> _rebuildNotes(TraceRecorder recorder, int from, int to) => [
  for (final (a, b) in recorder.rebuildGaps(from, to).take(5))
    'rebuilds not recorded for seq $a-$b (level 3 was off); '
        'call trace_detail({on: true}) to record them',
];

Map<String, Object?> _fullListing(List<TraceEvent> inWindow, int limit) {
  final shown = inWindow.length <= limit
      ? inWindow
      : inWindow.sublist(inWindow.length - limit);
  return {
    'events': [for (final e in shown) e.toJson()],
    if (shown.length < inWindow.length)
      'more':
          '${inWindow.length - shown.length} earlier events left out; '
          'narrow with since, until or kinds',
  };
}

Map<String, Object?> _compactListing(List<TraceEvent> inWindow, int limit) {
  final compact = compactTrace(inWindow, limit: limit);
  return {
    'lines': compact.lines.join('\n'),
    if (compact.more > 0)
      'more':
          '${compact.more} earlier lines left out; narrow with since, '
          'until or kinds',
  };
}

/// The `trace` of a note: the events in the
/// [seconds] before [end] (recorder time, in ms), at most [maxLines]
/// compact lines. Null when nothing in the window is kept.
///
/// `build` and `state` events are kept only for widgets created at one of
/// the [subtree] sources (`file:line:column`). When level 3 was off for the
/// whole window, only inputs, routes and errors are kept and the first
/// line says [traceNotRecorded]. When it was off for part of the window,
/// the first line names that part.
Map<String, Object?>? noteTrace(
  TraceRecorder recorder, {
  required int end,
  required Set<String> subtree,
  int seconds = 10,
  int maxLines = 60,
}) {
  final start = end - seconds * 1000;
  final window = <TraceEvent>[
    for (final e in recorder.events)
      if (e.t >= start && e.t <= end) e,
  ];
  if (window.isEmpty) return null;
  final first = window.first.seq;
  final last = window.last.seq;
  final gaps = recorder.rebuildGaps(first, last);
  final off = gaps.length == 1 && gaps.single == (first, last);
  bool keep(TraceEvent e) {
    if (TraceKind.isInput(e.kind) ||
        e.kind == TraceKind.route ||
        e.kind == TraceKind.error) {
      return true;
    }
    if (off) return false;
    return switch (e.kind) {
      TraceKind.build || TraceKind.state => subtree.contains(e.source),
      TraceKind.probe || TraceKind.finding || TraceKind.mark => true,
      _ => false,
    };
  }

  final kept = [
    for (final e in window)
      if (keep(e)) e,
  ];
  if (kept.isEmpty) return null;
  final oldest = recorder.oldest;
  final partial = recorder.partial && oldest != null && oldest.t > start;
  final head = gaps.isEmpty
      ? null
      : off
      ? traceNotRecorded
      : '$traceNotRecorded for seq '
            '${[for (final (a, b) in gaps.take(3)) '$a-$b'].join(', ')}';
  return {
    'seconds': seconds,
    'rebuilds': gaps.isEmpty,
    'lines': [
      ?head,
      ...compactTrace(
        kept,
        limit: head == null ? maxLines : maxLines - 1,
      ).lines,
    ],
    if (partial) 'partial': true,
    if (partial) 'reason': recorder.partialReason,
  };
}

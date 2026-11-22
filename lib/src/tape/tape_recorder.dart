// Plain Dart: no `dart:ui` and no `package:flutter`. The
// Flutter side gives it a [TapeStart] for the page; everything else is
// read from the recorder's events and the network tap.

import 'dart:collection';
import 'dart:typed_data';

import '../model/tape.dart';
import '../model/trace_event.dart';
import '../trace/net_record.dart';
import '../trace/trace_recorder.dart';
import 'net_matcher.dart';

part 'tape_since.dart';

/// One request the tape recorder follows.
class _Exchange {
  _Exchange(this.call, this.key);

  final NetCall call;
  final String key;
  Uint8List? body;
  bool ended = false;
}

/// Keeps the inputs and network exchanges of the run since app start, in
/// its own store apart from the ring buffer: a full tape needs the first
/// minute even when the bug was in the tenth.
///
/// Bounded twice: [maxInputs] and [maxExchanges] by count, the
/// bodies by [maxBodyBytes]. Over a limit the oldest go, and from then on
/// a tape from app start can only be a partial segment that starts after
/// what was lost ("tape starts 3 min ago").
///
/// Nothing is written to disk here: a tape exists in memory until
/// the user or the agent saves it.
class TapeRecorder implements NetTap {
  TapeRecorder(
    this.recorder, {
    this.matcher = const NetMatcher(),
    this.maxBodyBytes = defaultMaxBodyBytes,
    this.maxInputs = 10000,
    this.maxExchanges = 5000,
    this.bodiesRead = true,
    this.appStart,
  });

  static const int defaultMaxBodyBytes = 20 * 1024 * 1024;

  final TraceRecorder recorder;
  final NetMatcher matcher;
  final int maxBodyBytes;
  final int maxInputs;
  final int maxExchanges;

  /// `TraceConfig.bodies`. False: no full tapes, and no answers to serve.
  final bool bodiesRead;

  /// The page at app start, for a full tape. Null: no full tape.
  TapeStart? appStart;

  final ListQueue<TraceEvent> _inputs = ListQueue<TraceEvent>();
  final ListQueue<TraceEvent> _marks = ListQueue<TraceEvent>();
  final ListQueue<TraceEvent> _routes = ListQueue<TraceEvent>();
  final LinkedHashMap<int, _Exchange> _net = LinkedHashMap<int, _Exchange>();
  final Map<NetCall, _Exchange> _byCall = Map<NetCall, _Exchange>.identity();
  int _bodyBytes = 0;

  /// Seqs before this one are not complete in the store; null when the
  /// store has everything since app start.
  int? _lostBefore;
  int? _lostAtT;
  String? _lostReason;

  bool _replaying = false;

  bool _started = false;

  /// Starts following the recorder.
  void start() {
    if (_started) return;
    _started = true;
    recorder.addListener(_onEvent);
  }

  /// Stops following it. The store stays until [clear].
  void stop() {
    if (!_started) return;
    _started = false;
    recorder.removeListener(_onEvent);
  }

  /// While a replay runs, nothing goes into the store: its inputs are the
  /// tape's, its answers came from the tape. When it ends, a tape can only
  /// start after it.
  bool get replaying => _replaying;
  set replaying(bool value) {
    if (value == _replaying) return;
    _replaying = value;
    if (!value) _lose('a replay ran before it');
  }

  /// The recorder's time now, in ms.
  int get now => recorder.now;

  /// The earliest time a tape can start at: app start, or later when
  /// something was dropped.
  int get earliestT => _lostAtT ?? appStart?.t ?? 0;

  /// The inputs held, oldest first, for the range picker's track.
  Iterable<TraceEvent> get inputs => _inputs;

  /// The marks held, oldest first.
  Iterable<TraceEvent> get marks => _marks;

  /// The route changes held, oldest first.
  Iterable<TraceEvent> get routes => _routes;

  /// The times of the requests held.
  Iterable<int> get requestTimes => _net.values.map((e) => e.call.request.t);

  /// Bytes of the bodies held.
  int get bodyBytes => _bodyBytes;

  /// About how large a tape from app start would be, for the comment
  /// form's "Attach what happened (1.2 MB)".
  int get estimatedBytes =>
      _bodyBytes + 200 * _inputs.length + 300 * _net.length + 1000;

  /// Whether a tape from app start can be full now.
  bool get canSaveFull => bodiesRead && _lostBefore == null && appStart != null;

  /// How many seconds back a tape can reach when [canSaveFull] is false
  /// because something was dropped, or null.
  int? get startsAgo {
    final t = _lostAtT;
    if (t == null) return null;
    return ((recorder.now - t) / 1000).round();
  }

  void _onEvent(TraceEvent event) {
    if (_replaying) return;
    final kind = event.kind;
    if (TraceKind.isInput(kind)) {
      // A tape replays the user, not the agent's or the player's own input.
      if (event.byAgent) return;
      _inputs.add(event);
      if (_inputs.length > maxInputs) {
        final old = _inputs.removeFirst();
        _lose('more than $maxInputs inputs', after: old);
      }
    } else if (kind == TraceKind.mark) {
      _marks.add(event);
      if (_marks.length > 200) _marks.removeFirst();
    } else if (kind == TraceKind.route) {
      _routes.add(event);
      if (_routes.length > 500) _routes.removeFirst();
    }
  }

  void _lose(String reason, {TraceEvent? after}) {
    final seq = after == null ? recorder.nextSeq : after.seq + 1;
    if (_lostBefore == null || seq > _lostBefore!) {
      _lostBefore = seq;
      _lostAtT = after?.t ?? recorder.now;
      _lostReason = reason;
    }
  }

  // ---- NetTap ----

  @override
  void requested(NetCall call, String url, List<int>? body) {
    if (_replaying) return;
    final exchange = _Exchange(call, matcher.key(call.method, url, body));
    _net[call.request.seq] = exchange;
    _byCall[call] = exchange;
    if (_net.length > maxExchanges) {
      final old = _net.remove(_net.keys.first)!;
      _byCall.remove(old.call);
      _dropBody(old);
      _lose(
        'more than $maxExchanges requests',
        after: old.call.response ?? old.call.request,
      );
    }
  }

  @override
  void answered(NetCall call) {}

  @override
  void ended(NetCall call, Uint8List? body) {
    final exchange = _byCall.remove(call);
    if (exchange == null) return;
    exchange.ended = true;
    if (body == null) return;
    exchange.body = body;
    _bodyBytes += body.length;
    // Over the limit the oldest bodies go: a tape from app start can no
    // longer serve them, so it starts after them.
    while (_bodyBytes > maxBodyBytes) {
      _Exchange? oldest;
      for (final e in _net.values) {
        if (e.body != null) {
          oldest = e;
          break;
        }
      }
      if (oldest == null) break;
      _dropBody(oldest);
      // The app has seen the answer, so the tape starts after it.
      _lose(
        'bodies over ${_mb(maxBodyBytes)}',
        after: oldest.call.response ?? oldest.call.request,
      );
    }
  }

  @override
  void failed(NetCall call) {
    _byCall.remove(call)?.ended = true;
  }

  void _dropBody(_Exchange exchange) {
    final body = exchange.body;
    if (body == null) return;
    _bodyBytes -= body.length;
    exchange.body = null;
  }

  /// Drops every store at once ("Clear recording"): for the moment the
  /// user typed something they do not want kept.
  void clear() {
    _inputs.clear();
    _marks.clear();
    _routes.clear();
    _net.clear();
    _byCall.clear();
    _bodyBytes = 0;
    _lostBefore = recorder.nextSeq;
    _lostAtT = recorder.now;
    _lostReason = 'the recording was cleared';
  }

  /// A tape of the run from [since]. [startAt] describes the page now, for
  /// a segment. Throws a [FormatException] when [since] names a mark that
  /// is not held.
  Tape save({
    required TapeSince since,
    required TapeStart Function({required int t, required int seq}) startAt,
    String? id,
    String? name,
    int? untilT,
  }) {
    final range = _clampToKept(_rangeStart(since));
    final full = since is _SinceStart && canSaveFull;
    final start = full ? appStart! : startAt(t: range.t, seq: range.seq);

    // [untilT]: the end of the range. Inputs, requests, marks and routes
    // after it are left out; an answer to a request made before it is kept,
    // whenever it came.
    bool inRange(TraceEvent e) =>
        e.seq >= range.seq && (untilT == null || e.t <= untilT);
    final exchanges = _exchangesIn(inRange);
    return Tape(
      id: id ?? newTapeId(),
      name: name,
      kind: full ? TapeKind.full : TapeKind.segment,
      start: start,
      inputs: _tapeInputs(inRange, exchanges.net),
      net: exchanges.net,
      marks: [
        for (final m in _marks)
          if (inRange(m))
            TapeMark(
              seq: m.seq,
              t: m.t,
              text: '${m.data['text'] ?? ''}',
              by: '${m.data['by'] ?? 'user'}',
            ),
      ],
      routes: [
        for (final r in _routes)
          if (inRange(r) && r.data['to'] is String) r.data['to']! as String,
      ],
      partial: range.partial,
      partialReason: range.reason,
      bodiesRead: bodiesRead,
      bodies: exchanges.bodies,
    );
  }

  /// Where [since] starts: the first seq and the run time (ms) of the tape.
  ({int seq, int t}) _rangeStart(TapeSince since) => switch (since) {
    _SinceStart() => (seq: 1, t: 0),
    SinceMark(:final index) => _markStart(index),
    SinceTime(:final t) => _timeStart(t),
    SinceSeconds(:final seconds) => _timeStart(
      recorder.now - (seconds * 1000).round(),
    ),
  };

  ({int seq, int t}) _timeStart(int t) {
    final startT = t < 0 ? 0 : t;
    return (seq: _firstSeqFrom(startT), t: startT);
  }

  ({int seq, int t}) _markStart(int? index) {
    final marks = _marks.toList();
    final mark = switch (index) {
      null => marks.lastOrNull,
      _ when index <= marks.length => marks[index - 1],
      _ => null,
    };
    if (mark == null) {
      throw FormatException(
        index == null
            ? 'no mark yet; make one with mark'
            : 'there are ${marks.length} marks; mark:$index is not one',
      );
    }
    return (seq: mark.seq, t: mark.t);
  }

  /// [start] moved forward to the first event still held, with the reason
  /// when something before it was lost.
  ({int seq, int t, bool partial, String? reason}) _clampToKept(
    ({int seq, int t}) start,
  ) {
    final lost = _lostBefore;
    if (lost == null || start.seq >= lost) {
      return (seq: start.seq, t: start.t, partial: false, reason: null);
    }
    final ago = startsAgo;
    return (
      seq: lost,
      t: _lostAtT ?? start.t,
      partial: true,
      reason:
          '$_lostReason: the tape starts '
          '${ago == null ? 'later' : _ago(ago)} ago',
    );
  }

  /// The requests of the range as tape exchanges, and their bodies by
  /// exchange number.
  ({List<NetExchange> net, Map<int, Uint8List> bodies}) _exchangesIn(
    bool Function(TraceEvent event) inRange,
  ) {
    final net = <NetExchange>[];
    final bodies = <int, Uint8List>{};
    final counts = <String, int>{};
    for (final exchange in _net.values) {
      if (!inRange(exchange.call.request)) continue;
      final n = net.length;
      final nth = counts[exchange.key] = (counts[exchange.key] ?? 0) + 1;
      net.add(_netExchange(exchange, n, nth));
      if (exchange.body case final body?) bodies[n] = body;
    }
    return (net: net, bodies: bodies);
  }

  NetExchange _netExchange(_Exchange exchange, int n, int nth) {
    final call = exchange.call;
    final response = call.response;
    final error = call.error;
    final headers = response?.data['headers'];
    return NetExchange(
      n: n,
      key: exchange.key,
      nth: nth,
      method: call.method,
      url: call.url,
      t: call.request.t,
      status: response?.data['status'] as int?,
      headers: headers is Map<String, Object?>
          ? {for (final e in headers.entries) e.key: '${e.value}'}
          : const <String, String>{},
      ms: response?.data['ms'] as int? ?? error?.data['ms'] as int?,
      hash: response?.data['hash'] as String?,
      size: response?.data['size'] as int?,
      error: error?.data['error'] as String?,
      unsupported: _unsupportedReason(exchange),
      answeredSeq: (response ?? error)?.seq,
    );
  }

  /// Why the answer cannot be served from the tape, or null when it can.
  String? _unsupportedReason(_Exchange exchange) {
    final answered = exchange.call.response != null;
    if (!answered || exchange.body != null || !bodiesRead) return null;
    return exchange.call.notKept ??
        (exchange.ended ? 'body not kept' : 'answer still loading');
  }

  List<TapeInput> _tapeInputs(
    bool Function(TraceEvent event) inRange,
    List<NetExchange> net,
  ) => [
    for (final (i, e) in _inputs.where(inRange).indexed)
      TapeInput(
        step: i + 1,
        seq: e.seq,
        t: e.t,
        frame: e.frame,
        kind: e.kind,
        widget: e.widget,
        source: e.source,
        data: Map<String, Object?>.of(e.data),
        after: answeredBefore(e.seq, net),
      ),
  ];

  /// The first seq at or after [t], in the ring buffer or the store (the
  /// ring buffer may have dropped what the store still has).
  int _firstSeqFrom(int t) {
    var best = recorder.nextSeq;
    for (final e in recorder.events) {
      if (e.t >= t) {
        best = e.seq;
        break;
      }
    }
    for (final e in [..._inputs, ..._marks]) {
      if (e.t >= t && e.seq < best) best = e.seq;
    }
    for (final e in _net.values) {
      final r = e.call.request;
      if (r.t >= t && r.seq < best) best = r.seq;
    }
    return best;
  }

  static String _mb(int bytes) => bytes >= 1024 * 1024
      ? '${bytes ~/ (1024 * 1024)} MB'
      : '${bytes ~/ 1024} KB (TapeRecorder.maxBodyBytes)';

  static String _ago(int seconds) =>
      seconds < 90 ? '$seconds s' : '${(seconds / 60).round()} min';
}

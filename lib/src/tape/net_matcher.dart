// Plain Dart: no `dart:ui` and no `package:flutter`. The request key and the
// nth answer.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../model/tape.dart';
import '../trace/net_record.dart' show NetHash;
import '../trace/redact.dart';

/// Turns a request into its key: method, URL without the parameters in
/// [redact] or [ignore], and the hash of the body without the fields in
/// [ignore].
///
/// The key is exact on purpose. A request that carries a time or a random
/// id never matches by body hash: name the field in
/// `TraceConfig.matchIgnore` instead of making the matcher fuzzy.
class NetMatcher {
  const NetMatcher({
    this.redact = const TraceRedact(),
    this.ignore = const <String>[],
  });

  /// Parameters whose values are masked are left out of the key: a token
  /// that was fresh when recorded is another value at replay.
  final TraceRedact redact;

  /// Body fields (at any depth of a JSON body) and URL parameters left out
  /// of the key (`TraceConfig.matchIgnore`). Names match exactly.
  final List<String> ignore;

  /// The key of a request. [body] is its bytes, or null when it has none
  /// or they are not known (a stream, a form).
  String key(String method, String url, List<int>? body) =>
      '${method.toUpperCase()} ${_url(url)} ${_body(body)}';

  String _url(String url) {
    var head = url;
    final hash = head.indexOf('#');
    if (hash >= 0) head = head.substring(0, hash);
    final mark = head.indexOf('?');
    if (mark < 0) return head;
    final query = head.substring(mark + 1);
    head = head.substring(0, mark);
    final kept = [
      for (final pair in query.split('&'))
        if (pair.isNotEmpty && !_leaves(_name(pair))) pair,
    ];
    return kept.isEmpty ? head : '$head?${kept.join('&')}';
  }

  static String _name(String pair) {
    final eq = pair.indexOf('=');
    final raw = eq < 0 ? pair : pair.substring(0, eq);
    try {
      return Uri.decodeQueryComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  bool _leaves(String name) => ignore.contains(name) || redact.masks(name);

  String _body(List<int>? body) {
    if (body == null || body.isEmpty) return '-';
    if (ignore.isNotEmpty || _looksJson(body)) {
      try {
        final decoded = jsonDecode(utf8.decode(body));
        if (decoded is Map || decoded is List) {
          // Sorted keys: the same object in another key order is the same
          // request.
          return '#${NetHash.of(utf8.encode(jsonEncode(_canonical(decoded))))}';
        }
      } on FormatException {
        // Not JSON: the raw bytes count.
      }
    }
    return '#${NetHash.of(body)}';
  }

  static bool _looksJson(List<int> body) {
    for (final b in body) {
      if (b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09) continue;
      return b == 0x7B || b == 0x5B; // { or [
    }
    return false;
  }

  Object? _canonical(Object? value) => switch (value) {
    final Map<Object?, Object?> map => {
      for (final key in (map.keys.map((k) => '$k').toList()..sort()))
        if (!ignore.contains(key)) key: _canonical(map[key]),
    },
    final List<Object?> list => [for (final item in list) _canonical(item)],
    _ => value,
  };
}

/// What a request with no answer in the tape does.
enum Unmatched {
  /// A clear error and a `replay.unmatched` event. The default for the
  /// first replay of a tape: no request reaches a server.
  fail,

  /// The request goes to the real server. The default when verifying a
  /// fix, because a fix may change what the app asks for.
  passthrough,

  /// The last answer the tape has for the key; a key the tape never saw
  /// fails.
  last;

  static Unmatched? byName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// How long a served answer takes.
class ReplayLatency {
  /// The latency the tape recorded, divided by the replay speed.
  const ReplayLatency.recorded() : ms = null, instant = false;

  /// No wait: the answer comes in the next turn of the event loop.
  const ReplayLatency.instant() : ms = 0, instant = true;

  /// Every answer takes [ms].
  const ReplayLatency.fixed(int this.ms) : instant = false;

  /// `recorded`, `instant`, or a number of milliseconds.
  static ReplayLatency? parse(Object? value) => switch (value) {
    null || 'recorded' => const ReplayLatency.recorded(),
    'instant' => const ReplayLatency.instant(),
    final num ms when ms >= 0 => ReplayLatency.fixed(ms.round()),
    _ => null,
  };

  final int? ms;
  final bool instant;

  @override
  String toString() => instant
      ? 'instant'
      : ms == null
      ? 'recorded'
      : '$ms ms';
}

/// What the network source does with one request during a replay.
sealed class NetAnswer {
  const NetAnswer();
}

/// Answer from the tape: [exchange]'s status, headers and [body], after
/// [delay].
class ServeAnswer extends NetAnswer {
  const ServeAnswer(this.exchange, this.body, this.delay);

  final NetExchange exchange;
  final Uint8List body;
  final Duration delay;
}

/// Fail the request with [reason]. [taped]: the request failed the same
/// way when it was recorded; otherwise the tape had no answer for it.
class FailAnswer extends NetAnswer {
  const FailAnswer(this.reason, {this.taped = false, this.exchange});

  final String reason;
  final bool taped;
  final NetExchange? exchange;
}

/// Let the request reach the real server. [exchange] is the one it stands
/// for in the tape, when there is one: its arrival counts for `after`.
class PassAnswer extends NetAnswer {
  const PassAnswer([this.exchange]);

  final NetExchange? exchange;
}

/// The network side of a replay: answers requests from a tape in order
/// and keeps what the inputs wait for.
class NetReplay {
  NetReplay(
    this.tape, {
    this.matcher = const NetMatcher(),
    this.unmatched = Unmatched.fail,
    this.latency = const ReplayLatency.recorded(),
    this.speed = 1,
  }) : assert(speed > 0) {
    for (final exchange in tape.net) {
      (_byKey[exchange.key] ??= <NetExchange>[]).add(exchange);
    }
  }

  final Tape tape;
  final NetMatcher matcher;
  final Unmatched unmatched;
  final ReplayLatency latency;
  final double speed;

  final Map<String, List<NetExchange>> _byKey = <String, List<NetExchange>>{};
  final Map<String, int> _used = <String, int>{};

  /// The key of every request asked for, in order: compared with the
  /// tape's for `first_difference`.
  final List<String> asked = <String>[];

  /// Requests the tape had no answer for, as `METHOD url`.
  final List<String> unmatchedRequests = <String>[];

  /// Order numbers delivered again.
  final Set<int> _delivered = <int>{};
  final List<(Set<int>, Completer<bool>)> _waits =
      <(Set<int>, Completer<bool>)>[];

  /// The answer for one request. [body] is the request body when known.
  NetAnswer answer({
    required String method,
    required String url,
    List<int>? body,
  }) {
    final key = matcher.key(method, url, body);
    asked.add(key);
    final list = _byKey[key];
    final used = _used[key] ?? 0;
    NetExchange? exchange;
    if (list != null && used < list.length) {
      exchange = list[used];
      _used[key] = used + 1;
    }
    if (exchange == null) {
      final where = '${method.toUpperCase()} $url';
      switch (unmatched) {
        case Unmatched.passthrough:
          unmatchedRequests.add(where);
          return const PassAnswer();
        case Unmatched.last when list != null && list.isNotEmpty:
          exchange = list.last;
        case Unmatched.fail:
        case Unmatched.last:
          unmatchedRequests.add(where);
          return FailAnswer(
            'pinpoint replay: no answer in the tape for $where '
            '(${list == null ? 'the tape never made this request' : 'the tape '
                      'made it ${list.length} times'}); replay with '
            'unmatched: passthrough to reach the server',
          );
      }
    }
    if (exchange.unsupported != null) return PassAnswer(exchange);
    if (exchange.error != null) {
      return FailAnswer(exchange.error!, taped: true, exchange: exchange);
    }
    final bytes = tape.bodies[exchange.n];
    if (exchange.status == null || (bytes == null && exchange.size != 0)) {
      // The tape knows the request but not its answer (bodies off, or the
      // body was not kept): the server answers.
      return PassAnswer(exchange);
    }
    return ServeAnswer(exchange, bytes ?? Uint8List(0), _delayOf(exchange));
  }

  Duration _delayOf(NetExchange exchange) {
    if (latency.instant) return Duration.zero;
    final fixed = latency.ms;
    if (fixed != null) return Duration(milliseconds: fixed);
    return Duration(milliseconds: ((exchange.ms ?? 0) / speed).round());
  }

  /// Answers the tape listed in total.
  int get expected => tape.net.length;

  /// The answer [n] reached the app again.
  void delivered(int n) {
    if (!_delivered.add(n)) return;
    for (final wait in List.of(_waits)) {
      if (_delivered.containsAll(wait.$1)) {
        _waits.remove(wait);
        if (!wait.$2.isCompleted) wait.$2.complete(true);
      }
    }
  }

  /// Whether [n] was delivered.
  bool wasDelivered(int n) => _delivered.contains(n);

  /// Completes with true once every answer in [ns] was delivered, or with
  /// false after [timeout].
  Future<bool> waitFor(
    Iterable<int> ns, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    final need = {...ns}..removeAll(_delivered);
    if (need.isEmpty) return Future<bool>.value(true);
    final completer = Completer<bool>();
    final entry = (need, completer);
    _waits.add(entry);
    final timer = Timer(timeout, () {
      _waits.remove(entry);
      if (!completer.isCompleted) completer.complete(false);
    });
    return completer.future.whenComplete(timer.cancel);
  }

  /// Ends every wait with false.
  void close() {
    for (final (_, completer) in _waits) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _waits.clear();
  }
}

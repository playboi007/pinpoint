// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13). The
// network events of PLAN-v2 Milestone 14 (steps 11 to 13), without a
// platform: the web hooks turn `fetch` and XHR objects into these calls,
// and tests drive them directly.

import 'dart:collection';
import 'dart:typed_data';

import '../model/annotation.dart' show clipText;
import '../model/trace_event.dart';
import '../tape/net_matcher.dart';
import 'cause_zone.dart';
import 'redact.dart';
import 'trace_recorder.dart';

/// Writes `net.request`, `net.response` and `net.error` events.
///
/// Request and response metadata is level 1. Bodies are level 2
/// ([bodies], `TraceConfig.bodies`): a body is read only to hash it and to
/// keep up to [maxBody] bytes of it for a tape (Milestone 15). Bodies never
/// go into events.
class NetRecorder {
  NetRecorder(
    this.recorder, {
    bool bodies = true,
    NetBodies? store,
    this.redact = const TraceRedact(),
    this.ignoreOrigins = const <String>{},
    this.tap,
  }) : readBodies = bodies,
       store = store ?? NetBodies();

  /// While a replay runs, answers requests from a tape (PLAN-v2 Milestone
  /// 15, step 8). Null: every request reaches the network.
  NetReplay? replay;

  /// Sees every recorded request with its raw URL and body, and its answer
  /// (the tape recorder, Milestone 15). With a tap, kept bodies go to the
  /// tap and not to [store]: a body is held once.
  NetTap? tap;

  final TraceRecorder recorder;

  /// Header and URL parameter names whose values are masked before an
  /// event exists (rule 16).
  final TraceRedact redact;

  /// Origins never recorded, such as `http://127.0.0.1:4747`: the bridge's
  /// (rule 14). Their requests pass through untouched.
  final Set<String> ignoreOrigins;

  /// Requests left out: to an ignored origin, or Pinpoint's own.
  int ignored = 0;

  /// Whether answers are read for their hash and kept.
  final bool readBodies;

  /// The bodies kept, by the seq of their `net.response`.
  final NetBodies store;

  /// The bodies kept; see [store].
  NetBodies get bodies => store;

  /// The most bytes of one body kept. A larger body keeps its hash and
  /// says `truncated: true`.
  static const int maxBody = 256 * 1024;

  /// Longest URL kept in an event.
  static const int maxUrl = 400;

  /// A request starts: records `net.request` in the cause of the calling
  /// zone. [body] is the request body when its bytes are known; otherwise
  /// [bodyKind] names it (`stream`, `form`, `blob`) and [bodySize] gives
  /// its size if known.
  ///
  /// Null when the request is not recorded.
  NetCall? request({
    required String via,
    required String method,
    required String url,
    Map<String, String> headers = const <String, String>{},
    List<int>? body,
    String? bodyKind,
    int? bodySize,
  }) {
    final cause = CauseZone.currentCause;
    // Pinpoint never records itself (rule 14): its long poll and its
    // posts to the bridge are left out, by zone and by origin.
    if ((cause != null && cause.internal) || _ignored(url)) {
      ignored++;
      return null;
    }
    final upper = method.toUpperCase();
    // Masked before the event exists (rule 16).
    final shownUrl = clipText(redact.url(url), maxUrl);
    final event = recorder.add(
      TraceKind.netRequest,
      data: {
        'via': via,
        'method': upper,
        'url': shownUrl,
        if (body != null) ...{'size': body.length, 'hash': NetHash.of(body)},
        if (body == null && bodySize != null) 'size': bodySize,
        'body': ?bodyKind,
        if (headers.isNotEmpty) 'headers': _clipHeaders(headers),
      },
      cause: cause,
    );
    final call = NetCall._(this, event, cause, upper, shownUrl);
    try {
      tap?.requested(call, url, body);
    } catch (_) {
      // The recorder only observes (rule 11).
    }
    return call;
  }

  /// What the platform hook does with a request during a replay: serve,
  /// fail or pass it through. Null when no replay runs, and for requests
  /// that are never recorded (the bridge, Pinpoint's own work): those
  /// always reach the network.
  ///
  /// A request with no answer in the tape records `replay.unmatched`.
  NetAnswer? replayAnswer({
    required String method,
    required String url,
    List<int>? body,
  }) {
    final replay = this.replay;
    if (replay == null) return null;
    final cause = CauseZone.currentCause;
    if ((cause != null && cause.internal) || _ignored(url)) return null;
    final NetAnswer answer;
    try {
      answer = replay.answer(method: method, url: url, body: body);
    } catch (error) {
      // The replay only decides; a failure here lets the request go.
      return null;
    }
    final unmatched =
        (answer is FailAnswer && !answer.taped) ||
        (answer is PassAnswer && answer.exchange == null);
    if (unmatched) {
      recorder.add(
        TraceKind.replayUnmatched,
        data: {
          'method': method.toUpperCase(),
          'url': clipText(redact.url(url), maxUrl),
          'then': answer is PassAnswer ? 'passthrough' : 'fail',
        },
        cause: cause,
      );
    }
    return answer;
  }

  bool _ignored(String url) {
    try {
      final uri = Uri.base.resolve(url);
      return engineResource(uri) ||
          ignoreOrigins.contains('${uri.scheme}://${uri.authority}');
    } catch (_) {
      return false;
    }
  }

  /// Whether [uri] is a file the Flutter web engine loads for itself: a
  /// fallback font when a glyph is missing, or CanvasKit. The app did not
  /// ask for it and the engine asks again only when it needs it, so a
  /// tape that kept it waits in vain for its answer at replay. Never
  /// recorded, and it always reaches the network.
  static bool engineResource(Uri uri) => switch (uri.host) {
    'fonts.gstatic.com' || 'fonts.googleapis.com' => true,
    'www.gstatic.com' => uri.path.startsWith('/flutter-'),
    _ => false,
  };

  void _tell(void Function(NetTap tap) call) {
    final tap = this.tap;
    if (tap == null) return;
    try {
      call(tap);
    } catch (_) {
      // The recorder only observes (rule 11).
    }
  }

  /// Masked, lower-case names, clipped.
  Map<String, Object?> _clipHeaders(Map<String, String> headers) => {
    for (final MapEntry(:key, :value) in headers.entries.take(20))
      clipText(key.toLowerCase(), 60): clipText(
        redact.masks(key) ? TraceRedact.mask : value,
        200,
      ),
  };

  /// Why an answer's body is not read, or null to read it.
  String? _skipReason(Map<String, String> headers, int? length) {
    if (!readBodies) return 'TraceConfig.bodies is false';
    final type = (_header(headers, 'content-type') ?? '').toLowerCase();
    // Watch out for: a cloned body is in memory twice until the copy is
    // read. Skip the clone for a large download, and for types that are
    // not text or JSON. A stream of events never ends, so it is skipped
    // too.
    if (length != null && length > maxBody) return 'larger than 256 KB';
    if (type.startsWith('text/event-stream')) return 'event stream';
    final textual =
        type.isEmpty ||
        type.startsWith('text/') ||
        type.contains('json') ||
        type.contains('xml') ||
        type.contains('javascript') ||
        type.contains('x-www-form-urlencoded');
    if (!textual) return type;
    return null;
  }

  static String? _header(Map<String, String> headers, String name) {
    for (final MapEntry(:key, :value) in headers.entries) {
      if (key.toLowerCase() == name) return value;
    }
    return null;
  }
}

/// Sees each recorded request and its answer, with what events do not
/// hold: the raw URL and the request body (for the request key), and the
/// answer's bytes (for a tape).
abstract interface class NetTap {
  /// A request started. [url] and [body] are raw: use them for a key
  /// only, never keep them in clear (rule 16).
  void requested(NetCall call, String url, List<int>? body);

  /// The answer's headers arrived ([NetCall.response] is set).
  void answered(NetCall call);

  /// The answer's body ended. [body] is null when it was not read or not
  /// kept whole ([NetCall.notKept] says why).
  void ended(NetCall call, Uint8List? body);

  /// The request failed ([NetCall.error] is set).
  void failed(NetCall call);
}

/// One request in flight. Its answer events carry the cause of the call,
/// also when the browser reports the answer outside every zone.
class NetCall {
  NetCall._(this._net, this.request, this.cause, this.method, this.url);

  final NetRecorder _net;

  /// The `net.request` event.
  final TraceEvent request;

  /// The cause of the zone the request was made in.
  final TraceCause? cause;

  final String method;
  final String url;
  final Stopwatch _watch = Stopwatch()..start();

  /// The `net.response` event, once the headers arrived.
  TraceEvent? response;

  NetHash? _hash;
  BytesBuilder? _kept;
  String? _skipped;

  /// Why the body was not read or kept whole, or null when it was: the
  /// tape cannot serve such an answer.
  String? get notKept => _skipped;
  int _size = 0;
  bool _ended = false;

  /// The headers arrived: records `net.response`. True when the caller
  /// should read the body and give it to [chunk] and [end].
  bool respond({
    required int status,
    Map<String, String> headers = const <String, String>{},
    int? length,
  }) {
    if (response != null) return false;
    final type = NetRecorder._header(headers, 'content-type');
    final declared =
        length ??
        int.tryParse(NetRecorder._header(headers, 'content-length') ?? '');
    final skip = _net._skipReason(headers, declared);
    response = _net.recorder.add(
      TraceKind.netResponse,
      // Not const: [end] adds the size and hash when the body is read.
      data: <String, Object?>{
        'req': request.seq,
        'method': method,
        'url': url,
        'status': status,
        'ms': _watch.elapsedMilliseconds,
        'size': ?declared,
        'type': ?(type == null ? null : clipText(type, 80)),
        if (headers.isNotEmpty) 'headers': _net._clipHeaders(headers),
        if (skip != null) 'body': 'not read: $skip',
      },
      cause: cause,
    );
    _skipped = skip;
    _net._tell((tap) => tap.answered(this));
    if (skip != null) {
      _net._tell((tap) => tap.ended(this, null));
      return false;
    }
    _hash = NetHash();
    _kept = BytesBuilder(copy: false);
    return true;
  }

  /// Part of the body, in order.
  void chunk(List<int> bytes) {
    final hash = _hash;
    final kept = _kept;
    if (hash == null || kept == null || _ended) return;
    hash.add(bytes);
    _size += bytes.length;
    final room = NetRecorder.maxBody - kept.length;
    if (room > 0) {
      kept.add(bytes.length <= room ? bytes : bytes.sublist(0, room));
    }
  }

  /// The body ended: its size and hash go into the `net.response` event,
  /// and up to [NetRecorder.maxBody] bytes into the store. [notRead]: the
  /// body could not be read (the read failed, a `blob` XHR), and why; what
  /// was read is dropped.
  void end({String? notRead}) {
    final event = response;
    final hash = _hash;
    if (_ended || event == null) return;
    _ended = true;
    if (hash == null) return;
    if (notRead != null) {
      event.data['body'] = 'not read: $notRead';
      _kept = null;
      _skipped = notRead;
      _net._tell((tap) => tap.ended(this, null));
      return;
    }
    event.data['size'] = _size;
    event.data['hash'] = hash.hex;
    if (_size > NetRecorder.maxBody) {
      event.data['truncated'] = true;
      _skipped = 'larger than 256 KB';
    }
    final kept = _kept?.takeBytes();
    _kept = null;
    if (kept == null) return;
    if (_net.tap == null) {
      _net.store.keep(event.seq, kept);
    } else {
      _net._tell((tap) => tap.ended(this, _skipped == null ? kept : null));
    }
  }

  /// The request failed before an answer: records `net.error`.
  void fail(String error) {
    if (response != null || _ended) return;
    _ended = true;
    this.error = _net.recorder.add(
      TraceKind.netError,
      data: {
        'req': request.seq,
        'method': method,
        'url': url,
        'ms': _watch.elapsedMilliseconds,
        'error': clipText(error, 200),
      },
      cause: cause,
    );
    _net._tell((tap) => tap.failed(this));
  }

  /// The `net.error` event, once the request failed.
  TraceEvent? error;
}

/// FNV-1a, 32 bits, as 8 hex digits: the same on the VM and in a browser,
/// where an `int` is a double and a plain 32-bit multiply loses bits.
class NetHash {
  int _h = 0x811c9dc5;

  void add(List<int> bytes) {
    var h = _h;
    for (final b in bytes) {
      h ^= b & 0xff;
      // h * 16777619 mod 2^32, as (h << 24) + h * 403: each part stays
      // below 2^53, so a double holds it exactly.
      h = (((h << 24) & 0xffffffff) + h * 0x193) & 0xffffffff;
    }
    _h = h;
  }

  String get hex => _h.toRadixString(16).padLeft(8, '0');

  static String of(List<int> bytes) => (NetHash()..add(bytes)).hex;
}

/// The bodies kept for tapes, bounded twice (rule 12): by count and by
/// bytes. The oldest go first.
class NetBodies {
  NetBodies({this.maxCount = 200, this.maxBytes = 8 * 1024 * 1024});

  final int maxCount;
  final int maxBytes;
  final LinkedHashMap<int, Uint8List> _bodies = LinkedHashMap<int, Uint8List>();
  int _bytes = 0;

  int get length => _bodies.length;
  int get bytes => _bytes;

  /// The body of the `net.response` [seq], or null when it is not kept.
  Uint8List? bodyOf(int seq) => _bodies[seq];

  void keep(int seq, List<int> body) {
    final bytes = body is Uint8List ? body : Uint8List.fromList(body);
    final old = _bodies.remove(seq);
    if (old != null) _bytes -= old.length;
    _bodies[seq] = bytes;
    _bytes += bytes.length;
    while (_bodies.isNotEmpty &&
        (_bodies.length > maxCount || _bytes > maxBytes)) {
      final first = _bodies.keys.first;
      _bytes -= _bodies.remove(first)!.length;
    }
  }

  void clear() {
    _bodies.clear();
    _bytes = 0;
  }
}

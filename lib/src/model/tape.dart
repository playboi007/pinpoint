// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13). The
// app makes tapes and the bridge stores and reads the same shape.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'json_read.dart';

/// Version of the tape JSON shape.
const int tapeSchema = 1;

/// What a tape id looks like: `tp_20261113_100001_a1f3`. A tape id becomes
/// a file name on the bridge, so nothing else is accepted.
final RegExp tapeIdPattern = RegExp(r'^tp_[a-z0-9_]{4,60}$');

/// What a replay run id looks like: `run_20261113_100001_a1f3`.
final RegExp runIdPattern = RegExp(r'^run_[a-z0-9_]{4,60}$');

final Random _random = Random();

String _stamp(DateTime at, String prefix) {
  final u = at.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  final suffix = _random.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
  return '${prefix}_${u.year}${two(u.month)}${two(u.day)}_'
      '${two(u.hour)}${two(u.minute)}${two(u.second)}_$suffix';
}

/// A new tape id for a tape saved at [at].
String newTapeId([DateTime? at]) => _stamp(at ?? DateTime.now(), 'tp');

/// A new run id for a replay started at [at].
String newRunId([DateTime? at]) => _stamp(at ?? DateTime.now(), 'run');

/// A **full** tape starts at app start and replays after a restart. A
/// **segment** starts at a mark (or seconds back) and replays from wherever
/// the app is now (PLAN-v2 Milestone 15, step 2).
enum TapeKind {
  full,
  segment;

  static TapeKind? byName(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// Where a tape starts: the page, its size, its environment and, when the
/// config allows it, its storage.
class TapeStart {
  const TapeStart({
    required this.t,
    required this.seq,
    required this.wallTime,
    this.url = '',
    this.width,
    this.height,
    this.pixelRatio,
    this.locale,
    this.environment,
    this.storage,
  });

  static TapeStart? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final t = json['t'];
    final seq = json['seq'];
    final wall = json['wall'];
    if (t is! int || seq is! int || wall is! String) return null;
    final env = json['environment'];
    final storage = json['storage'];
    return TapeStart(
      t: t,
      seq: seq,
      wallTime: wall,
      url: json['url'] is String ? json['url']! as String : '',
      width: asDouble(json['width']),
      height: asDouble(json['height']),
      pixelRatio: asDouble(json['pixelRatio']),
      locale: json['locale'] is String ? json['locale']! as String : null,
      environment: env is Map<String, Object?> ? env : null,
      storage: storage is Map<String, Object?>
          ? {
              for (final MapEntry(:key, :value) in storage.entries)
                if (value is Map<String, Object?>)
                  key: {
                    for (final e in value.entries)
                      if (e.value is String) e.key: e.value! as String,
                  },
            }
          : null,
    );
  }

  /// Run time (ms) at which the tape starts. 0 for a full tape.
  final int t;

  /// The first seq the tape covers.
  final int seq;

  /// Wall clock time at [t], ISO 8601.
  final String wallTime;

  /// The page URL (web), or empty.
  final String url;

  /// The view's logical size and pixel ratio.
  final double? width;
  final double? height;
  final double? pixelRatio;

  /// For example `en-US`.
  final String? locale;

  /// The Milestone 9 environment in force (`Environment.toJson`).
  final Map<String, Object?>? environment;

  /// `local` and `session`: copies of `localStorage` and `sessionStorage`
  /// at app start. Only with `TraceConfig.storage`, because they hold
  /// session tokens (step 4).
  final Map<String, Map<String, String>>? storage;

  Map<String, Object?> toJson() => {
    't': t,
    'seq': seq,
    'wall': wallTime,
    if (url.isNotEmpty) 'url': url,
    'width': ?width,
    'height': ?height,
    'pixelRatio': ?pixelRatio,
    'locale': ?locale,
    'environment': ?environment,
    'storage': ?storage,
  };
}

/// One input of a tape: a pointer, key, text or message event, with what
/// it waits for at replay (step 10).
class TapeInput {
  const TapeInput({
    required this.step,
    required this.seq,
    required this.t,
    required this.frame,
    required this.kind,
    this.widget,
    this.source,
    this.data = const <String, Object?>{},
    this.after = const <int>[],
  });

  static TapeInput? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final step = json['step'];
    final seq = json['seq'];
    final t = json['t'];
    final frame = json['frame'];
    final kind = json['kind'];
    if (step is! int || seq is! int || t is! int || kind is! String) {
      return null;
    }
    final data = json['data'];
    final after = json['after'];
    return TapeInput(
      step: step,
      seq: seq,
      t: t,
      frame: frame is int ? frame : 0,
      kind: kind,
      widget: json['widget'] is String ? json['widget']! as String : null,
      source: json['source'] is String ? json['source']! as String : null,
      data: data is Map<String, Object?> ? data : const <String, Object?>{},
      after: after is List<Object?>
          ? [for (final n in after) ?(n is int ? n : null)]
          : const <int>[],
    );
  }

  /// 1-based order in the tape: what `first_difference` and `until:
  /// 'step:12'` name.
  final int step;

  /// The event's seq in the run it was recorded in.
  final int seq;

  /// Run time (ms) of the event.
  final int t;
  final int frame;

  /// `input.pointer`, `input.key`, `input.text` or `input.message`.
  final String kind;

  /// The widget type it hit (a pointer down) or typed into (text).
  final String? widget;
  final String? source;

  /// The event's data: for a pointer down also its `anchor`, `fx` and `fy`.
  final Map<String, Object?> data;

  /// The order numbers of the exchanges whose answer had arrived before
  /// this input. At replay it waits until they are delivered again.
  final List<int> after;

  Map<String, Object?> toJson() => {
    'step': step,
    'seq': seq,
    't': t,
    'frame': frame,
    'kind': kind,
    'widget': ?widget,
    'source': ?source,
    if (data.isNotEmpty) 'data': data,
    if (after.isNotEmpty) 'after': after,
  };
}

/// One request of a tape and its answer.
class NetExchange {
  const NetExchange({
    required this.n,
    required this.key,
    required this.method,
    required this.url,
    required this.t,
    this.nth = 1,
    this.status,
    this.headers = const <String, String>{},
    this.ms,
    this.hash,
    this.size,
    this.error,
    this.unsupported,
    this.answeredSeq,
  });

  static NetExchange? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final n = json['n'];
    final key = json['key'];
    final method = json['method'];
    final url = json['url'];
    final t = json['t'];
    if (n is! int ||
        key is! String ||
        method is! String ||
        url is! String ||
        t is! int) {
      return null;
    }
    final headers = json['headers'];
    return NetExchange(
      n: n,
      key: key,
      method: method,
      url: url,
      t: t,
      nth: json['nth'] is int ? json['nth']! as int : 1,
      status: json['status'] is int ? json['status']! as int : null,
      headers: headers is Map<String, Object?>
          ? {
              for (final e in headers.entries)
                if (e.value is String) e.key: e.value! as String,
            }
          : const <String, String>{},
      ms: json['ms'] is int ? json['ms']! as int : null,
      hash: json['hash'] is String ? json['hash']! as String : null,
      size: json['size'] is int ? json['size']! as int : null,
      error: json['error'] is String ? json['error']! as String : null,
      unsupported: json['unsupported'] is String
          ? json['unsupported']! as String
          : null,
      answeredSeq: json['answered'] is int ? json['answered']! as int : null,
    );
  }

  /// Order number in the tape, from 0, by request order.
  final int n;

  /// The request key (`NetMatcher.key`): method, URL without the
  /// parameters in `redact` and `matchIgnore`, and the body hash.
  final String key;

  /// 1-based: this is the nth request with [key] in the tape.
  final int nth;

  final String method;

  /// The URL as recorded: masked (rule 16).
  final String url;

  /// Run time (ms) of the request.
  final int t;

  /// The answer's status; null when it failed or never came.
  final int? status;

  /// The answer's headers, masked when recorded.
  final Map<String, String> headers;

  /// Latency: request to answer headers.
  final int? ms;

  /// FNV-1a hash and size of the answer's body, when it was read.
  final String? hash;
  final int? size;

  /// The request failed with no answer: why.
  final String? error;

  /// Why the answer cannot be served from the tape (an event stream, a body
  /// that was not kept). A replay passes such a request through.
  final String? unsupported;

  /// The seq of the answer's `net.response` (or `net.error`), for [after].
  final int? answeredSeq;

  Map<String, Object?> toJson() => {
    'n': n,
    'key': key,
    'nth': nth,
    'method': method,
    'url': url,
    't': t,
    'status': ?status,
    if (headers.isNotEmpty) 'headers': headers,
    'ms': ?ms,
    'hash': ?hash,
    'size': ?size,
    'error': ?error,
    'unsupported': ?unsupported,
    'answered': ?answeredSeq,
  };
}

/// A mark of the run, kept with the tape.
class TapeMark {
  const TapeMark({
    required this.seq,
    required this.t,
    this.text = '',
    this.by = 'user',
  });

  static TapeMark? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final seq = json['seq'];
    final t = json['t'];
    if (seq is! int || t is! int) return null;
    return TapeMark(
      seq: seq,
      t: t,
      text: json['text'] is String ? json['text']! as String : '',
      by: json['by'] is String ? json['by']! as String : 'user',
    );
  }

  final int seq;
  final int t;
  final String text;
  final String by;

  Map<String, Object?> toJson() => {
    'seq': seq,
    't': t,
    if (text.isNotEmpty) 'text': text,
    'by': by,
  };
}

/// The inputs and network answers of a run, saved so the run can happen
/// again (PLAN-v2 Milestone 15).
///
/// The bodies are not part of [toJson]: they live in files next to the
/// tape on the bridge (`tapes/<id>/bodies/`), and a tool answer never
/// carries them (rule 16).
class Tape {
  Tape({
    required this.id,
    required this.kind,
    required this.start,
    this.name,
    this.inputs = const <TapeInput>[],
    this.net = const <NetExchange>[],
    this.marks = const <TapeMark>[],
    this.routes = const <String>[],
    this.partial = false,
    this.partialReason,
    this.bodiesRead = true,
    Map<int, Uint8List>? bodies,
  }) : bodies = bodies ?? <int, Uint8List>{};

  /// [json] (a [toJson] map) as a tape, with [bodies] from [bodiesToJson];
  /// null when a required part is missing.
  static Tape? fromJson(Object? json, {Object? bodies}) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final kind = TapeKind.byName(json['kind']);
    final start = TapeStart.fromJson(json['start']);
    if (id is! String || kind == null || start == null) return null;
    List<T> list<T>(Object? raw, T? Function(Object?) read) => [
      for (final item in raw is List<Object?> ? raw : const <Object?>[])
        ?read(item),
    ];
    final kept = <int, Uint8List>{};
    if (bodies is Map<String, Object?>) {
      for (final MapEntry(:key, :value) in bodies.entries) {
        final n = int.tryParse(key);
        if (n == null || value is! String) continue;
        try {
          kept[n] = base64Decode(value);
        } on FormatException {
          // A broken body is left out; its request passes through.
        }
      }
    }
    final routes = json['routes'];
    return Tape(
      id: id,
      kind: kind,
      start: start,
      name: json['name'] is String ? json['name']! as String : null,
      inputs: list(json['inputs'], TapeInput.fromJson),
      net: list(json['net'], NetExchange.fromJson),
      marks: list(json['marks'], TapeMark.fromJson),
      routes: routes is List<Object?>
          ? [for (final r in routes) ?(r is String ? r : null)]
          : const <String>[],
      partial: json['partial'] == true,
      partialReason: json['reason'] is String
          ? json['reason']! as String
          : null,
      bodiesRead: json['bodies'] != false,
      bodies: kept,
    );
  }

  final String id;
  final String? name;
  final TapeKind kind;
  final TapeStart start;
  final List<TapeInput> inputs;
  final List<NetExchange> net;
  final List<TapeMark> marks;

  /// The route names in the order they were shown: what a replay compares
  /// first (step 13).
  final List<String> routes;

  /// Whether a limit dropped data the tape needed (rule 19). A replay of a
  /// partial tape cannot give `changed`.
  final bool partial;
  final String? partialReason;

  /// Whether answers were read (`TraceConfig.bodies`). False: the tape has
  /// no answers to serve, and its replay passes requests through.
  final bool bodiesRead;

  /// Answer bodies by exchange order number.
  final Map<int, Uint8List> bodies;

  /// Bytes of all bodies.
  int get bodyBytes => bodies.values.fold(0, (a, b) => a + b.length);

  /// Counts for the note header and `list_tapes`.
  Map<String, Object?> get summary => {
    'id': id,
    'name': ?name,
    'kind': kind.name,
    'inputs': inputs.length,
    'requests': net.length,
    'marks': marks.length,
    'bytes': bodyBytes,
    'start': start.wallTime,
    'seconds': inputs.isEmpty
        ? 0
        : ((inputs.last.t - start.t) / 1000).toStringAsFixed(1),
    if (!bodiesRead) 'bodies': 'not read (TraceConfig.bodies is false)',
    if (partial) 'partial': partialReason ?? true,
  };

  Map<String, Object?> toJson() => {
    'schema': tapeSchema,
    'id': id,
    'name': ?name,
    'kind': kind.name,
    'start': start.toJson(),
    'inputs': [for (final i in inputs) i.toJson()],
    'net': [for (final e in net) e.toJson()],
    'marks': [for (final m in marks) m.toJson()],
    if (routes.isNotEmpty) 'routes': routes,
    if (partial) 'partial': true,
    'reason': ?partialReason,
    if (!bodiesRead) 'bodies': false,
  };

  /// The bodies as `{"<n>": base64}`, for the trip to the bridge.
  Map<String, Object?> bodiesToJson() => {
    for (final MapEntry(:key, :value) in bodies.entries)
      '$key': base64Encode(value),
  };
}

/// The order numbers of the exchanges in [net] answered before the event
/// [seq]: the `after` of an input at [seq] (step 1).
List<int> answeredBefore(int seq, List<NetExchange> net) => [
  for (final e in net)
    if (e.answeredSeq != null && e.answeredSeq! < seq) e.n,
];

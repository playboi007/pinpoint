// Plain Dart: no `dart:ui` and no `package:flutter`. The app makes tapes and
// the bridge stores and reads the same shape.

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
/// the app is now.
enum TapeKind {
  full,
  segment;

  static TapeKind? byName(Object? name) => asEnum(values, name);
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
    if (json case {
      't': final int t,
      'seq': final int seq,
      'wall': final String wall,
    }) {
      return TapeStart(
        t: t,
        seq: seq,
        wallTime: wall,
        url: json.str('url') ?? '',
        width: asDouble(json['width']),
        height: asDouble(json['height']),
        pixelRatio: asDouble(json['pixelRatio']),
        locale: json.str('locale'),
        environment: json.object('environment', (map) => map),
        storage: json.object('storage', _storageOf),
      );
    }
    return null;
  }

  static Map<String, Map<String, String>> _storageOf(
    Map<String, Object?> storage,
  ) => {
    for (final MapEntry(:key, :value) in storage.entries)
      if (value is Map<String, Object?>) key: asStringMap(value),
  };

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

  /// The environment override in force (`EnvironmentController.toJson`).
  final Map<String, Object?>? environment;

  /// `local` and `session`: copies of `localStorage` and `sessionStorage`
  /// at app start. Only with `TraceConfig.storage`, because they hold
  /// session tokens.
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
/// it waits for at replay.
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
    if (json case {
      'step': final int step,
      'seq': final int seq,
      't': final int t,
      'kind': final String kind,
    }) {
      return TapeInput(
        step: step,
        seq: seq,
        t: t,
        frame: asInt(json['frame']) ?? 0,
        kind: kind,
        widget: json.str('widget'),
        source: json.str('source'),
        data: asJsonMap(json['data']),
        after: json.items('after', asInt),
      );
    }
    return null;
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
    if (json case {
      'n': final int n,
      'key': final String key,
      'method': final String method,
      'url': final String url,
      't': final int t,
    }) {
      return NetExchange(
        n: n,
        key: key,
        method: method,
        url: url,
        t: t,
        nth: asInt(json['nth']) ?? 1,
        status: asInt(json['status']),
        headers: asStringMap(json['headers']),
        ms: asInt(json['ms']),
        hash: json.str('hash'),
        size: asInt(json['size']),
        error: json.str('error'),
        unsupported: json.str('unsupported'),
        answeredSeq: asInt(json['answered']),
      );
    }
    return null;
  }

  /// Order number in the tape, from 0, by request order.
  final int n;

  /// The request key (`NetMatcher.key`): method, URL without the
  /// parameters in `redact` and `matchIgnore`, and the body hash.
  final String key;

  /// 1-based: this is the nth request with [key] in the tape.
  final int nth;

  final String method;

  /// The URL as recorded, with secret query values masked.
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
    if (json case {'seq': final int seq, 't': final int t}) {
      return TapeMark(
        seq: seq,
        t: t,
        text: json.str('text') ?? '',
        by: json.str('by') ?? 'user',
      );
    }
    return null;
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
/// again.
///
/// The bodies are not part of [toJson]: they live in files next to the
/// tape on the bridge (`tapes/<id>/bodies/`), and a tool answer never
/// carries them.
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
    final id = json.str('id');
    final kind = TapeKind.byName(json['kind']);
    final start = TapeStart.fromJson(json['start']);
    if (id == null || kind == null || start == null) return null;
    return Tape(
      id: id,
      kind: kind,
      start: start,
      name: json.str('name'),
      inputs: json.items('inputs', TapeInput.fromJson),
      net: json.items('net', NetExchange.fromJson),
      marks: json.items('marks', TapeMark.fromJson),
      routes: json.items('routes', asString),
      partial: json['partial'] == true,
      partialReason: json.str('reason'),
      bodiesRead: json['bodies'] != false,
      bodies: _decodeBodies(bodies),
    );
  }

  /// A body that is not valid base64 is left out; its request passes through.
  static Map<int, Uint8List> _decodeBodies(Object? bodies) {
    final decoded = <int, Uint8List>{};
    for (final MapEntry(:key, :value) in asJsonMap(bodies).entries) {
      final n = int.tryParse(key);
      if (n == null || value is! String) continue;
      try {
        decoded[n] = base64Decode(value);
      } on FormatException {
        continue;
      }
    }
    return decoded;
  }

  final String id;
  final String? name;
  final TapeKind kind;
  final TapeStart start;
  final List<TapeInput> inputs;
  final List<NetExchange> net;
  final List<TapeMark> marks;

  /// The route names in the order they were shown: what a replay compares
  /// first.
  final List<String> routes;

  /// Whether a limit dropped data the tape needed. A replay of a
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
/// [seq]: the `after` of an input at [seq].
List<int> answeredBefore(int seq, List<NetExchange> net) => [
  for (final e in net)
    if (e.answeredSeq != null && e.answeredSeq! < seq) e.n,
];

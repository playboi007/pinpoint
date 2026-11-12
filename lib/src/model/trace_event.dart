// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13). The
// app records these events and the bridge reads the same shape.

import 'dart:convert';

import 'annotation.dart' show clipText;

/// The kinds of [TraceEvent] that Milestone 13 records.
///
/// A kind is a dotted name; a filter on `input` matches every `input.…`
/// kind.
abstract final class TraceKind {
  /// A pointer down, up, cancel, a scroll signal, or a move while down.
  static const String pointer = 'input.pointer';

  /// A hardware key down, repeat or up.
  static const String key = 'input.key';

  /// The value of the focused text field changed.
  static const String text = 'input.text';

  /// A `message` event on `window` (Milestone 14).
  static const String message = 'input.message';

  /// A frame the app drew.
  static const String frame = 'frame';

  /// A local widget rebuilt in a frame (level 3 only).
  static const String build = 'build';

  /// The current route changed.
  static const String route = 'route';

  /// Values of a watched `State` changed (level 3 only).
  static const String state = 'state';

  /// A `PinPoint.probe` line ran.
  static const String probe = 'probe';

  /// An error reached `FlutterError.onError` or `PlatformDispatcher.onError`.
  static const String error = 'error';

  /// A detector found a problem.
  static const String finding = 'finding';

  /// A moment the user or the agent pointed at.
  static const String mark = 'mark';

  /// Level 3 sources started. Before it, no `build` or `state` event means
  /// "not recorded", not "nothing happened".
  static const String detailOn = 'detail.on';

  /// Level 3 sources stopped.
  static const String detailOff = 'detail.off';

  /// Kinds that are input from the user, the browser or the platform.
  static bool isInput(String kind) => kind.startsWith('input.');

  /// Whether [kind] matches [filter]: the same kind, or a prefix of it up
  /// to a dot (`input` matches `input.key`).
  static bool matches(String kind, String filter) =>
      kind == filter ||
      (kind.length > filter.length &&
          kind.startsWith(filter) &&
          kind.codeUnitAt(filter.length) == 0x2E);
}

/// One thing that happened in the app (PLAN-v2, "One event shape for
/// everything").
///
/// [data] holds small JSON values only: [traceValues] clips them before an
/// event is made.
class TraceEvent {
  TraceEvent({
    required this.seq,
    required this.t,
    required this.frame,
    required this.kind,
    this.cause,
    this.widget,
    this.source,
    this.data = const <String, Object?>{},
  });

  /// [json] (a [toJson] map) as an event, or null when a required field is
  /// missing or of the wrong type. Unknown fields are ignored.
  static TraceEvent? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final seq = json['seq'];
    final t = json['t'];
    final frame = json['frame'];
    final kind = json['kind'];
    if (seq is! int || t is! int || frame is! int || kind is! String) {
      return null;
    }
    final cause = json['cause'];
    final widget = json['widget'];
    final source = json['source'];
    final data = json['data'];
    return TraceEvent(
      seq: seq,
      t: t,
      frame: frame,
      kind: kind,
      cause: cause is int ? cause : null,
      widget: widget is String ? widget : null,
      source: source is String ? source : null,
      data: data is Map<String, Object?> ? data : const <String, Object?>{},
    );
  }

  /// One line of JSONL as an event, or null for a blank or broken line.
  static TraceEvent? fromJsonLine(String line) {
    if (line.trim().isEmpty) return null;
    try {
      return fromJson(jsonDecode(line));
    } on FormatException {
      return null;
    }
  }

  /// Every event in [jsonl], one per line. Broken lines are skipped.
  static List<TraceEvent> parseJsonl(String jsonl) => [
    for (final line in const LineSplitter().convert(jsonl)) ?fromJsonLine(line),
  ];

  /// Order in the run, never reused.
  final int seq;

  /// Milliseconds since the run started, monotonic.
  final int t;

  /// Pinpoint's frame number when it happened.
  final int frame;

  /// For example `input.pointer` or `build`. See [TraceKind].
  final String kind;

  /// The id of the entry that started this work (Milestone 14); null
  /// without `PinPoint.run`.
  final int? cause;

  /// The type name of the widget involved, when known. Not final: a source
  /// that looks the widget up after the event (the pointer source, outside
  /// the pointer dispatch) fills it in then.
  String? widget;

  /// Where that widget is created, for example `lib/home.dart:120:12`. Not
  /// final, for the same reason as [widget].
  String? source;

  /// Small, clipped, JSON values only.
  final Map<String, Object?> data;

  /// Rough size in memory, for the recorder's byte limit. Counts strings by
  /// length and everything else as 8 bytes; [data] is small and flat, so
  /// this costs little.
  /// A widget or source filled in later is covered by the 64 bytes and the
  /// recorder's slack: the estimate is made once, when the event is added.
  late final int approxBytes =
      64 +
      kind.length +
      (widget?.length ?? 0) +
      (source?.length ?? 0) +
      _sizeOf(data);

  static int _sizeOf(Object? value) => switch (value) {
    final String s => 16 + s.length,
    final Map<String, Object?> m =>
      16 +
          [
            for (final MapEntry(:key, :value) in m.entries)
              key.length + _sizeOf(value),
          ].fold(0, (a, b) => a + b),
    final List<Object?> l => 16 + l.fold(0, (a, v) => a + _sizeOf(v)),
    _ => 8,
  };

  Map<String, Object?> toJson() => {
    'seq': seq,
    't': t,
    'frame': frame,
    'kind': kind,
    'cause': ?cause,
    'widget': ?widget,
    'source': ?source,
    if (data.isNotEmpty) 'data': data,
  };

  /// This event as one line of JSONL.
  String toJsonLine() => jsonEncode(toJson());

  @override
  String toString() => toJsonLine();
}

/// Longest string kept in an event's data, as in a state dump.
const int maxTraceChars = 200;

/// Most entries kept in a list or map inside an event's data.
const int maxTraceItems = 20;

/// [values] made safe for an event: strings cut to [maxTraceChars], lists
/// and maps cut to [maxTraceItems] entries one level deep, and any other
/// object turned into its clipped text. The same clipping a state dump
/// uses, so a probe never holds a large object.
Map<String, Object?> traceValues(Map<String, Object?> values) => {
  for (final MapEntry(:key, :value) in values.entries.take(maxTraceItems))
    clipText(key, 60): traceValue(value),
};

/// One value made safe for an event; see [traceValues].
Object? traceValue(Object? value, {bool nested = false}) {
  switch (value) {
    case null || bool() || int():
      return value;
    case final double d:
      return d.isFinite ? d : '$d';
    case final String s:
      return clipText(s, maxTraceChars);
    case final List<Object?> list when !nested:
      return [
        for (final item in list.take(maxTraceItems))
          traceValue(item, nested: true),
      ];
    case final Map<Object?, Object?> map when !nested:
      return {
        for (final MapEntry(:key, :value) in map.entries.take(maxTraceItems))
          clipText('$key', 60): traceValue(value, nested: true),
      };
  }
  try {
    return clipText('$value', maxTraceChars);
  } catch (_) {
    // A toString that throws.
    return '<${value.runtimeType}>';
  }
}

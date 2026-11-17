// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13).

/// Names whose values never reach memory in clear (PLAN-v2 Milestone 14,
/// step 15; rule 16): header names, URL parameter names, and keys of a
/// `message` event's JSON.
///
/// A name matches case-blind. `*token*` matches any name that contains
/// `token`; `x-*` any that starts with `x-`; `*-id` any that ends with
/// `-id`; anything else the whole name.
class TraceRedact {
  const TraceRedact([this.names = defaults]);

  /// `authorization`, `cookie`, `set-cookie`, and any name that contains
  /// `token`, `key` or `secret`.
  static const List<String> defaults = [
    'authorization',
    'cookie',
    'set-cookie',
    '*token*',
    '*key*',
    '*secret*',
  ];

  /// What a masked value becomes.
  static const String mask = '***';

  final List<String> names;

  /// Whether the value of [name] is masked.
  bool masks(String name) {
    final lower = name.toLowerCase();
    for (final pattern in names) {
      final p = pattern.toLowerCase();
      final starts = p.startsWith('*');
      final ends = p.length > 1 && p.endsWith('*');
      final core = p.substring(starts ? 1 : 0, ends ? p.length - 1 : p.length);
      final hit = starts && ends
          ? lower.contains(core)
          : starts
          ? lower.endsWith(core)
          : ends
          ? lower.startsWith(core)
          : lower == core;
      if (hit) return true;
    }
    return false;
  }

  /// [headers] with masked values.
  Map<String, String> headers(Map<String, String> headers) => {
    for (final MapEntry(:key, :value) in headers.entries)
      key: masks(key) ? mask : value,
  };

  /// [url] with masked parameter values and user info. The fragment, which
  /// a browser never sends, is dropped.
  String url(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    var head = url;
    final hash = head.indexOf('#');
    if (hash >= 0) head = head.substring(0, hash);
    var query = '';
    final mark = head.indexOf('?');
    if (mark >= 0) {
      query = head.substring(mark + 1);
      head = head.substring(0, mark);
    }
    if (uri.userInfo.isNotEmpty) {
      head = head.replaceFirst('${uri.userInfo}@', '$mask@');
    }
    if (query.isEmpty) return head;
    return '$head?${[for (final pair in query.split('&')) _pair(pair)].join('&')}';
  }

  String _pair(String pair) {
    final eq = pair.indexOf('=');
    if (eq < 0) return pair;
    final raw = pair.substring(0, eq);
    String name;
    try {
      name = Uri.decodeQueryComponent(raw);
    } catch (_) {
      name = raw;
    }
    return masks(name) ? '$raw=$mask' : pair;
  }

  /// A decoded JSON value with the values of masked keys replaced, at any
  /// depth.
  Object? json(Object? value) => switch (value) {
    final Map<Object?, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries)
        '$key': masks('$key') ? mask : json(value),
    },
    final List<Object?> list => [for (final item in list) json(item)],
    _ => value,
  };
}

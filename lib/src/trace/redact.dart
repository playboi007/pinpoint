// Plain Dart: no `dart:ui` and no `package:flutter`.

/// Names whose values never reach memory in clear: header names, URL parameter names, and keys of a
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

  /// [url] for a note: every query value is masked, whatever its name
  /// (a page URL can carry a session token under any name), and so is
  /// every value in the query of a hash route (`/#/orders?token=x`) or in
  /// a fragment that is only a query (`#access_token=x`). Names, path and
  /// route stay. User info is masked.
  String pageUrl(String url) {
    var head = url;
    var fragment = '';
    var hasFragment = false;
    final hash = head.indexOf('#');
    if (hash >= 0) {
      hasFragment = true;
      fragment = head.substring(hash + 1);
      head = head.substring(0, hash);
    }
    var query = '';
    var hasQuery = false;
    final mark = head.indexOf('?');
    if (mark >= 0) {
      hasQuery = true;
      query = head.substring(mark + 1);
      head = head.substring(0, mark);
    }
    final authority = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/?#]*)@');
    head = head.replaceFirstMapped(authority, (m) => '${m[1]}$mask@');
    final buffer = StringBuffer(head);
    if (hasQuery) buffer.write('?${_maskValues(query)}');
    if (hasFragment) {
      final route = fragment.indexOf('?');
      if (route >= 0) {
        buffer.write(
          '#${fragment.substring(0, route)}?'
          '${_maskValues(fragment.substring(route + 1))}',
        );
      } else if (!fragment.startsWith('/') && fragment.contains('=')) {
        buffer.write('#${_maskValues(fragment)}');
      } else {
        buffer.write('#$fragment');
      }
    }
    return buffer.toString();
  }

  /// The pairs of [query] with every value masked; a pair with no `=`
  /// stays.
  String _maskValues(String query) => [
    for (final pair in query.split('&'))
      if (pair.contains('='))
        '${pair.substring(0, pair.indexOf('='))}=$mask'
      else
        pair,
  ].join('&');

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

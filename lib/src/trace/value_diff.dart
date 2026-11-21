// Plain Dart: no `dart:ui` and no `package:flutter` (PLAN-v2 rule 13).
// What changed between two values, in a few words (PLAN-v3 Milestone 21b,
// "Story view"). The state lens keeps a small snapshot of the last value of
// each notifier it follows; at a notify it diffs that snapshot with the new
// one. Nothing here reads a private field or uses reflection: only `length`,
// iteration and `toString`.

import '../model/annotation.dart' show clipText;
import 'redact.dart';

/// Most changed fields, keys or indexes one diff names.
const int maxDiffNames = 5;

/// Most items or entries one snapshot keeps.
const int maxSnapItems = 50;

/// Longest text of one value in a snapshot or a diff.
const int maxDiffChars = 40;

/// Longest `toString` that is parsed for fields.
const int maxParsedChars = 2000;

/// A small, safe picture of a value at one moment.
class ValueSnap {
  const ValueSnap({
    required this.type,
    required this.text,
    this.fields,
    this.items,
    this.length,
    this.isMap = false,
    this.opaque = false,
    this.secrets,
  });

  /// The value's `runtimeType`, clipped.
  final String type;

  /// A short, redacted, clipped text of the value.
  final String text;

  /// The fields of a record or of `Name(a: 1, b: 2)`, or the entries of a
  /// map (key to text). Null for any other value. A positional field is
  /// named `$0`, `$1`.
  final Map<String, String>? fields;

  /// The first [maxSnapItems] items of a list or set.
  final List<String>? items;

  /// The length of a list, set or map.
  final int? length;

  final bool isMap;

  /// An `Instance of 'Foo'` value: its text says nothing.
  final bool opaque;

  /// For each masked field or key, a fingerprint of the real value. The
  /// text shows `***`; the fingerprint only tells that it changed.
  final Map<String, int>? secrets;

  /// The name inside `Instance of 'Foo'`, or the type.
  String get typeName {
    final match = _instance.firstMatch(text);
    return match?[1] ?? type;
  }

  /// Whether two snapshots say the same.
  bool sameAs(ValueSnap other) {
    if (text != other.text || length != other.length) return false;
    if (!_sameMap(fields, other.fields)) return false;
    final a0 = secrets;
    final b0 = other.secrets;
    if ((a0?.length ?? 0) != (b0?.length ?? 0)) return false;
    for (final MapEntry(:key, :value)
        in (a0 ?? const <String, int>{}).entries) {
      if (b0?[key] != value) return false;
    }
    final a = items;
    final b = other.items;
    if ((a == null) != (b == null)) return false;
    if (a != null) {
      if (a.length != b!.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
    }
    return true;
  }
}

bool _sameMap(Map<String, String>? a, Map<String, String>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (final MapEntry(:key, :value) in a.entries) {
    if (b[key] != value) return false;
  }
  return true;
}

final RegExp _instance = RegExp(r"^Instance of '([^']*)'$");

/// A snapshot of [value]. [owner] is the notifier's type name: a string
/// held by an owner whose name is masked (`tokenNotifier`) is masked whole,
/// and a field or key whose name is masked has its value masked
/// ([TraceRedact]).
ValueSnap snapshotOf(
  Object? value, {
  String owner = '',
  TraceRedact redact = const TraceRedact(),
}) {
  String type;
  try {
    type = clipText(value.runtimeType.toString(), 80);
  } catch (_) {
    type = '?';
  }
  String scalar(Object? v, {String key = ''}) {
    if (key.isNotEmpty && redact.masks(key)) return TraceRedact.mask;
    if (v is String) {
      if (owner.isNotEmpty && redact.masks(owner)) return TraceRedact.mask;
      return "'${clipText(v, maxDiffChars)}'";
    }
    try {
      return clipText('$v', maxDiffChars);
    } catch (_) {
      return '<${v.runtimeType}>';
    }
  }

  try {
    if (value == null || value is bool || value is num) {
      return ValueSnap(type: type, text: '$value');
    }
    if (value is String) {
      return ValueSnap(type: type, text: scalar(value));
    }
    if (value is Map) {
      final fields = <String, String>{};
      final secrets = <String, int>{};
      for (final entry in value.entries.take(maxSnapItems)) {
        final key = clipText('${entry.key}', 30);
        fields[key] = scalar(entry.value, key: key);
        if (redact.masks(key)) secrets[key] = _fingerprint(entry.value);
      }
      return ValueSnap(
        type: type,
        text: 'map of ${value.length}',
        fields: fields,
        length: value.length,
        isMap: true,
        secrets: secrets.isEmpty ? null : secrets,
      );
    }
    if (value is List || value is Set) {
      final iterable = value as Iterable<Object?>;
      final length = value is List ? value.length : (value as Set).length;
      return ValueSnap(
        type: type,
        text: '${value is List ? 'list' : 'set'} of $length',
        items: [for (final item in iterable.take(maxSnapItems)) scalar(item)],
        length: length,
      );
    }
    final full = '$value';
    if (_instance.hasMatch(full)) {
      return ValueSnap(type: type, text: full, opaque: true);
    }
    final fields = full.length <= maxParsedChars ? parseFields(full) : null;
    if (fields != null) {
      final shown = <String, String>{};
      final secrets = <String, int>{};
      for (final MapEntry(:key, :value) in fields.entries) {
        if (redact.masks(key)) {
          shown[key] = TraceRedact.mask;
          secrets[key] = _fingerprint(value);
        } else {
          shown[key] = clipText(value, maxDiffChars);
        }
      }
      // The text is rebuilt from the masked fields: a secret is never in it.
      final head = full.substring(0, full.indexOf('('));
      return ValueSnap(
        type: type,
        text: clipText(
          '$head(${[for (final e in shown.entries) '${e.key}: ${e.value}'].join(', ')})',
          maxDiffChars * 2,
        ),
        fields: shown,
        secrets: secrets.isEmpty ? null : secrets,
      );
    }
    return ValueSnap(
      type: type,
      text: owner.isNotEmpty && redact.masks(owner)
          ? TraceRedact.mask
          : clipText(full, maxDiffChars),
    );
  } catch (_) {
    // A `toString` that throws.
    return ValueSnap(type: type, text: '<$type>');
  }
}

// A number for a real value that must not be shown: equal values give equal
// numbers, and the value cannot be read back.
int _fingerprint(Object? value) => Object.hash('$value', 0x5e);

/// The fields of `Name(a: 1, b: 2)`, `(a: 1, b: 2)` or `(1, 2)`, or null
/// when [text] is not one of those. Fields are cut at commas outside
/// brackets and strings. A positional field is named `$0`, `$1`.
Map<String, String>? parseFields(String text) {
  final open = text.indexOf('(');
  if (open < 0 || !text.endsWith(')')) return null;
  // `Name(`, `Name<T>(` or `(`: nothing else before the bracket.
  final head = text.substring(0, open);
  if (!RegExp(r'^[A-Za-z_$][\w$<>?, .]*$|^$').hasMatch(head)) return null;
  final inner = text.substring(open + 1, text.length - 1);
  if (inner.trim().isEmpty) return null;
  final parts = _splitTop(inner);
  if (parts == null) return null;
  final fields = <String, String>{};
  var position = 0;
  for (final part in parts) {
    final colon = _topColon(part);
    if (colon > 0) {
      fields[part.substring(0, colon).trim()] = part
          .substring(colon + 1)
          .trim();
    } else {
      fields['\$${position++}'] = part.trim();
    }
  }
  return fields;
}

// Splits at commas that are outside (), [], {}, <> and quotes. Null when the
// brackets do not match.
List<String>? _splitTop(String text) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  String? quote;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    switch (c) {
      case "'" || '"':
        quote = c;
      case '(' || '[' || '{':
        depth++;
      case ')' || ']' || '}':
        depth--;
        if (depth < 0) return null;
      case ',' when depth == 0:
        parts.add(text.substring(start, i));
        start = i + 1;
    }
  }
  if (depth != 0 || quote != null) return null;
  final last = text.substring(start);
  if (last.trim().isNotEmpty) parts.add(last);
  return parts;
}

// The index of the colon that ends a field name, or -1 when the part has no
// name (the first colon must come before any bracket or quote).
int _topColon(String part) {
  for (var i = 0; i < part.length; i++) {
    final c = part[i];
    if (c == ':') {
      final name = part.substring(0, i).trim();
      return RegExp(r'^[\w$]+$').hasMatch(name) ? i : -1;
    }
    if ('([{\'"<'.contains(c)) return -1;
  }
  return -1;
}

/// Says what changed between [before] and [after] in a few words.
///
/// [sameObject] is true when the notifier's value is the same object before
/// and after (a list changed in place).
///
/// - A record, or `Name(a: 1, b: 2)`: the changed fields (at most
///   [maxDiffNames]): `focused false → true`.
/// - A list or set: the length and the changed indexes. A map: the length
///   and the changed keys.
/// - Equal text in a new object: `new object, same value`. The same object
///   with a snapshot that is equal: `changed in place`.
/// - `Instance of 'Foo'`: `changed (Foo)`.
/// - Anything else: `before → after`.
String diffValues(
  ValueSnap before,
  ValueSnap after, {
  bool sameObject = false,
}) {
  if (after.opaque || before.opaque) {
    return sameObject
        ? 'changed in place (${after.typeName})'
        : 'changed (${after.typeName})';
  }
  final same = before.sameAs(after);
  if (same) return sameObject ? 'changed in place' : 'new object, same value';
  final prefix = sameObject ? 'changed in place: ' : '';
  final bi = before.items;
  final ai = after.items;
  if (bi != null && ai != null) {
    final changed = <int>[];
    final n = bi.length < ai.length ? bi.length : ai.length;
    for (var i = 0; i < n; i++) {
      if (bi[i] != ai[i]) changed.add(i);
    }
    final parts = <String>[
      if (before.length != after.length)
        'length ${before.length} → ${after.length}'
      else
        'length ${after.length}',
      if (changed.isNotEmpty) 'changed ${_names(changed.map((i) => '[$i]'))}',
    ];
    return '$prefix${parts.join(', ')}';
  }
  final bf = before.fields;
  final af = after.fields;
  if (bf != null && af != null) {
    if (before.isMap || after.isMap) {
      final changed = <String>[
        for (final k in af.keys)
          if (bf.containsKey(k) &&
              (bf[k] != af[k] || before.secrets?[k] != after.secrets?[k]))
            k,
      ];
      final added = [
        for (final k in af.keys)
          if (!bf.containsKey(k)) k,
      ];
      final removed = [
        for (final k in bf.keys)
          if (!af.containsKey(k)) k,
      ];
      final parts = <String>[
        if (before.length != after.length)
          'length ${before.length} → ${after.length}'
        else
          'length ${after.length}',
        if (changed.isNotEmpty) 'changed ${_names(changed)}',
        if (added.isNotEmpty) 'added ${_names(added)}',
        if (removed.isNotEmpty) 'removed ${_names(removed)}',
      ];
      return '$prefix${parts.join(', ')}';
    }
    final parts = <String>[];
    for (final key in {...bf.keys, ...af.keys}) {
      final b = bf[key];
      final a = af[key];
      final secretChanged = before.secrets?[key] != after.secrets?[key];
      if (b == a && !secretChanged) continue;
      final name = key.startsWith(r'$') ? key.substring(1) : key;
      parts.add('$name ${b ?? '(none)'} → ${a ?? '(none)'}');
    }
    final shown = parts.take(maxDiffNames).toList();
    if (parts.length > maxDiffNames) {
      shown.add('+${parts.length - maxDiffNames} more');
    }
    return '$prefix${shown.join(', ')}';
  }
  return '$prefix${before.text} → ${after.text}';
}

// `a, b, c` for at most [maxDiffNames] names, then `+N more`.
String _names(Iterable<String> names) {
  final all = names.toList();
  final shown = all.take(maxDiffNames).join(', ');
  return all.length > maxDiffNames
      ? '$shown +${all.length - maxDiffNames} more'
      : shown;
}

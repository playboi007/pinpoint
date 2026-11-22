// Plain Dart: no `dart:ui` and no `package:flutter`.

/// Typed reads of decoded JSON. A value of the wrong type gives the fallback
/// (null, or an empty collection). These never throw.
library;

/// [value] as a map, or an empty one.
Map<String, Object?> asJsonMap(Object? value) =>
    value is Map<String, Object?> ? value : const <String, Object?>{};

/// [value] as a list, or an empty one.
List<Object?> asJsonList(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

String? asString(Object? value) => value is String ? value : null;

/// [value] when it is a string with text in it.
String? nonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int? asInt(Object? value) => value is int ? value : null;

/// Any JSON number as a double. JSON does not tell `1` from `1.0`.
double? asDouble(Object? value) => value is num ? value.toDouble() : null;

DateTime? asDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// The string items of [value]. Other items are dropped.
List<String> asStrings(Object? value) => [
  for (final item in asJsonList(value))
    if (item is String) item,
];

/// The entries of [value] whose value is a string.
Map<String, String> asStringMap(Object? value) => {
  for (final MapEntry(:key, :value) in asJsonMap(value).entries)
    if (value is String) key: value,
};

/// [value] as JSON writes it: `96`, not `96.0`. Null for a non-number.
String? jsonNumberText(Object? value) => switch (value) {
  final int n => '$n',
  final double n when n.isFinite =>
    n == n.truncateToDouble() ? '${n.toInt()}' : '$n',
  _ => null,
};

/// Reads of one key of a decoded JSON object.
extension JsonRead on Map<String, Object?> {
  String? str(String key) => asString(this[key]);

  DateTime? date(String key) => asDate(this[key]);

  /// The map at [key] when it has entries and passes [where], else null.
  Map<String, Object?>? nonEmptyMap(
    String key, {
    bool Function(Map<String, Object?> map)? where,
  }) {
    final map = asJsonMap(this[key]);
    return map.isNotEmpty && (where?.call(map) ?? true) ? map : null;
  }

  /// The list at [key], each item read by [parse]. Items it rejects are dropped.
  List<T> items<T extends Object>(String key, T? Function(Object?) parse) => [
    for (final value in asJsonList(this[key])) ?parse(value),
  ];
}

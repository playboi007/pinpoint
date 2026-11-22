part of 'annotation.dart';

/// [value] for JSON: null when not finite (JSON has no `Infinity` or `NaN`,
/// and `jsonEncode` throws on them), rounded to 0.01, and an `int` when
/// whole.
num? jsonNumber(double? value) {
  if (value == null || !value.isFinite) return null;
  final rounded = (value * 100).roundToDouble() / 100;
  return rounded == rounded.truncateToDouble() ? rounded.toInt() : rounded;
}

/// [time] in UTC to the second, for example `2026-11-10T14:32:05Z`.
String formatTimestamp(DateTime time) {
  final t = time.toUtc();
  return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-'
      '${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}Z';
}

/// A new note id, for example `pp_20261110_143205_a1f3`: the UTC time to
/// the second and four random hex digits.
///
/// It becomes a file name on the receiver, so it holds only `[a-z0-9_]`.
String annotationId(DateTime time, math.Random random) {
  final t = time.toUtc();
  final suffix = random.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
  return 'pp_${t.year.toString().padLeft(4, '0')}${_two(t.month)}'
      '${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}'
      '_$suffix';
}

/// [text] cut to at most [max] UTF-16 code units, ending in "…" when cut.
/// A surrogate pair is never split, so the result always encodes.
String clipText(String text, int max) {
  if (text.length <= max) return text;
  if (max <= 1) return '…';
  var end = max - 1;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return '${text.substring(0, end)}…';
}

String _two(int n) => n.toString().padLeft(2, '0');

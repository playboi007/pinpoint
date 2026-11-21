import 'package:flutter/widgets.dart';

/// The keys of the story. The State tab and the watch card show the same
/// story ([StoryView]), so they share these ([StateTab] repeats them for its
/// tests).
class StateChain {
  const StateChain._();

  /// The folder button of one row that has a source location. [id] is
  /// `r<n>` for a reader, `r<n>.d<m>` for one of its objects, and
  /// `<cause>.n<m>` or `<cause>.s<m>` for a notify or setState row of a
  /// cause block.
  static Key locationKey(String id) =>
      ValueKey<String>('pinpoint.stateTab.where.$id');

  /// The tip that the folder button shows after 2 s of hover.
  static const Key locationTipKey = ValueKey<String>(
    'pinpoint.stateTab.where.tip',
  );

  /// The popover of the folder button: short path and line.
  static const Key locationPopoverKey = ValueKey<String>(
    'pinpoint.stateTab.where.popover',
  );

  /// The Copy button of that popover.
  static const Key locationCopyKey = ValueKey<String>(
    'pinpoint.stateTab.where.copy',
  );

  /// One cause block: [id] is `c<cause>`, or `f<frame>` for a change with
  /// no cause.
  static Key causeKey(String id) => ValueKey<String>('pinpoint.stateTab.$id');

  /// The coupling hint of one cause block.
  static Key hintKey(String id) =>
      ValueKey<String>('pinpoint.stateTab.$id.hint');
}

/// [text] with the folder button [where] at the end of its row, if any.
Widget locatedRow(Widget? where, Widget text) {
  if (where == null) return text;
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(child: text),
      const SizedBox(width: 4),
      where,
    ],
  );
}

/// [value] as a list, or an empty one.
List<Object?> asList(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

/// `HH:MM:SS` of [time] in the local zone.
String formatClock(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

/// `Class.method` as `method()`; a top-level function keeps its name.
String methodLabel(Object? method) {
  if (method is! String || method.isEmpty) return '';
  final dot = method.lastIndexOf('.');
  final name = dot < 0 ? method : method.substring(dot + 1);
  return name.isEmpty ? '' : '$name()';
}

/// `lib/x.dart:88` for a frame's file and line; a `package:app/x.dart` file
/// shows as `lib/x.dart`. Empty when there is no file.
String whereLabel(Object? file, Object? line) {
  if (file is! String || file.isEmpty) return '';
  var shown = file;
  if (shown.startsWith('package:')) {
    final slash = shown.indexOf('/');
    shown = slash < 0 ? shown : 'lib/${shown.substring(slash + 1)}';
  }
  return line is int && line > 0 ? '$shown:$line' : shown;
}

/// `HH:MM:SS.mmm` of [epochMs] in the local zone: the clock of a block, shown
/// on hover.
String formatClockMs(int epochMs) {
  final time = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${formatClock(time)}.${time.millisecond.toString().padLeft(3, '0')}';
}

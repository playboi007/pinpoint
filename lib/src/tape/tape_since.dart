part of 'tape_recorder.dart';

/// Where a saved tape starts: `start`, a mark, or seconds back.
sealed class TapeSince {
  const TapeSince();

  /// App start: a full tape when nothing was lost.
  static const TapeSince start = _SinceStart();

  /// `start`, `mark` (the last), `mark:N` (the Nth held, from 1), a number
  /// of seconds, or `"30s"`. Throws a [FormatException] with a message for
  /// the agent.
  static TapeSince parse(Object? value) {
    switch (value) {
      case null || 'start':
        return start;
      case 'mark':
        return const SinceMark(null);
      case final num seconds when seconds > 0:
        return SinceSeconds(seconds.toDouble());
      case final String text:
        if (text.startsWith('mark:')) {
          final n = int.tryParse(text.substring(5));
          if (n != null && n > 0) return SinceMark(n);
        }
        final match = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(text);
        if (match != null) return SinceSeconds(double.parse(match[1]!));
    }
    throw FormatException(
      'since is "start", "mark", "mark:N", seconds back (30 or "30s"); '
      'got $value',
    );
  }

  /// The 1-based mark index, or null for "the last mark" and other kinds.
  int? get markIndex => null;
}

class _SinceStart extends TapeSince {
  const _SinceStart();
}

/// From a mark: the Nth held ([index], from 1) or the last (null).
class SinceMark extends TapeSince {
  const SinceMark(this.index);

  final int? index;

  @override
  int? get markIndex => index;
}

/// From [seconds] before now.
class SinceSeconds extends TapeSince {
  const SinceSeconds(this.seconds);

  final double seconds;
}

/// From a recorder time [t] (ms since the recording began): the comment
/// form's range picker.
class SinceTime extends TapeSince {
  const SinceTime(this.t);

  final int t;
}

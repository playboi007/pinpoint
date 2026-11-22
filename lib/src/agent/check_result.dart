part of 'checks.dart';

/// The outcome of one check of a note.
@immutable
class CheckResult {
  const CheckResult({
    required this.type,
    required this.passed,
    required this.message,
    this.measured,
  });

  /// A failed check: [message] says why.
  const CheckResult.fail(this.type, this.message, {this.measured})
    : passed = false;

  /// For example `no_overflow`.
  final String type;

  final bool passed;

  /// One line: what was measured, for example `Row overflows by 72 px on
  /// the right`.
  final String message;

  /// The measured value, as JSON: a number, a size or a list.
  final Object? measured;

  Map<String, Object?> toJson() => {
    'type': type,
    'passed': passed,
    'message': message,
    'measured': ?measured,
  };

  @override
  String toString() => '${passed ? 'PASS' : 'FAIL'} $type: $message';
}

/// A check the comment form offers in its menu.
@immutable
class CheckOption {
  const CheckOption(this.label, this.check);

  /// For example `No overflow`.
  final String label;

  /// The check as it goes into the note, for example `{type: no_overflow}`.
  final Map<String, Object?> check;

  String get type => check['type']! as String;
}

/// The checks the comment form offers: the ones that need no second
/// widget. `text_contains` is offered too, with the selected widget's
/// text, when it shows text. `gap_to`, `aligned_with`, `min_size` and
/// `max_size` need values the form does not ask for; an agent or a note
/// made by hand can carry them.
const List<CheckOption> commentChecks = [
  CheckOption('Visible', {'type': 'visible'}),
  CheckOption('No overflow', {'type': 'no_overflow'}),
  CheckOption('Text not cut off', {'type': 'not_truncated'}),
  CheckOption('Inside its parent', {'type': 'within_parent'}),
  CheckOption('Tap target at least 48', {'type': 'tap_target_min', 'min': 48}),
  CheckOption('Contrast at least 4.5:1', {'type': 'contrast_min', 'min': 4.5}),
];

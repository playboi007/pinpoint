import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter/widgets.dart';

/// Pinpoint's motion: every duration and curve its own UI uses.
///
/// The rule: the more often a part is used, the less it moves.
///
/// | tier | for | duration |
/// |---|---|---|
/// | [snap] | hover, select, tabs, typing, steppers: used all the time | 80 ms or none |
/// | [quick] | toasts, a new pin, Send to Sending, toggles: sometimes | 150 ms |
/// | [moderate] | panels and sections that open, fades | 250 ms |
/// | [expressive] | seldom-used moments: theme switch, scan, verify, replay | 420 ms |
///
/// Two things change the durations, never the design values:
///
/// - **Reduced motion.** When the system asks for it
///   (`MediaQuery.disableAnimations`; on web the `prefers-reduced-motion`
///   setting), every duration is zero: things change at once.
/// - **The What-if slow motion.** It sets `timeDilation`, which slows every
///   animation in the app, Pinpoint's too. Pinpoint divides by it, so its
///   own UI keeps its speed while the app runs slowly.
///
/// No Pinpoint animation repeats forever: each frame is a trace event.
/// [DraftSpinner] runs only while something loads, and the range picker's
/// hatching only while a handle is held.
@immutable
class PinPointMotion {
  const PinPointMotion({this.reduced = false, this.dilation = 1});

  /// The motion for [context]: reduced when its [MediaQuery] says so, and
  /// corrected for the current `timeDilation`.
  static PinPointMotion of(BuildContext context) => PinPointMotion(
    reduced: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
    dilation: timeDilation,
  );

  /// Whether the system asked for reduced motion.
  final bool reduced;

  /// The `timeDilation` the durations correct for.
  final double dilation;

  // Design values. Read the getters below; these are for documents and
  // tests.
  static const Duration snapBase = Duration(milliseconds: 80);
  static const Duration quickBase = Duration(milliseconds: 150);
  static const Duration moderateBase = Duration(milliseconds: 250);
  static const Duration expressiveBase = Duration(milliseconds: 420);

  /// Often-used parts. Prefer no motion at all there.
  Duration get snap => scaled(snapBase);

  /// Sometimes-used parts.
  Duration get quick => scaled(quickBase);

  /// Panels and sections that open or close; fades.
  Duration get moderate => scaled(moderateBase);

  /// Seldom-used moments, where motion can be fun.
  Duration get expressive => scaled(expressiveBase);

  /// [base] as it must be given to an animation: zero with reduced
  /// motion, else divided by the slow motion.
  Duration scaled(Duration base) {
    if (reduced) return Duration.zero;
    if (dilation == 1) return base;
    return base * (1 / dilation);
  }

  /// [base] for an animation that tells something (a spinner, a progress
  /// bar): never zero, only corrected for the slow motion.
  Duration informative(Duration base) =>
      dilation == 1 ? base : base * (1 / dilation);

  /// Things that come in: fast at first, then settle.
  static const Curve enter = Curves.easeOutCubic;

  /// Things that go: slow at first, then away.
  static const Curve exit = Curves.easeInCubic;

  /// Things that move from one place to another.
  static const Curve move = Curves.easeInOutCubic;

  /// A small overshoot, for a grip that grows or a stamp that lands.
  static const Curve spring = Curves.easeOutBack;

  @override
  bool operator ==(Object other) =>
      other is PinPointMotion &&
      other.reduced == reduced &&
      other.dilation == dilation;

  @override
  int get hashCode => Object.hash(reduced, dilation);
}

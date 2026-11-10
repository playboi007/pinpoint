import 'package:flutter/foundation.dart';

import '../sink/pinpoint_sink.dart';
import 'keymap.dart';

/// Settings for [PinPointWrapper].
///
/// Later milestones add the bridge URL and more.
@immutable
class PinPointConfig {
  const PinPointConfig({
    this.enabled = kDebugMode,
    this.showLauncher = true,
    this.shortcut = PinPointShortcut.altShiftC,
    this.projectRoot = const String.fromEnvironment('PINPOINT_ROOT'),
    this.localPathHints = const <String>[],
    this.sinks = const <PinPointSink>[],
  });

  /// Where Send delivers each note, in order. With none, Send reports that
  /// nothing took the note; Copy as Markdown still works.
  final List<PinPointSink> sinks;

  /// When false, the wrapper returns its child untouched and installs
  /// nothing. Defaults to [kDebugMode], so release builds carry nothing.
  final bool enabled;

  /// Whether to show the draggable launcher button.
  ///
  /// Keep it on where the shortcut may not reach Flutter (some browsers and
  /// operating systems take certain key combinations first).
  final bool showLauncher;

  /// Starts and stops picking. Defaults to Alt+Shift+C.
  final PinPointShortcut shortcut;

  /// The project's root directory. Source paths under it count as local and
  /// are shown relative to it.
  ///
  /// Defaults to the `PINPOINT_ROOT` define:
  /// `flutter run -d chrome --dart-define=PINPOINT_ROOT=$(pwd)`. Empty means
  /// not set; then every path outside the Flutter SDK, the Dart SDK and the
  /// pub cache counts as local.
  final String projectRoot;

  /// Paths (or `package:` prefixes) that count as local even outside
  /// [projectRoot], for packages of a monorepo. A path dependency looks
  /// external unless it is listed here.
  final List<String> localPathHints;
}

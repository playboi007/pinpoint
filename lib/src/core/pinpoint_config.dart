import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeData;

import '../sink/pinpoint_sink.dart';
import 'keymap.dart';

/// Settings for [PinPointWrapper].
///
/// Later milestones add more.
@immutable
class PinPointConfig {
  const PinPointConfig({
    this.enabled = kDebugMode,
    this.showLauncher = true,
    this.shortcut = PinPointShortcut.altShiftC,
    this.projectRoot = const String.fromEnvironment('PINPOINT_ROOT'),
    this.localPathHints = const <String>[],
    this.sinks = const <PinPointSink>[],
    this.bridgeUrl,
    this.maxScreenshotWidth = 1600,
    this.themeVariants = const <String, ThemeData>{},
  }) : assert(maxScreenshotWidth > 0);

  /// The bridge (`dart run pinpoint:bridge`), for example
  /// `http://127.0.0.1:4747`. The app loads its pins from it at start, stores
  /// drafts on it, and polls it for the agent's changes while the overlay is
  /// active.
  ///
  /// Null: the bridge of the first `HttpSink` in [sinks] that posts to
  /// `/annotations`, such as `HttpSink.bridge()`. With neither, notes and
  /// pins live in this tab only.
  final Uri? bridgeUrl;

  /// Themes the what-if panel offers by name, for apps that switch themes
  /// through their own state or use `ThemeExtension` tokens. When set, the
  /// panel lists these instead of the app's `theme` and `darkTheme`.
  final Map<String, ThemeData> themeVariants;

  /// The widest screenshot, in image pixels. A wider crop is captured at a
  /// lower pixel ratio. PNG encoding takes most of a capture's time, so this
  /// is what keeps a capture inside its 300 ms budget.
  final int maxScreenshotWidth;

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

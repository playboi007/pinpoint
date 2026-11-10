import 'package:flutter/foundation.dart';

import 'keymap.dart';

/// Settings for [PinPointWrapper].
///
/// Later milestones add sinks, the bridge URL, the project root and more.
@immutable
class PinPointConfig {
  const PinPointConfig({
    this.enabled = kDebugMode,
    this.showLauncher = true,
    this.shortcut = PinPointShortcut.altShiftC,
  });

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
}

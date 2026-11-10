import 'package:flutter/foundation.dart';

/// Settings for [PinPointWrapper].
///
/// Later milestones add sinks, the bridge URL, the project root and more.
@immutable
class PinPointConfig {
  const PinPointConfig({this.enabled = kDebugMode, this.showLauncher = true});

  /// When false, the wrapper returns its child untouched and installs
  /// nothing. Defaults to [kDebugMode], so release builds carry nothing.
  final bool enabled;

  /// Whether to show the draggable launcher button.
  final bool showLauncher;
}

import 'package:flutter/foundation.dart';

/// Whether the app's semantics are shown while Pinpoint is active.
///
/// While a mode is active, `PinPointWrapper` hides the app's semantics. On
/// web, an app that keeps semantics on (`ensureSemantics()` at startup) gets
/// a DOM element over each tappable widget, and the engine's click
/// debouncer sends a quick click on one to the widget as
/// `SemanticsAction.tap`. That tap never goes through the hit test, so it
/// passed the pointer trap and ran the app's button while picking.
///
/// Code that reads the app's semantics while a mode is active (the
/// accessibility audit, the `tap_target_min` check) calls [read] first and
/// waits a frame, so the tree is built again.
abstract final class AppSemantics {
  static final ValueNotifier<int> _readers = ValueNotifier<int>(0);

  /// How many readers need the app's semantics now.
  static ValueListenable<int> get readers => _readers;

  /// Shows the app's semantics until the returned callback is called. The
  /// callback acts once; later calls do nothing.
  static VoidCallback read() {
    _readers.value++;
    var done = false;
    return () {
      if (done) return;
      done = true;
      _readers.value--;
    };
  }
}

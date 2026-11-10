import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pinpoint_controller.dart';

/// Which modifier keys are held.
typedef KeyModifiers = ({bool alt, bool shift, bool control, bool meta});

/// Reads [KeyModifiers] from [keyboard].
KeyModifiers modifiersOf(HardwareKeyboard keyboard) => (
  alt: keyboard.isAltPressed,
  shift: keyboard.isShiftPressed,
  control: keyboard.isControlPressed,
  meta: keyboard.isMetaPressed,
);

/// A key plus an exact set of modifiers.
@immutable
class PinPointShortcut {
  const PinPointShortcut(
    this.key, {
    this.physicalKey,
    this.alt = false,
    this.shift = false,
    this.control = false,
    this.meta = false,
  });

  /// The default: Alt+Shift+C.
  ///
  /// Not Ctrl/Cmd+Shift+C, which Chrome uses for its own element inspector.
  /// Some combinations never reach Flutter on web because the browser or the
  /// OS takes them first. That is why the shortcut is configurable and the
  /// launcher button is always offered.
  static const PinPointShortcut altShiftC = PinPointShortcut(
    LogicalKeyboardKey.keyC,
    physicalKey: PhysicalKeyboardKey.keyC,
    alt: true,
    shift: true,
  );

  final LogicalKeyboardKey key;

  /// Also accepted as a match. With Alt held, macOS produces another
  /// character (Option+Shift+C types "Ç"), and on web the logical key can
  /// follow that character. The physical key does not change.
  final PhysicalKeyboardKey? physicalKey;

  final bool alt;
  final bool shift;
  final bool control;
  final bool meta;

  /// Whether [event] is this shortcut with exactly these modifiers held.
  bool matches(KeyEvent event, KeyModifiers modifiers) {
    final keyMatches =
        event.logicalKey == key ||
        (physicalKey != null && event.physicalKey == physicalKey);
    return keyMatches &&
        modifiers.alt == alt &&
        modifiers.shift == shift &&
        modifiers.control == control &&
        modifiers.meta == meta;
  }

  /// For tooltips, for example "Alt+Shift+C".
  String get label => [
    if (control) 'Ctrl',
    if (meta) 'Meta',
    if (alt) 'Alt',
    if (shift) 'Shift',
    key.keyLabel,
  ].join('+');

  @override
  bool operator ==(Object other) =>
      other is PinPointShortcut &&
      other.key == key &&
      other.physicalKey == physicalKey &&
      other.alt == alt &&
      other.shift == shift &&
      other.control == control &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, physicalKey, alt, shift, control, meta);
}

/// What a key press asks Pinpoint to do.
enum KeyAction {
  /// Start picking, or stop.
  toggle,

  /// One step back (Esc).
  back,

  /// Pause or resume the app's tickers (P).
  freeze,

  /// Select the next local ancestor (Arrow Up or `[`).
  chainUp,

  /// Select the next local widget back toward the picked one (Arrow Down or
  /// `]`).
  chainDown,

  /// Select the parent in the full chain, framework widgets included
  /// (Alt+Arrow Up).
  chainUpAll,

  /// Select the child in the full chain (Alt+Arrow Down).
  chainDownAll;

  /// Whether a held key repeats the action. Navigation does; toggling,
  /// going back and freezing act once per press.
  bool get repeats => switch (this) {
    chainUp || chainDown || chainUpAll || chainDownAll => true,
    toggle || back || freeze => false,
  };
}

/// The action for [event] in [mode], or null when the key is not Pinpoint's.
///
/// Key down and repeat events can match; key up never does. Only keys that
/// Pinpoint uses in the current mode match, so everything else stays with the
/// app (plain Esc in idle, for example, still closes the app's dialogs).
KeyAction? keyActionFor(
  KeyEvent event, {
  required PinPointMode mode,
  required PinPointShortcut shortcut,
  required KeyModifiers modifiers,
}) {
  if (event is KeyUpEvent) return null;
  if (shortcut.matches(event, modifiers)) return KeyAction.toggle;

  // Chain navigation needs a selection, which exists only while picking or
  // commenting. Milestone 5: while the comment field has focus, arrow keys
  // must edit its text, so navigation in commenting uses the breadcrumb
  // only. Turn these off there when the field exists.
  final selecting =
      mode == PinPointMode.picking || mode == PinPointMode.commenting;
  final altOnly =
      modifiers.alt &&
      !modifiers.shift &&
      !modifiers.control &&
      !modifiers.meta;
  if (selecting && altOnly) {
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      return KeyAction.chainUpAll;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      return KeyAction.chainDownAll;
    }
  }

  final plain =
      !modifiers.alt &&
      !modifiers.shift &&
      !modifiers.control &&
      !modifiers.meta;
  if (!plain) return null;

  if (mode != PinPointMode.idle &&
      event.logicalKey == LogicalKeyboardKey.escape) {
    return KeyAction.back;
  }
  // Picking only: the comment field (Milestone 5) needs a plain P.
  if (mode == PinPointMode.picking &&
      (event.logicalKey == LogicalKeyboardKey.keyP ||
          event.physicalKey == PhysicalKeyboardKey.keyP)) {
    return KeyAction.freeze;
  }
  if (selecting) {
    // Brackets also by physical key: on other layouts the key types
    // another character.
    if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.bracketLeft ||
        event.physicalKey == PhysicalKeyboardKey.bracketLeft) {
      return KeyAction.chainUp;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.bracketRight ||
        event.physicalKey == PhysicalKeyboardKey.bracketRight) {
      return KeyAction.chainDown;
    }
  }
  return null;
}

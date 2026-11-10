import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

/// What Pinpoint is doing right now.
enum PinPointMode {
  /// Pinpoint is out of the way. The app gets every pointer and key event.
  idle,

  /// The pointer trap covers the app. Hover outlines, a click selects.
  picking,

  /// A widget is selected and the comment form is open.
  commenting,

  /// The note is on its way to the sinks.
  sending,
}

/// The mode state machine, plus hover, selection and freeze state.
///
/// Allowed transitions:
///
/// ```text
/// idle --startPicking--> picking --select--> commenting --submit--> sending
///   ^                                                                  |
///   +------------------------- sendSucceeded --------------------------+
/// sending --sendFailed--> commenting
/// back (Esc): sending -> commenting -> picking -> idle
/// stop: any -> idle
/// ```
///
/// Each transition method returns `true` when it changed the mode, and
/// `false` (with no change and no notification) when the current mode does
/// not allow it.
///
/// Listeners are notified on mode, selection and freeze changes. Hover is a
/// separate [ValueListenable], so pointer moves do not rebuild everything
/// that watches the mode.
class PinPointController extends ChangeNotifier {
  PinPointMode _mode = PinPointMode.idle;
  bool _frozen = false;
  Offset? _selectedPosition;
  final ValueNotifier<Offset?> _hovered = ValueNotifier<Offset?>(null);

  /// The current mode.
  PinPointMode get mode => _mode;

  /// Whether any mode other than [PinPointMode.idle] is active.
  bool get isActive => _mode != PinPointMode.idle;

  /// Whether the app's tickers are paused.
  ///
  /// Freeze is independent of [mode]: stopping does not unfreeze.
  bool get frozen => _frozen;

  /// The latest pointer position while picking, in global logical pixels.
  ValueListenable<Offset?> get hovered => _hovered;

  /// Where the user clicked to select, in global logical pixels.
  ///
  /// Milestone 2 replaces this with a pick result that holds the element.
  Offset? get selectedPosition => _selectedPosition;

  /// idle -> picking.
  bool startPicking() => _move(from: PinPointMode.idle, to: PinPointMode.picking);

  /// picking -> commenting, selecting what is at [position].
  bool select(Offset position) {
    if (_mode != PinPointMode.picking) return false;
    _selectedPosition = position;
    return _move(from: PinPointMode.picking, to: PinPointMode.commenting);
  }

  /// commenting -> sending.
  bool submit() =>
      _move(from: PinPointMode.commenting, to: PinPointMode.sending);

  /// sending -> idle, after every sink accepted the note.
  bool sendSucceeded() {
    if (_mode != PinPointMode.sending) return false;
    _selectedPosition = null;
    return _move(from: PinPointMode.sending, to: PinPointMode.idle);
  }

  /// sending -> commenting, so the user can retry or copy the note.
  bool sendFailed() =>
      _move(from: PinPointMode.sending, to: PinPointMode.commenting);

  /// One step back, as Esc does. Going back to picking keeps the selection.
  bool back() {
    switch (_mode) {
      case PinPointMode.idle:
        return false;
      case PinPointMode.picking:
        stop();
        return true;
      case PinPointMode.commenting:
        return _move(from: _mode, to: PinPointMode.picking);
      case PinPointMode.sending:
        return _move(from: _mode, to: PinPointMode.commenting);
    }
  }

  /// Any mode -> idle. Drops hover and selection.
  void stop() {
    if (_mode == PinPointMode.idle) return;
    _selectedPosition = null;
    _move(from: _mode, to: PinPointMode.idle);
  }

  /// What the shortcut and the launcher do: start picking, or stop.
  void toggle() {
    if (_mode == PinPointMode.idle) {
      startPicking();
    } else {
      stop();
    }
  }

  /// Records the pointer position. Ignored unless picking.
  void hover(Offset? position) {
    if (_mode != PinPointMode.picking) return;
    _hovered.value = position;
  }

  /// Pauses or resumes the app's tickers.
  void toggleFreeze() {
    _frozen = !_frozen;
    notifyListeners();
  }

  /// Drops the selection, for example on hot reload, when held references
  /// may be stale. Commenting falls back to picking, since there is nothing
  /// left to comment on.
  void clearSelection() {
    if (_selectedPosition == null) return;
    _selectedPosition = null;
    if (_mode == PinPointMode.commenting) _mode = PinPointMode.picking;
    notifyListeners();
  }

  bool _move({required PinPointMode from, required PinPointMode to}) {
    if (_mode != from) return false;
    _mode = to;
    if (to != PinPointMode.picking) _hovered.value = null;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }
}

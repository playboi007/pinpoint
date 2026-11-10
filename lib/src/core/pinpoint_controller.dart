import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../search/pick_result.dart';

/// What Pinpoint is doing right now.
enum PinPointMode {
  /// Pinpoint is out of the way. The app gets every pointer and key event.
  idle,

  /// The pointer trap covers the app. Hover outlines, a click selects.
  picking,

  /// A widget is selected and the comment form is open. Hover still
  /// outlines, and a click selects again.
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
/// commenting --select--> commenting (a new selection)
/// back (Esc): sending -> commenting -> picking -> idle
/// stop: any -> idle
/// ```
///
/// Each transition method returns `true` when it changed the mode, and
/// `false` (with no change and no notification) when the current mode does
/// not allow it.
///
/// Listeners are notified on mode and freeze changes. Hover and selection
/// are separate [ValueListenable]s, so pointer moves and an outline that
/// follows its widget do not rebuild everything that watches the mode.
class PinPointController extends ChangeNotifier {
  PinPointMode _mode = PinPointMode.idle;
  bool _frozen = false;
  final ValueNotifier<PickResult?> _hovered = ValueNotifier<PickResult?>(null);
  final ValueNotifier<PickResult?> _selection = ValueNotifier<PickResult?>(
    null,
  );

  /// The current mode.
  PinPointMode get mode => _mode;

  /// Whether any mode other than [PinPointMode.idle] is active.
  bool get isActive => _mode != PinPointMode.idle;

  /// Whether the app's tickers are paused.
  ///
  /// Freeze is independent of [mode]: stopping does not unfreeze.
  bool get frozen => _frozen;

  /// What is under the pointer while picking or commenting.
  ValueListenable<PickResult?> get hovered => _hovered;

  /// The selected widget. Set from commenting on; kept when Esc goes back to
  /// picking.
  ValueListenable<PickResult?> get selection => _selection;

  /// Top-left of the info panel after a drag, in global logical pixels.
  /// Null means the default corner. Kept here so the panel's place survives
  /// reselection and stopping. Setting it notifies no one: the panel that
  /// moved repaints itself.
  Offset? panelPosition;

  /// Whether hover is recorded in the current mode.
  bool get canHover =>
      _mode == PinPointMode.picking || _mode == PinPointMode.commenting;

  /// idle -> picking.
  bool startPicking() =>
      _move(from: PinPointMode.idle, to: PinPointMode.picking);

  /// picking -> commenting, selecting [pick]. In commenting, replaces the
  /// selection and stays in commenting.
  bool select(PickResult pick) {
    if (_mode == PinPointMode.commenting) {
      _selection.value = pick;
      return true;
    }
    if (_mode != PinPointMode.picking) return false;
    _selection.value = pick;
    return _move(from: PinPointMode.picking, to: PinPointMode.commenting);
  }

  /// commenting -> sending.
  bool submit() =>
      _move(from: PinPointMode.commenting, to: PinPointMode.sending);

  /// sending -> idle, after every sink accepted the note.
  bool sendSucceeded() {
    if (_mode != PinPointMode.sending) return false;
    _selection.value = null;
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
    _selection.value = null;
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

  /// Records what is under the pointer. Ignored unless [canHover].
  void hover(PickResult? pick) {
    if (!canHover) return;
    _hovered.value = pick;
  }

  /// Puts a re-read [pick] in place of the selection, for an outline that
  /// follows its widget. Null means the widget is gone, which clears the
  /// selection as [clearSelection] does. Does nothing without a selection.
  void updateSelection(PickResult? pick) {
    if (_selection.value == null) return;
    if (pick == null) {
      clearSelection();
    } else {
      _selection.value = pick;
    }
  }

  /// Pauses or resumes the app's tickers.
  void toggleFreeze() {
    _frozen = !_frozen;
    notifyListeners();
  }

  /// Drops hover and selection, for example on hot reload, when held
  /// elements may be stale. Commenting falls back to picking, since there is
  /// nothing left to comment on.
  void clearSelection() {
    _hovered.value = null;
    if (_selection.value == null) return;
    _selection.value = null;
    if (_mode == PinPointMode.commenting) _mode = PinPointMode.picking;
    notifyListeners();
  }

  bool _move({required PinPointMode from, required PinPointMode to}) {
    if (_mode != from) return false;
    _mode = to;
    if (!canHover) _hovered.value = null;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _hovered.dispose();
    _selection.dispose();
    super.dispose();
  }
}

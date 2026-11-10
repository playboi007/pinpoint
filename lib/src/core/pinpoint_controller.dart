import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../model/annotation.dart';
import '../search/pick_result.dart';
import 'note_book.dart';

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

/// The comment being written: text, intent and whether to attach a
/// screenshot.
///
/// It lives in the controller, not in the form, so it survives Esc, a new
/// selection, a closed panel and a failed send. Only a successful send
/// clears the text.
class CommentDraft extends ChangeNotifier {
  /// The comment field's text. Listen to it for edits; this draft notifies
  /// only for [intent] and [includeScreenshot].
  final TextEditingController text = TextEditingController();

  AnnotationIntent _intent = AnnotationIntent.improve;
  bool _includeScreenshot = true;

  AnnotationIntent get intent => _intent;
  set intent(AnnotationIntent value) {
    if (value == _intent) return;
    _intent = value;
    notifyListeners();
  }

  /// On by default. The screenshot can show personal data that text
  /// masking never sees, so the form shows this box on every send.
  bool get includeScreenshot => _includeScreenshot;
  set includeScreenshot(bool value) {
    if (value == _includeScreenshot) return;
    _includeScreenshot = value;
    notifyListeners();
  }

  /// Whether anything but white space is typed.
  bool get hasText => text.text.trim().isNotEmpty;

  /// Whether an input method is composing text (for example Japanese input
  /// before the candidate is chosen). Pinpoint's keys leave it alone then.
  bool get composing {
    final range = text.value.composing;
    return range.isValid && !range.isCollapsed;
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }
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
/// sending --draftSaved--> picking
/// commenting --select--> commenting (a new selection)
/// openPin: idle, picking or commenting -> commenting (a pin's note)
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
  final ValueNotifier<bool> _measuring = ValueNotifier<bool>(false);

  /// The comment being written. Kept until a send succeeds.
  final CommentDraft draft = CommentDraft();

  /// Drafts and sent notes, shown as pins.
  final NoteBook notes = NoteBook();

  final ValueNotifier<String?> _openNote = ValueNotifier<String?>(null);

  /// The id of the note whose pin was clicked. While set, the panel shows
  /// that note instead of the comment form.
  ValueListenable<String?> get openNote => _openNote;

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

  /// Whether Alt is held, so the rulers measure from the selection to the
  /// hovered widget instead of to the selection's ancestor.
  ValueListenable<bool> get measuring => _measuring;

  /// Records whether Alt is held. Ignored in idle.
  void setMeasuring(bool held) {
    _measuring.value = held && isActive;
  }

  /// Whether hover is recorded in the current mode.
  bool get canHover =>
      _mode == PinPointMode.picking || _mode == PinPointMode.commenting;

  /// idle -> picking.
  bool startPicking() =>
      _move(from: PinPointMode.idle, to: PinPointMode.picking);

  /// picking -> commenting, selecting [pick]. In commenting, replaces the
  /// selection and stays in commenting, unless a comment is typed.
  bool select(PickResult pick) {
    if (_mode == PinPointMode.commenting) {
      // A click outside the panel is ambiguous. With a comment typed it does
      // nothing, so a stray click never takes the comment off its widget.
      // The breadcrumb, or Esc and a click, still choose another one.
      if (draft.hasText && _openNote.value == null) return false;
      _openNote.value = null;
      _selection.value = pick;
      return true;
    }
    if (_mode != PinPointMode.picking) return false;
    _openNote.value = null;
    _selection.value = pick;
    return _move(from: PinPointMode.picking, to: PinPointMode.commenting);
  }

  /// Opens the note [id] on [pick], its pin's widget, as a click on the pin
  /// does: from any mode to commenting, with the panel showing the note. A
  /// comment being written stays in [draft].
  ///
  /// Returns false while sending, or when there is no such note.
  bool openPin(String id, PickResult pick) {
    if (_mode == PinPointMode.sending || notes.byId(id) == null) return false;
    _openNote.value = id;
    _selection.value = pick;
    if (_mode == PinPointMode.commenting) return true;
    _mode = PinPointMode.commenting;
    notifyListeners();
    return true;
  }

  /// Closes the open note. Keeps the selection and the mode.
  void closeNote() {
    _openNote.value = null;
  }

  /// sending -> picking, after a draft was saved: ready for the next
  /// widget. Drops the selection, which now has its pin.
  bool draftSaved() {
    if (_mode != PinPointMode.sending) return false;
    _selection.value = null;
    _openNote.value = null;
    return _move(from: PinPointMode.sending, to: PinPointMode.picking);
  }

  /// commenting -> sending.
  bool submit() =>
      _move(from: PinPointMode.commenting, to: PinPointMode.sending);

  /// sending -> idle, after every sink accepted the note.
  bool sendSucceeded() {
    if (_mode != PinPointMode.sending) return false;
    _selection.value = null;
    _openNote.value = null;
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
    _openNote.value = null;
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

  /// Moves the selection along its chain: to the next local widget above
  /// it when [up], else back toward the picked widget. With [localOnly]
  /// false, one step in the full chain, framework widgets included.
  ///
  /// Returns whether the selection changed. Does nothing without a
  /// selection, or at the end of the chain.
  bool stepSelection({required bool up, bool localOnly = true}) {
    final current = _selection.value;
    if (current == null) return false;
    final next = current.stepped(up: up, localOnly: localOnly);
    if (identical(next, current)) return false;
    _selection.value = next;
    return true;
  }

  /// Selects entry [chainIndex] of the selection's chain, as a click on a
  /// breadcrumb does. Keeps the mode.
  ///
  /// Returns whether the selection changed.
  bool selectChainIndex(int chainIndex) {
    final current = _selection.value;
    if (current == null) return false;
    final next = current.selecting(chainIndex);
    if (identical(next, current)) return false;
    _selection.value = next;
    return true;
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
    _openNote.value = null;
    if (_mode == PinPointMode.commenting) _mode = PinPointMode.picking;
    notifyListeners();
  }

  bool _move({required PinPointMode from, required PinPointMode to}) {
    if (_mode != from) return false;
    _mode = to;
    if (!canHover) _hovered.value = null;
    if (!isActive) _measuring.value = false;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _hovered.dispose();
    _selection.dispose();
    _measuring.dispose();
    _openNote.dispose();
    notes.dispose();
    draft.dispose();
    super.dispose();
  }
}

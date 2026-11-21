import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../search/render_search.dart';
import '../state/state_lens.dart';

/// "Watch mode" of the state lens (PLAN-v3 Milestone 21): the user pressed
/// "Watch state" on a widget and went back to using the app.
///
/// Watching is a flag next to the mode, not a mode of its own, like the
/// what-if overrides and the tweaks. The mode goes to idle when watching
/// starts, so the pointer trap is gone and the app gets every pointer and
/// key event. What stays on screen is Pinpoint's own surfaces: the live
/// changes card ([open]) and, while the lens runs, the marker around the
/// target ([markerRect]). The user can start picking again while watching;
/// the lens keeps running and the card stays.
///
/// Only the user's "Watch state" calls [begin]. An agent that arms the lens
/// (`state_flow`) does not: agent work must cause no Pinpoint UI motion.
///
/// The marker follows the target after frames that the app draws anyway (a
/// persistent frame callback that asks for a post-frame callback; it
/// schedules no frame and runs no timer). The rect changes only when the
/// target moved, so a change repaints one layer and nothing else.
class WatchSession extends ChangeNotifier {
  final ValueNotifier<Rect?> _markerRect = ValueNotifier<Rect?>(null);
  final _FrameHook _frameHook = _FrameHook();

  StateLens? _lens;
  Element? _target;
  String _name = '';
  DateTime? _until;
  bool _open = false;
  bool _hooked = false;
  bool _checkArmed = false;
  bool _disposed = false;

  /// Top-left of the card after a drag, in global logical pixels. Null: the
  /// default corner. Kept for the session. Setting it notifies no one: the
  /// card that moved repaints itself.
  Offset? cardPosition;

  /// Whether the card shows.
  bool get open => _open;

  /// The lens the card follows; null before the first watch.
  StateLens? get lens => _lens;

  /// The watched element; null before the first watch. Kept after the
  /// window ends, so "Watch again" can re-arm it.
  Element? get target => _target;

  /// The watched widget's type name.
  String get name => _name;

  /// When the window ends. Fixed at the start: the card shows no countdown.
  DateTime? get until => _until;

  /// The visible rect of the target in global logical pixels, while the lens
  /// runs on it and it shows on screen; null otherwise (the marker hides).
  ValueListenable<Rect?> get markerRect => _markerRect;

  /// Whether the lens runs on [target] (not on a widget the agent moved it
  /// to).
  bool get armed {
    final lens = _lens;
    return _open &&
        lens != null &&
        lens.armed &&
        identical(lens.target, _target);
  }

  /// Whether "Watch again" can work: the card is open and the target is
  /// still in the tree.
  bool get canWatchAgain => _open && (_target?.mounted ?? false);

  /// Opens the card on [target], whose lens [lens] the caller armed just
  /// now for [window].
  void begin({
    required StateLens lens,
    required Element target,
    required String name,
    required Duration window,
  }) {
    if (_disposed) return;
    if (!identical(_lens, lens)) {
      _lens?.removeListener(_onLens);
      _lens = lens..addListener(_onLens);
    }
    _target = target;
    _name = name;
    _until = DateTime.now().add(window);
    _open = true;
    _hook();
    _readMarker();
    notifyListeners();
  }

  /// Arms the lens again on the same target.
  bool watchAgain() {
    final lens = _lens;
    final target = _target;
    if (lens == null || target == null || !canWatchAgain) return false;
    lens.arm(target);
    _until = DateTime.now().add(lens.value.window);
    _readMarker();
    notifyListeners();
    return true;
  }

  /// Ends the window, as the card's Stop does. The card stays.
  void stopLens() {
    if (armed) _lens?.stop();
  }

  /// Hides the card and the marker. A window that is still open ends: with
  /// no card, nobody would see it run.
  void close() {
    if (!_open) return;
    if (armed) _lens?.stop();
    _open = false;
    _setMarker(null);
    notifyListeners();
  }

  /// One step back, as Esc does while watching: the first press stops the
  /// lens, the next closes the card. False when nothing is open.
  bool back() {
    if (!_open) return false;
    if (armed) {
      stopLens();
    } else {
      close();
    }
    return true;
  }

  // The lens published: a window opened, ended or got a join. Its end or a
  // new target hides the marker at once; the position waits for a frame. The
  // card listens to the lens itself.
  void _onLens() {
    if (_disposed || !_open) return;
    if (!armed) _setMarker(null);
  }

  void _setMarker(Rect? rect) {
    if (_markerRect.value != rect) _markerRect.value = rect;
  }

  void _readMarker() {
    if (!armed) {
      _setMarker(null);
      return;
    }
    final target = _target;
    Rect? rect;
    try {
      if (target != null && target.mounted) {
        final object = target.renderObject;
        if (object != null) rect = RenderSearch.visibleRectOf(object);
      }
    } catch (_) {
      // Diagnostics run code written by widget authors.
      rect = null;
    }
    _setMarker(rect);
  }

  void _hook() {
    if (_hooked) return;
    _hooked = true;
    _frameHook.session = this;
    // There is no way to remove a persistent frame callback
    // (docs/api-notes.md, item 7). The hook drops its session on dispose.
    SchedulerBinding.instance.addPersistentFrameCallback(_frameHook.onFrame);
  }

  // Runs in the persistent phase of a frame the app draws, where layout may
  // be unfinished: read after the frame instead.
  void _onFrame() {
    if (_checkArmed || !_open) return;
    _checkArmed = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkArmed = false;
      if (!_disposed && _open) _readMarker();
    }, debugLabel: 'pinpoint.watchMarker');
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _frameHook.session = null;
    try {
      _lens?.removeListener(_onLens);
    } catch (_) {
      // The lens may be disposed already.
    }
    _markerRect.dispose();
    super.dispose();
  }
}

/// The persistent frame callback's only reference to its session.
class _FrameHook {
  WatchSession? session;

  void onFrame(Duration timeStamp) => session?._onFrame();
}

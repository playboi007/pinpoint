import 'package:flutter/scheduler.dart';

/// Pinpoint's own frame number, and a tick after each frame for the
/// sources.
///
/// The framework has no public frame number and no hook at the start of a
/// frame. So the clock counts the frames it sees end, in a persistent frame
/// callback, and an event made during a frame's build gets the number of
/// the frame being drawn.
///
/// It never schedules a frame (engineering rule 2): an app that draws
/// nothing gets no tick.
class FrameClock {
  FrameClock() {
    _hook.clock = this;
    // There is no way to remove a persistent frame callback
    // (docs/api-notes.md, item 7). One static hook is added once per
    // binding; it drops the clock on dispose, so a disposed clock is
    // neither called nor kept alive.
    if (!_hookAdded) {
      _hookAdded = true;
      SchedulerBinding.instance.addPersistentFrameCallback(_hook.onFrame);
    }
  }

  static final _Hook _hook = _Hook();
  static bool _hookAdded = false;

  int _completed = 0;
  bool _endedThisFrame = false;
  bool _disposed = false;

  /// Called after each frame, outside the build phase, in order.
  final List<void Function()> _listeners = <void Function()>[];

  /// The frame an event belongs to now: inside a frame (before its end
  /// was seen), the one being drawn; between frames, the last one drawn.
  int get frame {
    final phase = SchedulerBinding.instance.schedulerPhase;
    final drawing =
        phase == SchedulerPhase.transientCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks ||
        (phase == SchedulerPhase.persistentCallbacks && !_endedThisFrame);
    return _completed + (drawing ? 1 : 0);
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _onFrame() {
    if (_disposed) return;
    _completed++;
    _endedThisFrame = true;
    // Post-frame callbacks run after every persistent callback, outside
    // the build phase, and adding one schedules no frame. Work there that
    // changes no app state keeps the app idle (api-notes item 7).
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _endedThisFrame = false;
      if (_disposed) return;
      for (final listener in List<void Function()>.of(_listeners)) {
        listener();
      }
    }, debugLabel: 'pinpoint trace');
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
    if (identical(_hook.clock, this)) _hook.clock = null;
  }
}

class _Hook {
  FrameClock? clock;

  void onFrame(Duration _) => clock?._onFrame();
}

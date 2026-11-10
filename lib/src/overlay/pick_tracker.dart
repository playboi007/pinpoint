import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/pinpoint_controller.dart';
import '../search/pick_result.dart';
import '../search/render_search.dart';

/// Prints p50 and p95 pick time after every 200 hover picks, in debug.
///
/// For the manual timing check: `flutter run -d chrome
/// --dart-define=PINPOINT_PICK_TIMINGS=true`.
bool debugPrintPickTimings = const bool.fromEnvironment(
  'PINPOINT_PICK_TIMINGS',
);

/// Turns pointer positions into pick results on the controller, and keeps
/// the outlines on their widgets.
///
/// - Hover is coalesced to one pick per frame.
/// - A click picks at once. The same spot again chooses the next candidate.
/// - After each frame the app draws, the hovered and selected rects are read
///   again. A selection whose element is unmounted is cleared.
///
/// It never schedules a frame on its own while nothing changes (engineering
/// rule 2).
class PickTracker {
  PickTracker({required this.controller, required this.appKey}) {
    _frameHook.tracker = this;
    // There is no way to remove a persistent frame callback
    // (docs/api-notes.md, item 7). The hook drops its tracker on dispose, so
    // a disposed tracker is neither called nor kept alive.
    SchedulerBinding.instance.addPersistentFrameCallback(_frameHook.onFrame);
  }

  final PinPointController controller;

  /// Key of the app's `RepaintBoundary`: the root of every pick.
  final GlobalKey appKey;

  /// Number of hover and click picks run, for tests.
  @visibleForTesting
  static int debugPickCount = 0;

  final _FrameHook _frameHook = _FrameHook();
  Offset? _hoverPosition;
  int? _hoverCallbackId;
  bool _refreshArmed = false;
  bool _disposed = false;
  final List<int> _timings = <int>[];

  /// Records the pointer at [position] and picks there in the next frame.
  /// Several moves before that frame cost one pick. Null clears the hover,
  /// for example when the pointer leaves the window.
  void hoverAt(Offset? position) {
    if (_disposed) return;
    _hoverPosition = position;
    if (position == null || !controller.canHover) {
      _cancelHover();
      controller.hover(null);
      return;
    }
    // `scheduleFrameCallback` also schedules the frame. Transient callbacks
    // run before layout, against the geometry of the last frame, and the
    // highlight repaints later in the same frame.
    _hoverCallbackId ??= SchedulerBinding.instance.scheduleFrameCallback((_) {
      _hoverCallbackId = null;
      final at = _hoverPosition;
      if (_disposed || at == null || !controller.canHover) return;
      controller.hover(_pick(at, timed: true));
    });
  }

  /// Picks at [position] now and selects the result. Returns whether a
  /// widget was selected.
  bool selectAt(Offset position) {
    if (_disposed) return false;
    final pick = _pick(position, previous: controller.selection.value);
    return pick != null && controller.select(pick);
  }

  PickResult? _pick(
    Offset position, {
    PickResult? previous,
    bool timed = false,
  }) {
    final context = appKey.currentContext;
    final root = context?.findRenderObject();
    if (context is! Element || root == null) return null;
    debugPickCount++;
    final search = RenderSearch.find(root, position);
    if (timed) _recordTiming(search.elapsed);
    return PickResult.fromSearch(
      search,
      position: position,
      rootElement: context,
      previous: previous,
    );
  }

  void _recordTiming(Duration elapsed) {
    assert(() {
      if (!debugPrintPickTimings) return true;
      _timings.add(elapsed.inMicroseconds);
      if (_timings.length < 200) return true;
      _timings.sort();
      debugPrint(
        'pinpoint: 200 hover picks, '
        'p50 ${_timings[100] / 1000} ms, p95 ${_timings[190] / 1000} ms',
      );
      _timings.clear();
      return true;
    }());
  }

  // Runs in the persistent phase of every frame. Reading geometry here is
  // fine, but a change made here does not schedule a frame, so the outline
  // could stay one frame stale forever. Re-arm a post-frame callback instead.
  void _onFrame() {
    if (_refreshArmed) return;
    if (controller.hovered.value == null &&
        controller.selection.value == null) {
      return;
    }
    _refreshArmed = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _refreshArmed = false;
      if (!_disposed) _refresh();
    }, debugLabel: 'pinpoint.refreshPicks');
  }

  // A change here repaints the highlight, which schedules one more frame.
  // That frame finds nothing changed and stops: refreshed() returns the same
  // instance and the notifiers stay quiet (docs/api-notes.md, item 7).
  void _refresh() {
    final hovered = controller.hovered.value;
    if (hovered != null) {
      final next = hovered.refreshed();
      if (!identical(next, hovered)) controller.hover(next);
    }
    final selected = controller.selection.value;
    if (selected != null) {
      final next = selected.refreshed();
      if (!identical(next, selected)) controller.updateSelection(next);
    }
  }

  void _cancelHover() {
    final id = _hoverCallbackId;
    if (id == null) return;
    SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    _hoverCallbackId = null;
  }

  void dispose() {
    _cancelHover();
    _frameHook.tracker = null;
    _disposed = true;
  }
}

/// The persistent frame callback's only reference to its tracker.
class _FrameHook {
  PickTracker? tracker;

  void onFrame(Duration _) => tracker?._onFrame();
}

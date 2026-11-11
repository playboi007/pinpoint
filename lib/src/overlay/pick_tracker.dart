import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/pinpoint_controller.dart';
import '../search/pick_result.dart';
import '../search/render_search.dart';
import '../search/scroll_passthrough.dart';
import '../search/source_resolver.dart';

/// Prints p50 and p95 pick time (the walk plus the source refinement) after
/// every 200 hover picks, in debug.
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
  PickTracker({
    required this.controller,
    required this.appKey,
    required this.contentKey,
    this.resolver = const SourceResolver(),
  }) {
    _frameHook.tracker = this;
    controller.candidateCycler = cycleCandidate;
    // There is no way to remove a persistent frame callback
    // (docs/api-notes.md, item 7). The hook drops its tracker on dispose, so
    // a disposed tracker is neither called nor kept alive.
    SchedulerBinding.instance.addPersistentFrameCallback(_frameHook.onFrame);
  }

  final PinPointController controller;

  /// Key of the app's `RepaintBoundary`: the root of every pick.
  final GlobalKey appKey;

  /// Key of the element directly above the app's own widgets, where a
  /// picked widget's chain stops.
  final GlobalKey contentKey;

  /// Reads source locations and decides which are local. Replaced when the
  /// project root or the path hints change.
  SourceResolver resolver;

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

  /// Chooses the next candidate under the spot the selection was picked at,
  /// as a second click there would, without the click's rules: a typed comment
  /// stays in the draft and an open note closes. Returns whether the selection
  /// changed.
  bool cycleCandidate() {
    if (_disposed) return false;
    final current = controller.selection.value;
    if (current == null) return false;
    final next = _pick(current.position, previous: current);
    if (next == null || identical(next.element, current.element)) {
      return false;
    }
    controller.closeNote();
    controller.updateSelection(next);
    return true;
  }

  /// Forwards a wheel [event] over the trap to the scrollable under the
  /// cursor, then picks again where the pointer is, since other content is
  /// under it now.
  void scrollAt(PointerScrollEvent event) {
    if (_disposed) return;
    final context = appKey.currentContext;
    final root = context?.findRenderObject();
    if (context is! Element || root == null) return;
    if (!scrollPassthrough(event, root: root, rootElement: context)) return;
    _hoverPosition = event.position;
    _cancelHover();
    // Not a transient callback like hoverAt: that runs before the scrolled
    // list is laid out again and would pick the item that just left. After
    // the frame the geometry is new; the hover change repaints in one more
    // frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final at = _hoverPosition;
      if (_disposed || at == null || !controller.canHover) return;
      controller.hover(_pick(at));
    }, debugLabel: 'pinpoint.pickAfterScroll');
  }

  PickResult? _pick(
    Offset position, {
    PickResult? previous,
    bool timed = false,
  }) {
    final context = appKey.currentContext;
    final root = context?.findRenderObject();
    if (context is! Element || root == null) return null;
    if (!RenderSearch.isOnApp(root, position)) return null;
    debugPickCount++;
    final stopwatch = Stopwatch()..start();
    final search = RenderSearch.find(root, position);
    final boundary = contentKey.currentContext;
    final pick = PickResult.fromSearch(
      search,
      position: position,
      rootElement: context,
      chainBoundary: boundary is Element ? boundary : null,
      resolver: resolver,
      previous: previous,
    );
    // The walk plus the source refinement: both run once per hover frame.
    if (timed) _recordTiming(stopwatch.elapsed);
    return pick;
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
    if (controller.candidateCycler == cycleCandidate) {
      controller.candidateCycler = null;
    }
    _disposed = true;
  }
}

/// The persistent frame callback's only reference to its tracker.
class _FrameHook {
  PickTracker? tracker;

  void onFrame(Duration _) => tracker?._onFrame();
}

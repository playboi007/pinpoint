import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../agent/synthetic_input.dart';
import '../../model/trace_event.dart';
import '../../search/pick_result.dart';
import '../../search/render_search.dart';
import '../../search/source_index.dart';
import '../../search/source_resolver.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';

/// `input.pointer` events (level 1), from
/// `GestureBinding.instance.pointerRouter.addGlobalRoute`: a list, not a
/// slot, so no other tool loses anything.
///
/// Records down, up, cancel and scroll signals. Moves only while a pointer
/// is down, and at most one per frame (one per 16 ms when no frame is
/// drawn): they can come hundreds a second, and without the limit the
/// buffer would hold nothing else (watch out for). Scroll signals in one
/// frame add up into one event.
///
/// A down records the local widget it hit and the position inside it as a
/// fraction (step 5), so Milestone 15 can replay a tap after the layout
/// changed. A pointer that lands on Pinpoint's own UI is not recorded, and
/// the agent's synthetic input is tagged `by: agent` (rule 14).
class PointerSource extends TraceSource {
  PointerSource({
    required this.appKey,
    required this.contentKey,
    required this.resolver,
    this.onUp,
  });

  /// Called after a pointer went up on the app (the route source reads
  /// after the next frame).
  final void Function()? onUp;

  /// The app's `RepaintBoundary`: what is under it is the app.
  final GlobalKey appKey;

  /// The element directly above the app's own widgets.
  final GlobalKey contentKey;

  final SourceResolver resolver;

  /// Global routes this class has added and not removed, for tests.
  @visibleForTesting
  static int debugInstalled = 0;

  TraceRecorder? _recorder;
  late final PointerRoute _route = _onPointer;

  /// Pointers down on the app (true) or on Pinpoint (false), by pointer id.
  final Map<int, bool> _down = <int, bool>{};

  /// The frame and time stamp of the last move recorded, by pointer id.
  final Map<int, (int, Duration)> _moveAt = <int, (int, Duration)>{};

  /// The shortest time between two moves recorded in one frame.
  static const Duration moveInterval = Duration(milliseconds: 16);
  TraceEvent? _lastScroll;

  /// Downs whose widget waits for [_downTimer], with their positions.
  final List<(TraceEvent, Offset)> _pendingDowns = <(TraceEvent, Offset)>[];
  Timer? _downTimer;

  @override
  String get name => 'pointer';

  @override
  int get level => 1;

  @override
  bool get isInput => true;

  @override
  void start(TraceRecorder recorder) {
    if (_recorder != null) return;
    _recorder = recorder;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
    debugInstalled++;
  }

  @override
  void stop() {
    if (_recorder == null) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
    debugInstalled--;
    _recorder = null;
    _down.clear();
    _moveAt.clear();
    _lastScroll = null;
    _downTimer?.cancel();
    _downTimer = null;
    _pendingDowns.clear();
  }

  // Runs inside the pointer dispatch: never throw, never await.
  void _onPointer(PointerEvent event) {
    final recorder = _recorder;
    if (recorder == null) return;
    final watch = Stopwatch()..start();
    try {
      _record(recorder, event);
    } catch (error) {
      debugPrint('pinpoint: pointer source failed: $error');
    } finally {
      recorder.charge(watch.elapsedMicroseconds);
    }
  }

  void _record(TraceRecorder recorder, PointerEvent event) {
    final pointer = event.pointer;
    switch (event) {
      case PointerDownEvent():
        final onApp = _isOnApp(event.position, event.viewId);
        _down[pointer] = onApp;
        if (onApp) _recordDown(recorder, event);
      case PointerMoveEvent():
        if (_down[pointer] != true) return;
        // At most one per frame, and when no frame is drawn (a drag over
        // a part of the app that does not react), at most one per 16 ms
        // of the events' own time stamps.
        final frame = recorder.frameOf();
        final last = _moveAt[pointer];
        if (last != null &&
            last.$1 == frame &&
            event.timeStamp - last.$2 < moveInterval) {
          return;
        }
        _moveAt[pointer] = (frame, event.timeStamp);
        recorder.add(TraceKind.pointer, data: _base(event, 'move'));
      case PointerUpEvent() || PointerCancelEvent():
        _moveAt.remove(pointer);
        if (_down.remove(pointer) != true) return;
        recorder.add(
          TraceKind.pointer,
          data: _base(event, event is PointerUpEvent ? 'up' : 'cancel'),
        );
        onUp?.call();
      case PointerScrollEvent():
        if (!_isOnApp(event.position, event.viewId)) return;
        final last = _lastScroll;
        final frame = recorder.frameOf();
        if (last != null &&
            last.frame == frame &&
            identical(recorder.newest, last)) {
          // The same frame: add up into the event already recorded.
          final data = last.data;
          data['dx'] = _round((data['dx']! as num) + event.scrollDelta.dx);
          data['dy'] = _round((data['dy']! as num) + event.scrollDelta.dy);
          return;
        }
        _lastScroll = recorder.add(
          TraceKind.pointer,
          data: _base(event, 'scroll')
            ..['dx'] = _round(event.scrollDelta.dx)
            ..['dy'] = _round(event.scrollDelta.dy),
        );
      default:
        // Hover, added, removed, pan-zoom: not recorded.
        return;
    }
  }

  Map<String, Object?> _base(PointerEvent event, String phase) => {
    'phase': phase,
    'pointer': event.pointer,
    'x': _round(event.position.dx),
    'y': _round(event.position.dy),
    'device': event.kind.name,
    if (event.device >= SyntheticInput.deviceBase) 'by': 'agent',
  };

  void _recordDown(TraceRecorder recorder, PointerDownEvent event) {
    final recorded = recorder.add(
      TraceKind.pointer,
      data: _base(event, 'down'),
    );
    // The widget under the pointer needs a pick search (about 5 ms on web)
    // and its anchor a walk of the tree. Neither runs inside the pointer
    // dispatch, where it would delay the app's own handling (rule 11): a
    // one-shot timer runs them after the event, before the layout changes
    // in the next frame, and forces no frame (engineering rule 2).
    _pendingDowns.add((recorded, event.position));
    _downTimer ??= Timer(Duration.zero, _fillDowns);
  }

  void _fillDowns() {
    _downTimer = null;
    final pending = List.of(_pendingDowns);
    _pendingDowns.clear();
    final watch = Stopwatch()..start();
    for (final (event, position) in pending) {
      try {
        _fillDown(event, position);
      } catch (error) {
        debugPrint('pinpoint: pointer source failed: $error');
      }
    }
    _recorder?.charge(watch.elapsedMicroseconds);
  }

  /// Fills in the widget a down hit, its source, its anchor and the
  /// position inside it as a fraction.
  void _fillDown(TraceEvent event, Offset position) {
    final appContext = appKey.currentContext;
    final root = appContext?.findRenderObject();
    final content = contentKey.currentContext;
    if (appContext is! Element || root == null || content is! Element) {
      return;
    }
    final pick = PickResult.fromSearch(
      RenderSearch.find(root, position),
      position: position,
      rootElement: appContext,
      chainBoundary: content,
      resolver: resolver,
    );
    if (pick == null || pick.sourceUnavailable) return;
    final entry = pick.chain[pick.chainIndex];
    final rect = pick.globalRect;
    event.widget = entry.name;
    final location = entry.location;
    if (location != null) {
      event.source =
          '${resolver.paths.relativePath(location.uri)}:'
          '${location.line}:${location.column}';
    }
    final data = event.data;
    if (rect.width > 0 && rect.height > 0) {
      data['fx'] = _fraction((position.dx - rect.left) / rect.width);
      data['fy'] = _fraction((position.dy - rect.top) / rect.height);
    }
    final anchor = SourceIndex(
      resolver: resolver,
    ).anchorFor(entry.element, root: content);
    if (anchor != null) data['anchor'] = anchor.toJson();
  }

  /// Whether the top of the hit path at [position] is the app, not
  /// Pinpoint's overlay (its panel, pins, rail or picking trap).
  bool _isOnApp(Offset position, int viewId) {
    final root = appKey.currentContext?.findRenderObject();
    if (root == null) return false;
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(result, position, viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderObject) continue;
      RenderObject? node = target;
      while (node != null) {
        if (identical(node, root)) return true;
        node = node.parent;
      }
      return false;
    }
    return false;
  }

  static num _round(double value) {
    final r = (value * 10).roundToDouble() / 10;
    return r == r.roundToDouble() ? r.round() : r;
  }

  static double _fraction(double value) =>
      (value.clamp(0.0, 1.0) * 100).roundToDouble() / 100;
}

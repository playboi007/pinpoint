import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../capture/context_collector.dart';
import '../../model/trace_event.dart';
import '../../search/element_lookup.dart';
import '../../search/render_search.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';

/// `route` events (level 1): the route on top, read the way the collector
/// and `get_screen` read it (the route of what is at the center of the
/// app), recorded when it changes.
///
/// That read is a hit search, so it does not run on every frame. It runs
/// after the first frame, after a frame that follows a pointer up ([tapped];
/// most route changes follow a tap), and at most every [interval] while
/// frames go on. A route coming in is still moving when its first frame
/// ends, so a one-shot timer reads once more [interval] after the last
/// read. A timer forces no frame, and an app that is idle gets no further
/// read.
class RouteSource extends TraceSource with FrameWork {
  RouteSource({required this.appKey});

  static const Duration interval = Duration(milliseconds: 500);

  /// The app's `RepaintBoundary`.
  final GlobalKey appKey;

  TraceRecorder? _recorder;
  final Stopwatch _sinceRead = Stopwatch();
  bool _tapped = false;
  bool _read = false;
  Timer? _trailing;
  String? _route;

  @override
  String get name => 'route';

  @override
  int get level => 1;

  @override
  bool get isInput => false;

  @override
  void start(TraceRecorder recorder) => _recorder = recorder;

  @override
  void stop() {
    _recorder = null;
    _read = false;
    _trailing?.cancel();
    _trailing = null;
  }

  /// A pointer went up on the app: read after the next frame.
  void tapped() => _tapped = true;

  @override
  void afterFrame() {
    if (_recorder == null) return;
    if (_read && !_tapped && _sinceRead.elapsed < interval) {
      _trailing ??= Timer(interval, _readNow);
      return;
    }
    _readNow();
    // The route that came in may still be moving: read once more later.
    _trailing ??= Timer(interval, _readNow);
  }

  void _readNow() {
    _trailing?.cancel();
    _trailing = null;
    final recorder = _recorder;
    if (recorder == null) return;
    _tapped = false;
    _sinceRead
      ..reset()
      ..start();
    try {
      final route = currentRoute(appKey);
      if (_read && route == _route) return;
      final from = _route;
      _route = route;
      _read = true;
      if (route == null && from == null) return;
      recorder.add(TraceKind.route, data: {'from': from, 'to': route});
    } catch (error) {
      debugPrint('pinpoint: route source failed: $error');
    }
  }

  /// The route of what is at the center of the app, or null.
  static String? currentRoute(GlobalKey appKey) {
    final context = appKey.currentContext;
    final root = context?.findRenderObject();
    if (context is! Element || root == null) return null;
    final rect = RenderSearch.globalRectOf(root);
    if (rect == null) return null;
    for (final hit in RenderSearch.find(root, rect.center).candidates) {
      final owner = elementFor(hit.renderObject, root: context);
      if (owner is RenderObjectElement) {
        return ContextCollector.routeNameOf(owner);
      }
    }
    return null;
  }
}

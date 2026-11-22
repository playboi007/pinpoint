import 'package:flutter/widgets.dart';

import '../../core/rebuild_hook.dart';
import '../../model/trace_event.dart';
import '../../search/source_resolver.dart';
import '../trace_recorder.dart';
import '../trace_source.dart';

/// One `build` event per local widget per frame, with a count (level 3).
///
/// Level 3 because it holds `debugOnRebuildDirtyWidget`: held from app
/// start, it would break DevTools "track rebuilds" for every user of
/// Pinpoint (api-notes item 8): DevTools cannot turn on while Pinpoint
/// holds the slot. It shares the one callback with `RebuildTracker`
/// through [RebuildHook], and shares
/// it with DevTools when DevTools was there first.
class RebuildSource extends TraceSource with FrameWork {
  RebuildSource({
    required this.hook,
    required this.content,
    required this.resolver,
    this.onLost,
    this.onGap,
  });

  final RebuildHook hook;

  /// The element directly above the app's own widgets. Elements outside it
  /// are Pinpoint's own UI and are never recorded.
  final Element? Function() content;

  /// Reads locations and decides which widgets are local.
  final SourceResolver resolver;

  /// Called when another tool took the slot while this source ran.
  final void Function()? onLost;

  /// Called with the first and last seq of a span in which rebuilds were
  /// not counted: DevTools turned its tracking off, which cleared the
  /// slot, and the hook went back in after the next frame.
  final void Function(int from, int to)? onGap;

  /// The recorder's next seq after the last frame event.
  int _seqAfterFrame = 0;

  /// The first seq of a span to mark as not counted in [endFrame].
  int? _gapFrom;

  /// Whether rebuilds are also handed to another tool, for example DevTools
  /// "track rebuilds".
  bool get shared => _running && hook.shared;

  /// Elements that rebuilt in the frame just flushed, for the watches.
  final List<void Function(Set<Element> rebuilt)> rebuiltListeners =
      <void Function(Set<Element> rebuilt)>[];

  late final RebuildDirtyWidgetCallback _listener = _onRebuild;
  final Map<Element, int> _counts = Map<Element, int>.identity();

  /// Whether an element is under [content], cached per element: the walk
  /// up runs once for each element, not once per rebuild.
  static final Expando<bool> _inApp = Expando<bool>('pinpoint in app');

  TraceRecorder? _recorder;
  bool _running = false;
  int? _lastTotal;

  /// Why the last start failed, for example `rebuild slot taken`.
  String? failure;

  @override
  String get name => 'rebuild';

  @override
  int get level => 3;

  @override
  bool get isInput => false;

  /// Whether the hook is installed and counting.
  bool get running => _running;

  /// App rebuilds in the frame just flushed; null while not running.
  int? get lastTotal => _running ? _lastTotal : null;

  @override
  void start(TraceRecorder recorder) {
    _recorder = recorder;
    if (_running) return;
    if (!hook.add(_listener)) {
      failure = 'rebuild slot taken';
      return;
    }
    failure = null;
    _running = true;
    _lastTotal = 0;
    _seqAfterFrame = recorder.nextSeq;
  }

  @override
  void stop() {
    if (_running) hook.remove(_listener);
    _running = false;
    _counts.clear();
    _lastTotal = null;
    _gapFrom = null;
  }

  // Called for every rebuild: count into a map keyed by
  // element, nothing else. Locations are resolved when the event is
  // written, once per frame.
  // The shape of Flutter's rebuild callback.
  // ignore: avoid_positional_boolean_parameters
  void _onRebuild(Element element, bool builtOnce) {
    _counts[element] = (_counts[element] ?? 0) + 1;
  }

  @override
  void afterFrame() {
    final recorder = _recorder;
    if (!_running || recorder == null) return;
    if (hook.takenOver) {
      if (hook.reclaim()) {
        // DevTools turned its tracking off and cleared the slot: the hook is
        // back, but rebuilds since the last frame were not all counted. The
        // clear can only come between frames (a service extension call).
        // The gap is marked in [endFrame], after this frame's event.
        _gapFrom = _seqAfterFrame;
      } else {
        // Another tool wrote over the hook: stop, and leave the slot to it.
        stop();
        failure = 'rebuild slot taken';
        onLost?.call();
        return;
      }
    }
    final root = content();
    var total = 0;
    final rebuilt = Set<Element>.identity();
    for (final MapEntry(key: element, value: n) in _counts.entries) {
      if (root == null || !_isInApp(element, root)) continue;
      total += n;
      rebuilt.add(element);
      final entry = resolver.entryOf(element);
      final location = entry.location;
      // Framework widgets are counted, not listed.
      if (!entry.isLocal || location == null) continue;
      recorder.add(
        TraceKind.build,
        widget: entry.name,
        source:
            '${resolver.paths.relativePath(location.uri)}:'
            '${location.line}:${location.column}',
        data: {'n': n},
      );
    }
    _counts.clear();
    // A frame with a gap has no known total.
    _lastTotal = _gapFrom == null ? total : null;
    if (rebuilt.isNotEmpty) {
      for (final listener in rebuiltListeners.toList()) {
        listener(rebuilt);
      }
    }
  }

  /// Called after the frame event is written: marks a gap found in
  /// [afterFrame], which covers this frame's event too.
  void endFrame() {
    final recorder = _recorder;
    if (recorder == null) return;
    final from = _gapFrom;
    _gapFrom = null;
    if (from != null) onGap?.call(from, recorder.nextSeq - 1);
    _seqAfterFrame = recorder.nextSeq;
  }

  static bool _isInApp(Element element, Element root) {
    final cached = _inApp[element];
    if (cached != null) return cached;
    var found = false;
    try {
      element.visitAncestorElements((ancestor) {
        found = identical(ancestor, root);
        return !found;
      });
    } catch (_) {
      // Unmounted since it rebuilt.
      return false;
    }
    _inApp[element] = found;
    return found;
  }
}

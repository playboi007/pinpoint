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
/// Pinpoint (api-notes item 8). It shares the one callback with
/// `RebuildTracker` through [RebuildHook] (watch out for: one hook, two
/// users).
class RebuildSource extends TraceSource with FrameWork {
  RebuildSource({
    required this.hook,
    required this.content,
    required this.resolver,
    this.onLost,
  });

  final RebuildHook hook;

  /// The element directly above the app's own widgets. Elements outside it
  /// are Pinpoint's own UI and are never recorded (rule 14).
  final Element? Function() content;

  /// Reads locations and decides which widgets are local.
  final SourceResolver resolver;

  /// Called when another tool took the slot while this source ran.
  final void Function()? onLost;

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
  }

  @override
  void stop() {
    if (_running) hook.remove(_listener);
    _running = false;
    _counts.clear();
    _lastTotal = null;
  }

  // Called for every rebuild (watch out for): count into a map keyed by
  // element, nothing else. Locations are resolved when the event is
  // written, once per frame.
  void _onRebuild(Element element, bool builtOnce) {
    _counts[element] = (_counts[element] ?? 0) + 1;
  }

  @override
  void afterFrame() {
    final recorder = _recorder;
    if (!_running || recorder == null) return;
    // DevTools wrote the slot, or turned its tracking off and cleared ours:
    // stop, and leave the slot to it.
    if (hook.takenOver) {
      stop();
      failure = 'rebuild slot taken';
      onLost?.call();
      return;
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
    _lastTotal = total;
    if (rebuilt.isNotEmpty) {
      for (final listener in rebuiltListeners) {
        listener(rebuilt);
      }
    }
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

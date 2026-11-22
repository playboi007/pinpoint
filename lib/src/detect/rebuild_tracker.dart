import 'package:flutter/widgets.dart';

import '../core/hook_registry.dart';
import '../core/rebuild_hook.dart';
import '../search/render_search.dart';
import 'detector.dart';

/// Counts rebuilds per element in a rolling five-second window, through
/// `debugOnRebuildDirtyWidget`. Off by default.
///
/// The hook is called for every rebuild, so it only counts: source
/// locations are resolved in [findings], when the list asks for them.
///
/// It shares the one Pinpoint callback in the slot with the trace's
/// rebuild source through [RebuildHook].
class RebuildTracker {
  RebuildTracker({
    HookRegistry? registry,
    RebuildHook? hook,
    Duration Function()? clock,
  }) : assert(registry != null || hook != null),
       _clock = clock ?? _monotonic,
       _hook = hook ?? RebuildHook(registry!);

  /// How far back counts reach.
  static const int windowSeconds = 5;

  /// Elements kept before the oldest are dropped.
  static const int maxElements = 20000;

  static final Stopwatch _watch = Stopwatch()..start();
  static Duration _monotonic() => _watch.elapsed;

  final Duration Function() _clock;
  final RebuildHook _hook;
  late final RebuildDirtyWidgetCallback _listener = _onRebuild;
  final Map<Element, _Heat> _heat = Map<Element, _Heat>.identity();
  bool _installed = false;

  bool get installed => _installed;

  /// Whether someone else wrote the slot after us. DevTools does: turning
  /// its rebuild tracking off sets the slot to null.
  bool get takenOver => _installed && _hook.takenOver;

  /// After [takenOver]: takes an emptied slot back. See
  /// [RebuildHook.reclaim].
  bool reclaim() => _installed && _hook.reclaim();

  /// Starts counting. A callback DevTools put in the slot first is shared,
  /// not replaced (see [RebuildHook]). Returns false, and writes nothing,
  /// only when another tool wrote over Pinpoint's hook.
  bool install() {
    if (_installed && !takenOver) return true;
    if (!_hook.add(_listener)) return false;
    _installed = true;
    return true;
  }

  /// Stops counting and forgets the counts. A slot someone else wrote is
  /// left to them.
  void uninstall() {
    _installed = false;
    _hook.remove(_listener);
    _heat.clear();
  }

  // Runs during build: count, nothing else.
  // The shape of Flutter's rebuild callback.
  // ignore: avoid_positional_boolean_parameters
  void _onRebuild(Element element, bool builtOnce) {
    if (!_installed) return;
    final second = _clock().inSeconds;
    (_heat[element] ??= _Heat()).add(second);
    if (_heat.length > maxElements) _prune(second);
  }

  void _prune(int now) {
    _heat.removeWhere((element, heat) => heat.total(now) == 0);
  }

  /// The [count] elements that rebuilt most in the window, at least
  /// [minCount] times each, as findings. Pinpoint's own elements (outside
  /// [locator]'s boundary) and unmounted ones are left out.
  List<Finding> findings({
    required FindingLocator locator,
    int count = 10,
    int minCount = 10,
  }) {
    final now = _clock().inSeconds;
    _heat.removeWhere((element, heat) => !element.mounted);
    _prune(now);
    final ranked = [
      for (final MapEntry(key: element, value: heat) in _heat.entries)
        if (heat.total(now) case final total when total >= minCount)
          (element, total),
    ];
    // Most first; on a tie the shallower element, which is usually the one
    // that called setState.
    ranked.sort((a, b) {
      final byCount = b.$2.compareTo(a.$2);
      return byCount != 0 ? byCount : a.$1.depth.compareTo(b.$1.depth);
    });
    final found = <Finding>[];
    for (final (element, total) in ranked) {
      if (found.length >= count) break;
      if (!locator.isInApp(element)) continue;
      final renderObject = element.renderObject;
      final name = element.widget.runtimeType.toString();
      found.add(
        Finding(
          kind: 'rebuild_heat',
          severity: Severity.info,
          summary: '$name rebuilt $total times in $windowSeconds s',
          element: element,
          rect: renderObject == null
              ? null
              : RenderSearch.globalRectOf(renderObject),
          source: locator.sourceOf(element),
          data: {
            'widget': name,
            'count': total,
            'windowSeconds': windowSeconds,
          },
        ),
      );
    }
    return found;
  }
}

/// Rebuilds in each of the last [RebuildTracker.windowSeconds] seconds.
class _Heat {
  final List<int> _seconds = List<int>.filled(RebuildTracker.windowSeconds, -1);
  final List<int> _counts = List<int>.filled(RebuildTracker.windowSeconds, 0);

  void add(int second) {
    final slot = second % RebuildTracker.windowSeconds;
    if (_seconds[slot] != second) {
      _seconds[slot] = second;
      _counts[slot] = 0;
    }
    _counts[slot]++;
  }

  int total(int now) {
    var sum = 0;
    for (var i = 0; i < _counts.length; i++) {
      if (now - _seconds[i] < RebuildTracker.windowSeconds) sum += _counts[i];
    }
    return sum;
  }
}

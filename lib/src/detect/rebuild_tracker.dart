import 'package:flutter/widgets.dart';

import '../core/hook_registry.dart';
import '../search/render_search.dart';
import 'detector.dart';

/// Counts rebuilds per element in a rolling five-second window, through
/// `debugOnRebuildDirtyWidget`. Off by default.
///
/// The hook is called for every rebuild, so it only counts: source
/// locations are resolved in [findings], when the list asks for them.
class RebuildTracker {
  RebuildTracker({required HookRegistry registry, Duration Function()? clock})
    : _clock = clock ?? _monotonic,
      _slot = registry.slot<RebuildDirtyWidgetCallback?>(
        key: #pinpointRebuildDirty,
        read: () => debugOnRebuildDirtyWidget,
        write: (value) => debugOnRebuildDirtyWidget = value,
      );

  /// How far back counts reach.
  static const int windowSeconds = 5;

  /// Elements kept before the oldest are dropped.
  static const int maxElements = 20000;

  static final Stopwatch _watch = Stopwatch()..start();
  static Duration _monotonic() => _watch.elapsed;

  final Duration Function() _clock;
  final GlobalSlot<RebuildDirtyWidgetCallback?> _slot;
  late final RebuildDirtyWidgetCallback _hook = _onRebuild;
  final Map<Element, _Heat> _heat = Map<Element, _Heat>.identity();
  bool _installed = false;

  bool get installed => _installed;

  /// Whether someone else wrote the slot after us. DevTools does: turning
  /// its rebuild tracking off sets the slot to null.
  bool get takenOver =>
      _installed && !identical(debugOnRebuildDirtyWidget, _hook);

  /// Starts counting. Returns false, and writes nothing, when the slot is
  /// already taken: DevTools' "track rebuilds" asserts that the slot is
  /// null when it turns on (docs/api-notes.md, item 8), so Pinpoint only
  /// writes an empty slot.
  bool install() {
    if (_installed && !takenOver) return true;
    final current = debugOnRebuildDirtyWidget;
    if (current != null && !identical(current, _hook)) return false;
    _installed = true;
    _slot.set(_hook);
    return true;
  }

  /// Stops counting and forgets the counts. A slot someone else wrote is
  /// left to them.
  void uninstall() {
    _installed = false;
    _slot.release();
    _heat.clear();
  }

  // Runs during build: count, nothing else.
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

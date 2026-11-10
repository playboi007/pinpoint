import 'package:flutter/rendering.dart';

import '../core/hook_registry.dart';

/// Flutter's debug paint flags that the findings list can turn on: visual
/// aids, not detectors.
enum DebugPaintFlag {
  size('Sizes'),
  baselines('Baselines'),
  layers('Layer borders'),
  pointers('Pointers'),
  rainbow('Repaint rainbow');

  const DebugPaintFlag(this.label);

  final String label;

  /// Whether the flag is on now.
  bool get isOn => _read();

  bool _read() => switch (this) {
    size => debugPaintSizeEnabled,
    baselines => debugPaintBaselinesEnabled,
    layers => debugPaintLayerBordersEnabled,
    pointers => debugPaintPointersEnabled,
    rainbow => debugRepaintRainbowEnabled,
  };

  void _write(bool value) {
    switch (this) {
      case size:
        debugPaintSizeEnabled = value;
      case baselines:
        debugPaintBaselinesEnabled = value;
      case layers:
        debugPaintLayerBordersEnabled = value;
      case pointers:
        debugPaintPointersEnabled = value;
      case rainbow:
        debugRepaintRainbowEnabled = value;
    }
  }
}

/// Sets the debug paint flags through [HookRegistry] and repaints, so a
/// change shows at once and the flags go back on dispose.
class DebugPaintToggles {
  DebugPaintToggles(HookRegistry registry)
    : _slots = {
        for (final flag in DebugPaintFlag.values)
          flag: registry.slot<bool>(
            key: flag,
            read: flag._read,
            write: flag._write,
          ),
      } {
    // The flags' slots restore themselves; the color needs this.
    registry.onDispose(_restoreRainbowColor);
  }

  final Map<DebugPaintFlag, GlobalSlot<bool>> _slots;

  /// The repaint rainbow cycles this color on every repaint, and
  /// `flutter test` checks it is back to its start.
  HSVColor? _rainbowStart;

  /// Turns exactly the flags in [on] on, and the rest back to what they
  /// were. Repaints when anything changed.
  void apply(Set<DebugPaintFlag> on) {
    var changed = false;
    for (final MapEntry(key: flag, value: slot) in _slots.entries) {
      final want = on.contains(flag);
      if (want && !slot.isHeld) {
        if (flag == DebugPaintFlag.rainbow) {
          _rainbowStart = debugCurrentRepaintColor;
        }
        slot.set(true);
        changed = true;
      } else if (!want && slot.isHeld) {
        slot.release();
        if (flag == DebugPaintFlag.rainbow) _restoreRainbowColor();
        changed = true;
      }
    }
    if (changed) repaintAll();
  }

  void _restoreRainbowColor() {
    final start = _rainbowStart;
    if (start == null) return;
    debugCurrentRepaintColor = start;
    _rainbowStart = null;
  }

  /// Marks every render object as needing paint, as Flutter's own debug
  /// service extensions do: the flags are read in paint, and nothing else
  /// would repaint a still screen. Bounded and guarded (engineering rule 4).
  static void repaintAll({int maxNodes = 200000}) {
    var visited = 0;
    void visit(RenderObject node) {
      if (visited++ >= maxNodes) return;
      try {
        node
          ..markNeedsPaint()
          ..visitChildren(visit);
      } catch (_) {
        // A custom render object that throws: the rest still repaints.
      }
    }

    for (final view in RendererBinding.instance.renderViews) {
      view.visitChildren(visit);
    }
  }
}

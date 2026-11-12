import 'package:flutter/widgets.dart';

import 'hook_registry.dart';

/// The one `debugOnRebuildDirtyWidget` callback Pinpoint installs, shared
/// by every user inside Pinpoint: the rebuild heat detector
/// (`RebuildTracker`) and the trace's rebuild source.
///
/// One hook, two users (PLAN-v2 Milestone 13, watch out for): DevTools'
/// "track rebuilds" asserts that the slot is null before it writes it
/// (docs/api-notes.md, item 8), so a second install would fail, and so
/// would DevTools. The slot is written only while at least one listener is
/// added, and only when it is empty.
class RebuildHook {
  RebuildHook(HookRegistry registry)
    : _slot = registry.slot<RebuildDirtyWidgetCallback?>(
        key: #pinpointRebuildDirty,
        read: () => debugOnRebuildDirtyWidget,
        write: (value) => debugOnRebuildDirtyWidget = value,
      );

  final GlobalSlot<RebuildDirtyWidgetCallback?> _slot;
  late final RebuildDirtyWidgetCallback _hook = _onRebuild;
  final List<RebuildDirtyWidgetCallback> _listeners =
      <RebuildDirtyWidgetCallback>[];

  /// Whether Pinpoint wrote the slot and has not let it go.
  bool get installed => _slot.isHeld;

  /// Whether the slot holds someone else's callback now: DevTools wrote it,
  /// or turned its tracking off and cleared ours (item 8).
  bool get takenOver =>
      _slot.isHeld && !identical(debugOnRebuildDirtyWidget, _hook);

  /// Whether the slot is held by another tool, so [add] would fail.
  static bool get heldByOther => debugOnRebuildDirtyWidget != null;

  /// Adds [listener]. The first listener installs the hook. Returns false,
  /// and adds nothing, when the slot holds another tool's callback.
  bool add(RebuildDirtyWidgetCallback listener) {
    if (_listeners.contains(listener) && !takenOver) return true;
    final current = debugOnRebuildDirtyWidget;
    if (current != null && !identical(current, _hook)) return false;
    if (!_listeners.contains(listener)) _listeners.add(listener);
    if (!identical(current, _hook)) _slot.set(_hook);
    return true;
  }

  /// Removes [listener]. The last one gives the slot back, unless another
  /// tool wrote it since: then it is theirs and is left alone.
  void remove(RebuildDirtyWidgetCallback listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) _slot.release();
  }

  // Runs during build, for every rebuild: hand on, nothing else.
  void _onRebuild(Element element, bool builtOnce) {
    for (var i = 0; i < _listeners.length; i++) {
      _listeners[i](element, builtOnce);
    }
  }
}

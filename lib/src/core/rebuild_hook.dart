import 'package:flutter/widgets.dart';

import 'hook_registry.dart';

/// The one `debugOnRebuildDirtyWidget` callback Pinpoint installs, shared
/// by every user inside Pinpoint: the rebuild heat detector
/// (`RebuildTracker`) and the trace's rebuild source.
///
/// One hook, two users. It also
/// shares the slot with DevTools "track rebuilds" where Flutter lets it
/// (docs/api-notes.md, item 8):
///
/// - DevTools first: Pinpoint writes its hook over DevTools' callback and
///   calls that callback first on every rebuild, so DevTools' counts go on.
///   When Pinpoint lets go, DevTools' callback goes back in the slot.
/// - DevTools turns tracking off while Pinpoint holds the slot: DevTools
///   writes null. [reclaim] puts the hook back, without DevTools' callback.
/// - Pinpoint first, then DevTools turns on: DevTools asserts that the slot
///   is null, so this order still fails. No public API lets Pinpoint get in
///   front of that assert.
class RebuildHook {
  RebuildHook(HookRegistry registry)
    : _slot = registry.slot<RebuildDirtyWidgetCallback?>(
        key: #pinpointRebuildDirty,
        read: () => debugOnRebuildDirtyWidget,
        write: (value) => debugOnRebuildDirtyWidget = value,
      );

  final GlobalSlot<RebuildDirtyWidgetCallback?> _slot;
  late final RebuildDirtyWidgetCallback _hook = _onRebuild;

  /// The other tool's callback that was in the slot when the hook went in
  /// (DevTools' "track rebuilds"), called first on every rebuild.
  RebuildDirtyWidgetCallback? _shared;
  final List<RebuildDirtyWidgetCallback> _listeners =
      <RebuildDirtyWidgetCallback>[];

  /// Whether Pinpoint wrote the slot and has not let it go.
  bool get installed => _slot.isHeld;

  /// Whether the slot holds someone else's callback now: DevTools wrote it,
  /// or turned its tracking off and cleared ours (item 8).
  bool get takenOver =>
      _slot.isHeld && !identical(debugOnRebuildDirtyWidget, _hook);

  /// Whether the hook hands every rebuild on to another tool's callback,
  /// for example DevTools "track rebuilds".
  bool get shared => installed && !takenOver && _shared != null;

  /// Whether the slot holds another tool's callback. [add] then shares it.
  static bool get heldByOther => debugOnRebuildDirtyWidget != null;

  /// Adds [listener]. The first listener installs the hook; a callback
  /// another tool put in the slot is kept and called first (see [shared]).
  /// Returns false, and adds nothing, only when another tool wrote over
  /// Pinpoint's hook after Pinpoint wrote it: sharing that one could call
  /// back into Pinpoint without end.
  bool add(RebuildDirtyWidgetCallback listener) {
    if (takenOver && !reclaim()) return false;
    if (!_listeners.contains(listener)) _listeners.add(listener);
    if (!identical(debugOnRebuildDirtyWidget, _hook)) _install();
    return true;
  }

  /// After [takenOver]: puts the hook back when the slot is empty, which is
  /// what DevTools leaves when it turns tracking off. Returns whether the
  /// hook is in the slot now. A callback another tool wrote over the hook
  /// is left alone.
  bool reclaim() {
    if (!takenOver) return installed;
    if (debugOnRebuildDirtyWidget != null || _listeners.isEmpty) return false;
    _install();
    return true;
  }

  void _install() {
    _slot.set(_hook);
    // The value the slot had before the first write, or the one another
    // tool wrote since (GlobalSlot.set): DevTools' callback, or null.
    final before = _slot.previous;
    _shared = identical(before, _hook) ? null : before;
  }

  /// Removes [listener]. The last one gives the slot back (DevTools'
  /// callback, when it was shared), unless another tool wrote the slot
  /// since: then it is theirs and is left alone.
  void remove(RebuildDirtyWidgetCallback listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) {
      _slot.release();
      _shared = null;
    }
  }

  // Runs during build, for every rebuild: hand on, nothing else.
  // The shape of Flutter's rebuild callback.
  // ignore: avoid_positional_boolean_parameters
  void _onRebuild(Element element, bool builtOnce) {
    _shared?.call(element, builtOnce);
    for (var i = 0; i < _listeners.length; i++) {
      _listeners[i](element, builtOnce);
    }
  }
}

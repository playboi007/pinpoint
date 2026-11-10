import 'package:flutter/services.dart';

/// Installs global hooks and puts them back on [dispose] (engineering rule 1).
///
/// Every single global slot Pinpoint touches goes through here:
/// `HardwareKeyboard` handlers, `timeDilation`,
/// `debugDefaultTargetPlatformOverride`, `FlutterError.onError`,
/// `PlatformDispatcher.onError`, the debug callbacks and the debug paint
/// flags.
///
/// `SchedulerBinding.addPersistentFrameCallback` has no remove method, so it
/// cannot be registered here. Guard such callbacks with a disposed flag.
class HookRegistry {
  final List<VoidCallback> _restores = <VoidCallback>[];

  /// Adds [handler] to `HardwareKeyboard.instance` until [dispose].
  ///
  /// Every handler sees every key, whatever earlier handlers return; the
  /// return value only reports "handled" to the embedder (docs/api-notes.md,
  /// item 6). To keep keys from the app, take focus away from it.
  void addKeyHandler(KeyEventCallback handler) {
    HardwareKeyboard.instance.addHandler(handler);
    _restores.add(() => HardwareKeyboard.instance.removeHandler(handler));
  }

  /// Writes [value] into a global slot and restores the previous value on
  /// [dispose].
  ///
  /// When someone else wrote the slot after us (DevTools does this with
  /// `debugOnRebuildDirtyWidget`), the slot is theirs: it is left alone.
  void replace<T>({
    required T Function() read,
    required void Function(T value) write,
    required T value,
  }) {
    final previous = read();
    write(value);
    _restores.add(() {
      if (identical(read(), value)) write(previous);
    });
  }

  /// A global slot written again and again, such as `timeDilation` from
  /// the what-if panel. The value from before the first write comes back on
  /// [GlobalSlot.release] or on [dispose].
  ///
  /// [key] names the global. Two registries can hold the same one: Flutter
  /// can mount a new wrapper State before it disposes the old one. The
  /// newest holder owns the slot and keeps the original value, so the old
  /// State's dispose does not undo the new State's write.
  GlobalSlot<T> slot<T>({
    required Object key,
    required T Function() read,
    required void Function(T value) write,
  }) {
    final slot = GlobalSlot<T>._(key, read, write);
    _restores.add(slot.release);
    return slot;
  }

  /// Runs [restore] on [dispose], with the slots, newest first: for a
  /// global that a hook changes as a side effect, such as the repaint
  /// rainbow's color.
  void onDispose(VoidCallback restore) => _restores.add(restore);

  /// Restores every slot, newest first. Safe to call more than once.
  void dispose() {
    for (final restore in _restores.reversed) {
      restore();
    }
    _restores.clear();
  }
}

/// One global slot from [HookRegistry.slot].
class GlobalSlot<T> {
  GlobalSlot._(this._key, this._read, this._write);

  /// The holder of each global, by key.
  static final Map<Object, GlobalSlot<Object?>> _holders =
      <Object, GlobalSlot<Object?>>{};

  final Object _key;
  final T Function() _read;
  final void Function(T value) _write;

  bool _held = false;
  late T _previous;
  late T _ours;

  /// Whether the slot holds a value written here.
  bool get isHeld => _held;

  /// The value from before the first write: what a chained handler (for
  /// example `FlutterError.onError`) calls on to. Only valid after a
  /// [set].
  T get previous => _previous;

  /// Writes [value]. The first write keeps the value it replaces.
  void set(T value) {
    final holder = _holders[_key];
    if (holder != null &&
        !identical(holder, this) &&
        holder._held &&
        identical(_read(), holder._ours)) {
      // Take over: the other holder no longer restores anything.
      _previous = holder._previous as T;
      holder._held = false;
    } else if (!_held || !identical(_read(), _ours)) {
      // First write, or someone outside Pinpoint wrote the slot since our
      // last write: theirs is what comes back on release.
      _previous = _read();
    }
    _holders[_key] = this;
    _held = true;
    _ours = value;
    _write(value);
  }

  /// Puts back the value from before the first write, unless someone else
  /// wrote the slot after us: then it is theirs and is left alone.
  void release() {
    if (!_held) return;
    _held = false;
    if (identical(_holders[_key], this)) _holders.remove(_key);
    if (identical(_read(), _ours)) _write(_previous);
  }
}

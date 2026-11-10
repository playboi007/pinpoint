import 'package:flutter/services.dart';

/// Installs global hooks and puts them back on [dispose] (engineering rule 1).
///
/// Every single global slot Pinpoint touches goes through here:
/// `HardwareKeyboard` handlers now, later `FlutterError.onError`, the debug
/// callbacks, `timeDilation` and the debug paint flags.
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

  /// Restores every slot, newest first. Safe to call more than once.
  void dispose() {
    for (final restore in _restores.reversed) {
      restore();
    }
    _restores.clear();
  }
}

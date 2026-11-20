import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../core/hook_registry.dart';
import 'console_filter.dart';

/// Replaces `console.error` of the page. No `package:web`: only `console`
/// and `Proxy` are used.
ConsoleFilter createConsoleFilter(HookRegistry hooks) =>
    _WebConsoleFilter(hooks);

class _WebConsoleFilter implements ConsoleFilter {
  _WebConsoleFilter(this._hooks);

  final HookRegistry _hooks;
  final ConsoleLineFilter _filter = ConsoleLineFilter();
  GlobalSlot<JSAny?>? _slot;

  @override
  bool get available => true;

  @override
  bool get active => _slot?.isHeld ?? false;

  @override
  int get dropped => _filter.dropped;

  JSObject? get _console {
    try {
      return globalContext['console'] as JSObject?;
    } catch (_) {
      return null;
    }
  }

  @override
  void install() {
    if (active) return;
    final console = _console;
    if (console == null) return;
    try {
      final original = console['error'];
      if (original == null || !original.isA<JSFunction>()) return;
      _filter.reset();
      // A `Proxy` takes every call with all its arguments, which a Dart
      // closure with fixed parameters cannot: `apply(target, this, args)`.
      final handler = JSObject()..['apply'] = _apply.toJS;
      final proxy = (globalContext['Proxy']! as JSFunction)
          .callAsConstructor<JSObject>(original, handler);
      final slot = _slot ??= _hooks.slot<JSAny?>(
        key: 'console.error',
        read: () => console['error'],
        write: (value) => console['error'] = value,
        // A function read twice from JS is two Dart objects in a wasm build.
        same: (a, b) =>
            a == null || b == null ? a == b : a.strictEquals(b).toDart,
      );
      slot.set(proxy);
    } catch (_) {
      // No console that can be written: leave it as it is.
      _slot?.release();
    }
  }

  JSAny? _apply(JSFunction target, JSAny? thisArg, JSArray<JSAny?> args) {
    try {
      final list = args.toDart;
      if (list.isNotEmpty && list.first.isA<JSString>()) {
        final text = (list.first! as JSString).toDart;
        if (_filter.shouldDrop(text)) return null;
      }
    } catch (_) {
      // The filter only drops; a failure here forwards the call.
    }
    return (target as JSObject).callMethod<JSAny?>('apply'.toJS, thisArg, args);
  }

  @override
  void restore() {
    try {
      _slot?.release();
    } catch (_) {
      // Nothing left to undo.
    }
  }
}

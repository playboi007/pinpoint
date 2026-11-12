import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'browser_page.dart';

BrowserPage createBrowserPage() => const _WebPage();

extension type _Storage._(JSObject _) implements JSObject {
  external int get length;
  external String? key(int index);
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

_Storage? _storage(String name) {
  try {
    final value = globalContext[name];
    return value == null ? null : _Storage._(value as JSObject);
  } catch (_) {
    return null;
  }
}

class _WebPage implements BrowserPage {
  const _WebPage();

  static const String _own = 'pinpoint.';

  @override
  bool get available => true;

  @override
  String get url {
    try {
      final location = globalContext['location']! as JSObject;
      return (location['href']! as JSString).toDart;
    } catch (_) {
      return '';
    }
  }

  Map<String, String> _read(String name) {
    final storage = _storage(name);
    final out = <String, String>{};
    if (storage == null) return out;
    try {
      for (var i = 0; i < storage.length; i++) {
        final key = storage.key(i);
        if (key == null || key.startsWith(_own)) continue;
        final value = storage.getItem(key);
        if (value != null) out[key] = value;
      }
    } catch (_) {}
    return out;
  }

  void _write(String name, Map<String, String>? values) {
    final storage = _storage(name);
    if (storage == null || values == null) return;
    try {
      for (final key in _read(name).keys) {
        storage.removeItem(key);
      }
      for (final MapEntry(:key, :value) in values.entries) {
        if (!key.startsWith(_own)) storage.setItem(key, value);
      }
    } catch (_) {}
  }

  @override
  Map<String, Map<String, String>> readStorage() => {
    'local': _read('localStorage'),
    'session': _read('sessionStorage'),
  };

  @override
  void writeStorage(Map<String, Map<String, String>> storage) {
    _write('localStorage', storage['local']);
    _write('sessionStorage', storage['session']);
  }

  @override
  String? sessionGet(String key) {
    try {
      return _storage('sessionStorage')?.getItem(key);
    } catch (_) {
      return null;
    }
  }

  @override
  void sessionSet(String key, String value) {
    try {
      _storage('sessionStorage')?.setItem(key, value);
    } catch (_) {}
  }

  @override
  void sessionRemove(String key) {
    try {
      _storage('sessionStorage')?.removeItem(key);
    } catch (_) {}
  }

  @override
  void reload() {
    final location = globalContext['location']! as JSObject;
    location.callMethod<JSAny?>('reload'.toJS);
  }

  @override
  void postMessage(String data, String origin) {
    Object? value = data;
    try {
      value = jsonDecode(data);
    } on FormatException {
      // Text, not JSON.
    }
    final init = JSObject()
      ..['data'] = value.jsify()
      ..['origin'] = origin.toJS;
    final event = (globalContext['MessageEvent']! as JSFunction)
        .callAsConstructor<JSObject>('message'.toJS, init);
    (globalContext['window']! as JSObject).callMethod<JSAny?>(
      'dispatchEvent'.toJS,
      event,
    );
  }
}

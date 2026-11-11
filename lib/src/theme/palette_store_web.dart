import 'dart:js_interop';

import 'palette_store.dart';
import 'pinpoint_tokens.dart';

/// `window.localStorage`. Reading the property itself can throw too.
@JS('localStorage')
external _Storage get _storage;

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
}

/// Keeps the pick in `localStorage`, per origin. Storage can be missing or
/// throw (private mode, a blocked cookie setting), so every call is guarded.
class _LocalStoragePaletteStore implements PaletteStore {
  static const String _key = 'pinpoint.theme';

  @override
  PinPointPalette? read() {
    try {
      return PinPointPalette.parse(_storage.getItem(_key));
    } catch (_) {
      return null;
    }
  }

  @override
  void write(PinPointPalette palette) {
    try {
      _storage.setItem(_key, palette.name);
    } catch (_) {
      // The pick is not saved; the palette still changes for this run.
    }
  }
}

PaletteStore createPlatformPaletteStore() => _LocalStoragePaletteStore();

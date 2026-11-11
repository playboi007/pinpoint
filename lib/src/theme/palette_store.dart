import 'package:flutter/foundation.dart';

import 'palette_store_memory.dart'
    if (dart.library.js_interop) 'palette_store_web.dart'
    as platform;
import 'pinpoint_tokens.dart';

/// Where the user's palette pick is kept between runs.
///
/// On web it is `window.localStorage['pinpoint.theme']`, so the pick is saved
/// per origin. Elsewhere it lives in memory only. Both methods must never
/// throw: a store that cannot save simply forgets.
abstract interface class PaletteStore {
  /// The saved palette, or null when none is saved or it cannot be read.
  PinPointPalette? read();

  /// Saves [palette].
  void write(PinPointPalette palette);
}

/// A store for the current platform: `localStorage` on web, memory
/// elsewhere.
PaletteStore createPaletteStore() => platform.createPlatformPaletteStore();

/// A store that keeps the pick in memory. Used outside web and in tests.
class MemoryPaletteStore implements PaletteStore {
  MemoryPaletteStore([this._palette]);

  PinPointPalette? _palette;

  /// How many times [write] was called.
  int writes = 0;

  @override
  PinPointPalette? read() => _palette;

  @override
  void write(PinPointPalette palette) {
    writes++;
    _palette = palette;
  }
}

/// The palette Pinpoint's overlay is drawn in. Listen to it to follow a
/// switch; call [select] to switch and save.
class PaletteController extends ValueNotifier<PinPointPalette> {
  PaletteController({PaletteStore? store})
    : _store = store ?? createPaletteStore(),
      super(PinPointPalette.redline);

  final PaletteStore _store;
  bool _restored = false;

  /// Sets the palette to the saved pick, or to [fallback] when none is saved.
  /// Only the first call has an effect, so a pick made since then is never
  /// replaced when the overlay mounts again.
  void restore(PinPointPalette fallback) {
    if (_restored) return;
    _restored = true;
    value = _store.read() ?? fallback;
  }

  /// Switches to [palette] and saves it.
  void select(PinPointPalette palette) {
    _restored = true;
    value = palette;
    _store.write(palette);
  }
}

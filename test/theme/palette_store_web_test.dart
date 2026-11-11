@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/theme/palette_store.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

/// Runs only in Chrome: `flutter test --platform chrome test/theme/`.
void main() {
  test('the web store round-trips through localStorage', () {
    final store = createPaletteStore();
    store.write(PinPointPalette.ember);
    expect(store.read(), PinPointPalette.ember);
    // A second store reads the same pick: it is shared per origin.
    expect(createPaletteStore().read(), PinPointPalette.ember);
    store.write(PinPointPalette.redline);
    expect(createPaletteStore().read(), PinPointPalette.redline);
  });
}

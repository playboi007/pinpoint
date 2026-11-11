import 'palette_store.dart';

/// Outside web there is no storage Pinpoint may use without a dependency, so
/// the pick lives in memory for this run.
PaletteStore createPlatformPaletteStore() => MemoryPaletteStore();

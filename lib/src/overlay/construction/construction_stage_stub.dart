import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'construction_stage.dart';

/// No page outside a browser: sites are never drawn.
ConstructionStage createConstructionStage() => const _NoStage();

class _NoStage implements ConstructionStage {
  const _NoStage();

  @override
  bool get available => false;

  @override
  void setColors(ConstructionColors colors) {}

  @override
  void setReducedMotion(bool reduced) {}

  @override
  void add(String id, Rect rect) {}

  @override
  void move(String id, Rect rect) {}

  @override
  void reveal(String id, Uint8List? png) {}

  @override
  void remove(String id, {bool fade = true}) {}

  @override
  void dispose() {}
}

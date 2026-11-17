import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:pinpoint/src/overlay/construction/construction_boxes.dart';
import 'package:pinpoint/src/overlay/construction/construction_stage.dart';

/// A stage that only writes down what it was asked to do.
class FakeConstructionStage implements ConstructionStage {
  FakeConstructionStage({this.available = true});

  @override
  final bool available;

  /// Every call, as `kind:id`.
  final List<String> calls = <String>[];

  /// The rects of the sites now up, by id.
  final Map<String, Rect> sites = <String, Rect>{};

  /// The blueprint each site was put up with.
  final Map<String, List<ConstructionBox>> boxes =
      <String, List<ConstructionBox>>{};

  /// What each reveal was given.
  final Map<String, Uint8List?> reveals = <String, Uint8List?>{};

  /// The `fade` of each remove, in order.
  final List<bool> fades = <bool>[];

  ConstructionColors? colors;
  bool reduced = false;
  bool disposed = false;

  int count(String kind) => calls.where((c) => c.startsWith('$kind:')).length;

  @override
  void setColors(ConstructionColors value) => colors = value;

  @override
  void setReducedMotion(bool value) => reduced = value;

  @override
  void add(String id, Rect rect, List<ConstructionBox> blueprint) {
    calls.add('add:$id');
    sites[id] = rect;
    boxes[id] = blueprint;
  }

  @override
  void move(String id, Rect rect) {
    calls.add('move:$id');
    sites[id] = rect;
  }

  @override
  void reveal(String id, Uint8List? png) {
    calls.add('reveal:$id');
    reveals[id] = png;
  }

  @override
  void remove(String id, {bool fade = true}) {
    calls.add('remove:$id');
    sites.remove(id);
    fades.add(fade);
  }

  @override
  void dispose() => disposed = true;
}

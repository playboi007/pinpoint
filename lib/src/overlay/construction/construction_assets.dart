/// One picture of the construction site.
class ConstructionAsset {
  const ConstructionAsset(
    this.name,
    this.file,
    this.width,
    this.height, {
    required this.lineArt,
  });

  /// The name the markup uses. It does not change with the art.
  final String name;

  /// The file in `assets/construction/`, without `.webp`.
  final String file;

  /// The size in CSS pixels at scale 1. A new file may have more pixels
  /// (twice is good for sharp screens) but must have the same aspect ratio.
  final double width;
  final double height;

  /// Black ink on white: drawn with `mix-blend-mode: multiply`, so the white
  /// goes away. Coloured art is drawn with normal blending.
  final bool lineArt;
}

/// The pictures of the construction site: one manifest.
///
/// Now the black line art is used. The coloured set (flat vector, solid
/// fills) replaces it in two steps: put the files named in [colouredSet]
/// into `assets/construction/` (webp, transparent background, the aspect
/// ratio of each size), then set [coloured] to true. Nothing else changes.
///
/// Two-frame characters are two files, `..._a` and `..._b`; the page
/// switches between them by CSS steps.
abstract final class ConstructionAssets {
  /// Use the coloured files.
  static const bool coloured = false;

  /// The files of today, mapped to the new names. A frame b that equals
  /// frame a means "no second frame yet". `hammer_arm` and `roller` are
  /// loose parts that only these placeholders need: they are drawn on top
  /// of the body, and swing by CSS.
  static const List<ConstructionAsset> placeholders = [
    ConstructionAsset('planner_read_a', 'hammer_body', 60, 123, lineArt: true),
    ConstructionAsset('planner_read_b', 'hammer_body', 60, 123, lineArt: true),
    ConstructionAsset('planner_point_a', 'done', 74, 123, lineArt: true),
    ConstructionAsset('planner_point_b', 'done', 74, 123, lineArt: true),
    ConstructionAsset('builder_a', 'hammer_body', 60, 123, lineArt: true),
    ConstructionAsset('builder_b', 'hammer_body', 60, 123, lineArt: true),
    ConstructionAsset('walk_a', 'walk_a', 121, 112, lineArt: true),
    ConstructionAsset('walk_b', 'walk_b', 121, 112, lineArt: true),
    ConstructionAsset('painter_a', 'painter', 114, 189, lineArt: true),
    ConstructionAsset('painter_b', 'painter', 114, 189, lineArt: true),
    ConstructionAsset('done', 'done', 88, 146, lineArt: true),
    ConstructionAsset('cone', 'cone', 65, 81, lineArt: true),
    ConstructionAsset('hammer_arm', 'hammer_arm', 68, 68, lineArt: true),
    ConstructionAsset('roller', 'roller', 114, 189, lineArt: true),
  ];

  /// The coloured set: each file is named like its asset. The canvas of a
  /// two-frame character is the same in both frames, so the figure does
  /// not jump. The builder's canvas has room for the swing of the hammer.
  static const List<ConstructionAsset> colouredSet = [
    ConstructionAsset(
      'planner_read_a',
      'planner_read_a',
      74,
      123,
      lineArt: false,
    ),
    ConstructionAsset(
      'planner_read_b',
      'planner_read_b',
      74,
      123,
      lineArt: false,
    ),
    ConstructionAsset(
      'planner_point_a',
      'planner_point_a',
      74,
      123,
      lineArt: false,
    ),
    ConstructionAsset(
      'planner_point_b',
      'planner_point_b',
      74,
      123,
      lineArt: false,
    ),
    ConstructionAsset('builder_a', 'builder_a', 95, 123, lineArt: false),
    ConstructionAsset('builder_b', 'builder_b', 95, 123, lineArt: false),
    ConstructionAsset('walk_a', 'walk_a', 121, 112, lineArt: false),
    ConstructionAsset('walk_b', 'walk_b', 121, 112, lineArt: false),
    ConstructionAsset('painter_a', 'painter_a', 114, 189, lineArt: false),
    ConstructionAsset('painter_b', 'painter_b', 114, 189, lineArt: false),
    ConstructionAsset('done', 'done', 88, 146, lineArt: false),
    ConstructionAsset('cone', 'cone', 65, 81, lineArt: false),
  ];

  /// The set in use.
  static const List<ConstructionAsset> all = coloured
      ? colouredSet
      : placeholders;

  /// Whether the loose arm and roller parts are drawn (placeholders only).
  static const bool looseParts = !coloured;

  /// The names the markup asks for, in the order of [all].
  static List<String> get names => [for (final a in all) a.name];

  /// The asset [name] of the set in use.
  static ConstructionAsset of(String name) =>
      all.firstWhere((a) => a.name == name);
}

/// One picture of the construction site.
class ConstructionAsset {
  const ConstructionAsset(this.name, this.file, this.width, this.height);

  /// The name the markup uses. It does not change with the art.
  final String name;

  /// The file in `assets/construction/`, without `.webp`.
  final String file;

  /// The size in CSS pixels at scale 1: half the pixels of the file (the
  /// files are made at 2x for sharp screens). A new file must keep the
  /// aspect ratio.
  final double width;
  final double height;
}

/// The pictures of the construction site: one manifest.
///
/// The art is the coloured set: flat vector, solid fills, transparent
/// background, drawn with normal blending. Two-frame characters are two
/// files, `..._a` and `..._b`, that share one canvas (the figure does not
/// jump); the page switches between them by CSS steps. A character is drawn
/// at its real proportions: the layout scales it by its height.
///
/// The stacker (the worker with booster shoes) has his own art in
/// [stackerSet]. With [stackerArt] false, his poses fall back to
/// `planner_point_a/b` with CSS flames and a CSS block.
abstract final class ConstructionAssets {
  // The sizes of the files in CSS pixels (the file is twice as big).
  static const double plannerReadWidth = 84;
  static const double plannerReadHeight = 127;
  static const double plannerPointWidth = 86.5;
  static const double plannerPointHeight = 129;
  static const double builderWidth = 119;
  static const double builderHeight = 130.5;
  static const double walkWidth = 139.5;
  static const double walkHeight = 124;
  static const double painterWidth = 84.5;
  static const double painterHeight = 146;
  static const double doneWidth = 70;
  static const double doneHeight = 128.5;
  static const double coneWidth = 61.5;
  static const double coneHeight = 70;

  /// Where the builder's hammer head is in `builder_b` (the strike frame),
  /// as a fraction of the picture's width and height.
  static const double hammerHeadX = 0.987;
  static const double hammerHeadY = 0.398;

  /// Whether the stacker's own files are used. False: placeholders.
  static const bool stackerArt = true;

  /// The canvas of the four stacker poses: the same size for all of them,
  /// 220 x 330 pixels in the files. Standing, his feet are on the bottom
  /// edge; flying, his flames are. The three flying poses share one
  /// placement, so switching between them does not move him.
  static const double stackerWidth = stackerArt ? 110 : 86.5;
  static const double stackerHeight = stackerArt ? 165 : 129;

  /// How much of the canvas height the standing figure fills: the layout
  /// makes that part as tall as the other workers.
  static const double stackerFigure = stackerArt ? 224 / 330 : 1;

  /// The block (a light foam cube), as wide as the one he carries in the
  /// poses: 22 canvas pixels (80 x 80 pixels in the file, drawn smaller).
  static const double blockSize = stackerArt ? 22 : 40;

  /// Where the palms of `stacker_stand` are, as a fraction of the canvas
  /// (he faces left, toward the wheelbarrow): the block flies there.
  static const double stackerHandX = stackerArt ? 0.36 : 0.2;
  static const double stackerHandY = stackerArt ? 0.65 : 0.55;

  /// Where the bottom of the block is in the flying poses, as a fraction of
  /// the canvas height from the top (measured at row 88 of 330 in `fly_a`).
  /// The placeholder's block sits on the head of `planner_point`, 6 px from
  /// the top of the canvas.
  static const double stackerBlockBottom = stackerArt ? 0.27 : 0.045;

  /// The same line in `stacker_place`, which holds the block lower and more
  /// to the left (bottom at row 130 of 330, centre at x 53 of 220). He
  /// flies so that this line is on the top edge of the box he repairs, so
  /// that the block comes down onto the box as he places it.
  static const double stackerPlaceBlockBottom = stackerArt ? 0.39 : 0.045;
  static const double stackerPlaceBlockX = stackerArt ? 0.24 : 0.5;

  /// The highest and widest content of the flying poses, as a fraction of
  /// the canvas (the block's top at row 42; the content from x 28 to 173):
  /// he is kept under the tape and inside the site by these.
  static const double stackerContentTop = stackerArt ? 42 / 330 : -0.2;
  static const double stackerContentLeft = stackerArt ? 28 / 220 : 0;
  static const double stackerContentRight = stackerArt ? 173 / 220 : 1;

  /// The names of the stacker's poses: his own art, or the placeholders.
  static const String stackerStand = stackerArt
      ? 'stacker_stand'
      : 'planner_point_a';
  static const String stackerFlyA = stackerArt
      ? 'stacker_fly_a'
      : 'planner_point_a';
  static const String stackerFlyB = stackerArt
      ? 'stacker_fly_b'
      : 'planner_point_b';
  static const String stackerPlace = stackerArt
      ? 'stacker_place'
      : 'planner_point_b';

  /// The files that exist now, each named like its asset.
  static const List<ConstructionAsset> base = [
    ConstructionAsset(
      'planner_read_a',
      'planner_read_a',
      plannerReadWidth,
      plannerReadHeight,
    ),
    ConstructionAsset(
      'planner_read_b',
      'planner_read_b',
      plannerReadWidth,
      plannerReadHeight,
    ),
    ConstructionAsset(
      'planner_point_a',
      'planner_point_a',
      plannerPointWidth,
      plannerPointHeight,
    ),
    ConstructionAsset(
      'planner_point_b',
      'planner_point_b',
      plannerPointWidth,
      plannerPointHeight,
    ),
    ConstructionAsset('builder_a', 'builder_a', builderWidth, builderHeight),
    ConstructionAsset('builder_b', 'builder_b', builderWidth, builderHeight),
    ConstructionAsset('walk_a', 'walk_a', walkWidth, walkHeight),
    ConstructionAsset('walk_b', 'walk_b', walkWidth, walkHeight),
    ConstructionAsset('painter_a', 'painter_a', painterWidth, painterHeight),
    ConstructionAsset('painter_b', 'painter_b', painterWidth, painterHeight),
    ConstructionAsset('done', 'done', doneWidth, doneHeight),
    ConstructionAsset('cone', 'cone', coneWidth, coneHeight),
  ];

  /// The stacker's files, for when they are made: four poses on one canvas
  /// and the block. `stacker_stand` is back three-quarter with the hands out
  /// to receive. `stacker_fly_a` and `stacker_fly_b` fly with the block over
  /// the head, the flames under the boots flicker between the two.
  /// `stacker_place` pushes the block forward to put it on a box.
  static const List<ConstructionAsset> stackerSet = [
    ConstructionAsset(
      'stacker_stand',
      'stacker_stand',
      stackerWidth,
      stackerHeight,
    ),
    ConstructionAsset(
      'stacker_fly_a',
      'stacker_fly_a',
      stackerWidth,
      stackerHeight,
    ),
    ConstructionAsset(
      'stacker_fly_b',
      'stacker_fly_b',
      stackerWidth,
      stackerHeight,
    ),
    ConstructionAsset(
      'stacker_place',
      'stacker_place',
      stackerWidth,
      stackerHeight,
    ),
    ConstructionAsset('block', 'block', blockSize, blockSize),
  ];

  /// The set in use.
  static const List<ConstructionAsset> all = stackerArt
      ? [...base, ...stackerSet]
      : base;

  /// The names the markup asks for, in the order of [all].
  static List<String> get names => [for (final a in all) a.name];

  /// The asset [name] of the set in use.
  static ConstructionAsset of(String name) =>
      all.firstWhere((a) => a.name == name);
}

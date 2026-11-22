part of 'construction_layout.dart';

/// The tape band at the top, as tall as its text needs.
class _Tape {
  factory _Tape(double w, double h) {
    // The text shrinks to the width: 14 letters of Roboto Mono, with spacing.
    final fs = ((w - 12) / 9.6).clamp(5.0, 10.0);
    // A short widget gets a thinner band, so the workers keep room below.
    final th = math.min(
      h,
      math.min(
        (fs + 6).roundToDouble(),
        math.max(10.0, (0.3 * h).roundToDouble()),
      ),
    );
    return _Tape._(
      th,
      math.min(fs, math.max(4.0, th - 5)),
      h >= ConstructionLayout.minWorkersHeight ? 0.0 : (h - th) / 2,
    );
  }

  const _Tape._(this.height, this.font, this.top);

  final double height;
  final double font;
  final double top;
}

/// The scale of each character, from the worker height [wh]. Each one is
/// drawn at its real proportions, scaled by height.
class _Scales {
  _Scales(double wh, double h)
    : hammer = wh / ConstructionLayout._hammerHeight,
      planner = wh / ConstructionLayout._plannerHeight,
      // His standing figure, not his whole canvas, is as tall as the others.
      stacker =
          wh /
          (ConstructionLayout._stackerHeight *
              ConstructionAssets.stackerFigure),
      // The wheelbarrow worker is a little smaller than the builder.
      barrow = 0.8 * wh / ConstructionLayout._barrowHeight,
      // The painter, with the ladder, is a little taller.
      painter = math.min(wh * 1.1, 0.9 * h) / ConstructionLayout._painterHeight,
      cone = 0.42 * wh / ConstructionLayout._coneHeight,
      done = math.min(wh * 1.1, 0.92 * h) / ConstructionLayout._doneHeight;

  final double hammer;
  final double planner;
  final double stacker;
  final double barrow;
  final double painter;
  final double cone;
  final double done;

  double get hammerWidth => ConstructionLayout._hammerWidth * hammer;
  double get barrowWidth => ConstructionLayout._barrowWidth * barrow;
  double get coneWidth => ConstructionLayout._coneWidth * cone;
  double get plannerWidth => ConstructionLayout._plannerWidth * planner;
  double get stackerWidth => ConstructionLayout._stackerWidth * stacker;
  double get painterWidth => ConstructionLayout._painterWidth * painter;
}

/// Which characters fit in a site of width [w], and the zone they share.
class _Fit {
  factory _Fit(
    double w,
    double widgetHeight,
    _Scales s,
    List<ConstructionBox> boxes,
  ) {
    const pad = ConstructionLayout.pad;
    final hw = s.hammerWidth;
    final bw = s.barrowWidth;
    final pw = s.plannerWidth;
    final ssw = s.stackerWidth;

    // At the right: two planners when they fit, else the one that reads
    // the blueprint.
    final two = w >= 2 * pw + 3 * pad;
    final plannersWidth = two ? 2 * pw + pad : pw;
    // The work zone ends where the planners start.
    final zoneEnd = w - pad - plannersWidth - pad;

    // In the zone, from the left: cone, gap, builder, gap, the wheelbarrow's
    // lane (the stacker at its end), gap, cone. Without room for the cones
    // and the builder there is no builder: the planners work alone.
    final edge = pad + s.coneWidth + pad;
    final builderFit = zoneEnd >= hw + 2 * edge;
    final lane = zoneEnd - 2 * edge - hw - pad;
    final barrowFit = builderFit && lane >= bw + ConstructionLayout.minRun;
    // The painter needs a wide widget: room for the lane and itself.
    final painterFit =
        barrowFit &&
        lane >= bw + ConstructionLayout.minRun + s.painterWidth + pad;
    // The stacker needs room for himself at the end of the lane, and a box
    // in the upper half to work on.
    final stackerFit =
        barrowFit &&
        lane >=
            bw +
                ConstructionLayout.minRun +
                ssw +
                ConstructionLayout.handoffGap &&
        boxes.any((b) => ConstructionBoxes.isHigh(b, widgetHeight));

    return _Fit._(
      two: two,
      plannersWidth: plannersWidth,
      zoneEnd: zoneEnd,
      edge: edge,
      builderFit: builderFit,
      barrowFit: barrowFit,
      painterFit: painterFit,
      stackerFit: stackerFit,
      laneEnd: zoneEnd - edge,
      defaultLeft: barrowFit ? edge : math.max(pad, (zoneEnd - hw) / 2),
    );
  }

  const _Fit._({
    required this.two,
    required this.plannersWidth,
    required this.zoneEnd,
    required this.edge,
    required this.builderFit,
    required this.barrowFit,
    required this.painterFit,
    required this.stackerFit,
    required this.laneEnd,
    required this.defaultLeft,
  });

  final bool two;
  final double plannersWidth;
  final double zoneEnd;
  final double edge;
  final bool builderFit;
  final bool barrowFit;
  final bool painterFit;
  final bool stackerFit;
  final double laneEnd;
  final double defaultLeft;
}

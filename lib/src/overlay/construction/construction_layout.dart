import 'dart:math' as math;

import 'construction_assets.dart';
import 'construction_boxes.dart';

part 'construction_layout_fit.dart';

/// Where the parts of one construction site go, in CSS pixels, for a widget
/// of a given size.
///
/// Plain numbers only (no `dart:ui`), so the markup that uses it can be
/// built anywhere. Each character has a design box (the sizes of its
/// pictures, see `ConstructionAssets`); it is drawn at its real proportions,
/// scaled by its height: the builder and the planners are [workerHeight]
/// tall.
///
/// The zones, read from the right: the planners stand at the right, the
/// builder, the wheelbarrow and the stacker work in the middle, and the
/// painter and the "done" worker of the finish are at the left. A widget too
/// small for all of them gets fewer: planners only, then the builder, then
/// the wheelbarrow, the stacker and the painter; under [minWorkersHeight]
/// there are only tape and hatching.
///
/// The builder stands so that, in the strike frame, his hammer head is on
/// an edge of the biggest box of the blueprint, when that fits in the zone.
class ConstructionLayout {
  const ConstructionLayout._({
    required this.width,
    required this.height,
    required this.workerHeight,
    required this.planners,
    required this.hammer,
    required this.cones,
    required this.barrow,
    required this.painter,
    required this.stacker,
    required this.aimed,
    required this.hammerScale,
    required this.plannerScale,
    required this.stackerScale,
    required this.barrowScale,
    required this.painterScale,
    required this.doneScale,
    required this.coneScale,
    required this.hammerLeft,
    required this.barrowLeft,
    required this.barrowRun,
    required this.stackerLeft,
    required this.zoneEnd,
    required this.plannersWidth,
    required this.tapeHeight,
    required this.tapeFont,
    required this.tapeTop,
    required this.walkSeconds,
  });

  /// A site with tape and hatching only: no workers fit.
  ConstructionLayout._bare({
    required this.width,
    required this.height,
    required _Tape tape,
  }) : workerHeight = 0,
       planners = 0,
       hammer = false,
       cones = false,
       barrow = false,
       painter = false,
       stacker = false,
       aimed = false,
       hammerScale = 0,
       plannerScale = 0,
       stackerScale = 0,
       barrowScale = 0,
       painterScale = 0,
       doneScale = 0,
       coneScale = 0,
       hammerLeft = 0,
       barrowLeft = 0,
       barrowRun = 0,
       stackerLeft = 0,
       zoneEnd = 0,
       plannersWidth = 0,
       tapeHeight = tape.height,
       tapeFont = tape.font,
       tapeTop = tape.top,
       walkSeconds = 4;

  /// The layout for a site that covers a widget [widgetWidth] by
  /// [widgetHeight], which is the site's size less the 2 px around it.
  ///
  /// [boxes] is the blueprint, in the widget's own pixels: the builder aims
  /// at the biggest one, and the stacker works only when one of them is in
  /// the upper half of the widget.
  factory ConstructionLayout.of(
    double widgetWidth,
    double widgetHeight, {
    List<ConstructionBox> boxes = const [],
  }) {
    final w = widgetWidth + 2 * overscan;
    final h = widgetHeight + 2 * overscan;
    final tape = _Tape(w, h);
    final wh = _workerHeightFor(widgetHeight, w, h, tape.height);
    final hasWorkers =
        widgetHeight >= minWorkersHeight && wh >= minWorkerHeight;
    if (!hasWorkers) {
      return ConstructionLayout._bare(width: w, height: h, tape: tape);
    }

    final scales = _Scales(wh, h);
    final fit = _Fit(w, widgetHeight, scales, boxes);
    final aim = _aimFor(
      boxes: boxes,
      widgetWidth: widgetWidth,
      widgetHeight: widgetHeight,
      siteHeight: h,
      scales: scales,
      fit: fit,
    );
    final hammerLeft = aim ?? fit.defaultLeft;
    final (:barrowLeft, :run, :stackerLeft) = _lane(scales, fit, hammerLeft);
    return ConstructionLayout._(
      width: w,
      height: h,
      workerHeight: wh,
      planners: fit.two ? 2 : 1,
      hammer: fit.builderFit,
      cones: fit.builderFit,
      barrow: fit.barrowFit,
      painter: fit.painterFit,
      stacker: fit.stackerFit,
      aimed: aim != null,
      hammerScale: scales.hammer,
      plannerScale: scales.planner,
      stackerScale: scales.stacker,
      barrowScale: scales.barrow,
      painterScale: scales.painter,
      doneScale: scales.done,
      coneScale: scales.cone,
      hammerLeft: hammerLeft,
      barrowLeft: barrowLeft,
      barrowRun: run,
      stackerLeft: stackerLeft,
      zoneEnd: fit.zoneEnd,
      plannersWidth: fit.plannersWidth,
      tapeHeight: tape.height,
      tapeFont: tape.font,
      tapeTop: tape.top,
      // About 30 px a second, there and back, with a pause at each end.
      walkSeconds: (2 * run / 30 / 0.92).clamp(4.0, 40.0),
    );
  }

  /// A worker's height: 56 px, or half the height on a big widget (at most
  /// 110 px), never over 85% of the height or behind the tape, and one
  /// planner must fit the width.
  static double _workerHeightFor(
    double widgetHeight,
    double w,
    double h,
    double tapeHeight,
  ) {
    final cap = (0.5 * widgetHeight).clamp(baseWorkerHeight, maxWorkerHeight);
    var wh = math.min(cap, 0.85 * widgetHeight);
    wh = math.min(wh, h - tapeHeight - 2);
    return math.min(wh, (w - 2 * pad) / _plannerWidth * _plannerHeight);
  }

  /// The builder moves right, to hit an edge of the biggest box. To the
  /// right he still leaves room for the wheelbarrow's shortest walk and the
  /// stacker.
  static double? _aimFor({
    required List<ConstructionBox> boxes,
    required double widgetWidth,
    required double widgetHeight,
    required double siteHeight,
    required _Scales scales,
    required _Fit fit,
  }) {
    if (!fit.builderFit) return null;
    final reserve = fit.barrowFit
        ? scales.barrowWidth +
              minRun +
              pad +
              (fit.stackerFit ? scales.stackerWidth + handoffGap : 0)
        : 0.0;
    return _aim(
      boxes: boxes,
      widgetWidth: widgetWidth,
      widgetHeight: widgetHeight,
      siteHeight: siteHeight,
      scale: scales.hammer,
      width: scales.hammerWidth,
      low: fit.edge,
      high: fit.laneEnd - reserve - scales.hammerWidth,
      fallback: fit.defaultLeft,
    );
  }

  /// Where the wheelbarrow starts, how far it runs, and where the stacker
  /// stands, for a builder at [hammerLeft].
  static ({double barrowLeft, double run, double stackerLeft}) _lane(
    _Scales scales,
    _Fit fit,
    double hammerLeft,
  ) {
    final laneStart = hammerLeft + scales.hammerWidth + pad;
    final bw = scales.barrowWidth;
    if (!fit.stackerFit) {
      return (
        barrowLeft: laneStart,
        run: math.max(0.0, fit.laneEnd - laneStart - bw),
        stackerLeft: 0.0,
      );
    }
    // The stacker stands at the end of the lane; the wheelbarrow walks up to
    // him, a short way only: one trip a few seconds long.
    final stackerLeft = fit.laneEnd - scales.stackerWidth;
    final endLeft = stackerLeft - handoffGap - bw;
    final barrowLeft = math.max(laneStart, endLeft - maxHandoffRun);
    return (
      barrowLeft: barrowLeft,
      run: math.max(0.0, endLeft - barrowLeft),
      stackerLeft: stackerLeft,
    );
  }

  /// The builder's left edge so that his hammer head, in the strike frame,
  /// is on the left or right edge of the biggest box, at the head's height;
  /// null when that cannot be: no big box, the head's height is not beside
  /// the box, or the builder would leave the room `[low, high]` of the zone.
  /// The edge that moves him least from [fallback] wins.
  static double? _aim({
    required List<ConstructionBox> boxes,
    required double widgetWidth,
    required double widgetHeight,
    required double siteHeight,
    required double scale,
    required double width,
    required double low,
    required double high,
    required double fallback,
  }) {
    if (boxes.isEmpty || high < low) return null;
    var big = boxes.first;
    for (final b in boxes) {
      if (b.area > big.area) big = b;
    }
    if (big.area < minBigShare * widgetWidth * widgetHeight) return null;
    // The head's height in the site: the builder's feet are 2 px above the
    // bottom.
    final headY =
        siteHeight -
        2 -
        (1 - ConstructionAssets.hammerHeadY) * _hammerHeight * scale;
    final top = big.top + overscan;
    final bottom = big.top + big.height + overscan;
    if (headY < top + 2 || headY > bottom - 2) return null;
    double? best;
    for (final edgeX in [
      big.left + overscan,
      big.left + big.width + overscan,
    ]) {
      final left = edgeX - ConstructionAssets.hammerHeadX * width;
      if (left < low || left > high) continue;
      if (best == null || (left - fallback).abs() < (best - fallback).abs()) {
        best = left;
      }
    }
    return best;
  }

  /// Pixels the cover goes past the widget on each side.
  static const double overscan = 1;

  /// A worker's height on an ordinary widget.
  static const double baseWorkerHeight = 56;

  /// The tallest a worker is drawn, on a big widget: about the assets' own
  /// size, so they stay sharp.
  static const double maxWorkerHeight = 110;

  /// Under this widget height there are no workers: hatching and tape only.
  static const double minWorkersHeight = 24;

  /// Under this worker height they are not worth drawing.
  static const double minWorkerHeight = 14;

  /// Space between parts.
  static const double pad = 4;

  /// The least the wheelbarrow walks.
  static const double minRun = 20;

  /// The gap between the wheelbarrow and the stacker at the hand-off.
  static const double handoffGap = 6;

  /// The most the wheelbarrow walks to the stacker, when he is there.
  static const double maxHandoffRun = 56;

  /// The biggest box is "big" when it covers this share of the widget.
  static const double minBigShare = 0.1;

  /// At most this many sites at once.
  static const int maxSites = 3;

  // The design boxes of the characters, in CSS pixels at scale 1. They are
  // the sizes in `ConstructionAssets`: a new picture of a character has the
  // same aspect ratio.
  static const double _hammerWidth = ConstructionAssets.builderWidth;
  static const double _hammerHeight = ConstructionAssets.builderHeight;
  static const double _plannerWidth = ConstructionAssets.plannerPointWidth;
  static const double _plannerHeight = ConstructionAssets.plannerPointHeight;
  static const double _barrowWidth = ConstructionAssets.walkWidth;
  static const double _barrowHeight = ConstructionAssets.walkHeight;
  static const double _painterWidth = ConstructionAssets.painterWidth;
  static const double _painterHeight = ConstructionAssets.painterHeight;
  static const double _coneWidth = ConstructionAssets.coneWidth;
  static const double _coneHeight = ConstructionAssets.coneHeight;
  static const double _doneHeight = ConstructionAssets.doneHeight;
  static const double _stackerWidth = ConstructionAssets.stackerWidth;
  static const double _stackerHeight = ConstructionAssets.stackerHeight;

  /// The site's size: the widget's, plus [overscan] on each side.
  final double width;
  final double height;

  /// The height of the builder and the planners; 0 without workers.
  final double workerHeight;

  /// How many planners show: 0 (bare), 1 or 2.
  final int planners;

  /// Which parts show.
  final bool hammer;
  final bool cones;
  final bool barrow;
  final bool painter;
  final bool stacker;

  /// Whether the builder stands where his hammer head hits an edge of the
  /// biggest box (false: he stands at his usual place).
  final bool aimed;

  /// The CSS scale of each part: its drawn size times this.
  final double hammerScale;
  final double plannerScale;
  final double stackerScale;
  final double barrowScale;
  final double painterScale;
  final double doneScale;
  final double coneScale;

  /// Left edge of the builder.
  final double hammerLeft;

  /// Left edge of the wheelbarrow's lane, and how far it walks.
  final double barrowLeft;
  final double barrowRun;

  /// Left edge of the stacker at the hand-off spot (0 without him).
  final double stackerLeft;

  /// Where the work zone ends: the planners stand to the right of it.
  final double zoneEnd;

  /// The width of the planners together.
  final double plannersWidth;

  /// The tape's height, font size and distance from the top.
  final double tapeHeight;
  final double tapeFont;
  final double tapeTop;

  /// Seconds for the wheelbarrow to walk there and back.
  final double walkSeconds;

  /// Whether any worker shows.
  bool get hasWorkers => planners > 0;

  /// The y of the ground the workers stand on, in the site.
  double get groundY => height - 2;

  /// The builder's drawn size.
  double get hammerBoxWidth => _hammerWidth * hammerScale;
  double get hammerBoxHeight => _hammerHeight * hammerScale;

  /// The wheelbarrow worker's drawn size.
  double get barrowBoxWidth => _barrowWidth * barrowScale;
  double get barrowBoxHeight => _barrowHeight * barrowScale;

  /// The stacker's drawn size.
  double get stackerBoxWidth => _stackerWidth * stackerScale;
  double get stackerBoxHeight => _stackerHeight * stackerScale;

  /// Where the builder's hammer head is in the strike frame, in the site.
  double get hammerHeadX =>
      hammerLeft + ConstructionAssets.hammerHeadX * hammerBoxWidth;
  double get hammerHeadY =>
      groundY - (1 - ConstructionAssets.hammerHeadY) * hammerBoxHeight;

  /// The classes of the site's element: which parts show.
  List<String> get classes => [
    if (!hasWorkers) 'ppc-bare',
    if (planners == 2) 'ppc-plan2',
    if (hammer) 'ppc-hammer-on',
    if (cones) 'ppc-cones',
    if (barrow) 'ppc-barrow-on',
    if (painter) 'ppc-painter-on',
    if (stacker) 'ppc-stacker-on',
  ];

  static String _n(double v) {
    final s = v.toStringAsFixed(3);
    return s.contains('.')
        ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : s;
  }

  double get _plannerBoxWidth => _plannerWidth * plannerScale;

  /// The inline `style` text of the site's element, without its position.
  ///
  /// `--sh` scales the builder, `--spl` the planners, `--sb` the
  /// wheelbarrow worker, `--ss` the stacker, `--sw` is the site's width
  /// (the measure line sweeps that far), `--hl` the builder's left edge
  /// (where his hammer hits an edge of the big box), `--hin` and `--bin` how
  /// far the builder and the wheelbarrow walk in, `--pout` how far the
  /// planners walk out, `--pa` and `--pb` where the two planners stand (from
  /// the right edge), `--cl2` the left edge of the far cone, `--kl` the
  /// stacker's left edge, `--ppw` and `--prun` the painter's width and how
  /// far it rolls, `--dl` the left edge of the "done" worker.
  String get variables =>
      '--sh:${_n(hammerScale)};--spl:${_n(plannerScale)};'
      '--sb:${_n(barrowScale)};--ss:${_n(stackerScale)};'
      '--sp:${_n(painterScale)};--sd:${_n(doneScale)};'
      '--sc:${_n(coneScale)};--hl:${_n(hammerLeft)}px;'
      '--bl:${_n(barrowLeft)}px;--run:${_n(barrowRun)}px;'
      '--kl:${_n(stackerLeft)}px;'
      '--th:${_n(tapeHeight)}px;'
      '--tf:${_n(tapeFont)}px;--tt:${_n(tapeTop)}px;--wd:${_n(walkSeconds)}s;'
      '--fa:${_n(fallDegrees)}deg;--sw:${_n(width)}px;'
      '--hin:${_n(hammerLeft + hammerBoxWidth)}px;'
      '--bin:${_n(barrowLeft + barrowBoxWidth)}px;'
      '--pout:${_n(plannersWidth + 2 * pad)}px;'
      '--pa:${_n(2 * pad + _plannerBoxWidth)}px;--pb:${_n(pad)}px;'
      '--cl2:${_n(zoneEnd - pad - _coneWidth * coneScale)}px;'
      '--ppw:${_n(_painterWidth * painterScale)}px;'
      '--prun:${_n(width - pad - _painterWidth * painterScale)}px;'
      '--dl:${_n(pad)}px';

  /// How far each half of the snapped tape swings down from its outer end:
  /// its free end drops about 70% of the height, so it stays over the
  /// widget and never sweeps across the page.
  double get fallDegrees =>
      (math.atan2(0.7 * height, math.max(width / 2, 1)) * 180 / math.pi).clamp(
        6.0,
        35.0,
      );
}

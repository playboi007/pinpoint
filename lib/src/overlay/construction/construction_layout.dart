import 'dart:math' as math;

/// Where the parts of one construction site go, in CSS pixels, for a widget
/// of a given size.
///
/// Plain numbers only (no `dart:ui`), so the markup that uses it can be
/// built anywhere. Each character has a design box (see the constants
/// below); at height [workerHeight] the builder's scale is
/// `workerHeight / 123`.
///
/// The zones, read from the right: the planners stand at the right, the
/// builder and the wheelbarrow work in the middle, and the painter and the
/// "done" worker of the finish are at the left. A widget too small for all
/// of them gets fewer: planners only, then the builder, then the wheelbarrow
/// and the painter; under [minWorkersHeight] there are only tape and hatching.
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
    required this.hammerScale,
    required this.barrowScale,
    required this.painterScale,
    required this.doneScale,
    required this.coneScale,
    required this.hammerLeft,
    required this.barrowLeft,
    required this.barrowRun,
    required this.zoneEnd,
    required this.plannersWidth,
    required this.tapeHeight,
    required this.tapeFont,
    required this.tapeTop,
    required this.walkSeconds,
  });

  /// The layout for a site that covers a widget [widgetWidth] by
  /// [widgetHeight], which is the site's size less the 2 px around it.
  factory ConstructionLayout.of(double widgetWidth, double widgetHeight) {
    final w = widgetWidth + 2 * overscan;
    final h = widgetHeight + 2 * overscan;

    // Tape: a band at the top, as tall as its text needs. The text shrinks
    // to the width: 14 letters of Roboto Mono, with spacing.
    final fs = ((w - 12) / 9.6).clamp(5.0, 10.0);
    // A short widget gets a thinner band, so the workers keep room below.
    final th = math.min(
      h,
      math.min(
        (fs + 6).roundToDouble(),
        math.max(10.0, (0.3 * h).roundToDouble()),
      ),
    );
    final tapeFont = math.min(fs, math.max(4.0, th - 5));
    final tapeTop = h >= minWorkersHeight ? 0.0 : (h - th) / 2;

    // 56 px, or half the height on a big widget (at most 110 px, the
    // assets' own size), never over 85% of the height or behind the tape.
    final cap = (0.5 * widgetHeight).clamp(baseWorkerHeight, maxWorkerHeight);
    var wh = math.min(cap, 0.85 * widgetHeight);
    wh = math.min(wh, h - th - 2);
    // One planner must fit the width as well.
    wh = math.min(wh, (w - 2 * pad) / _plannerWidth * _plannerHeight);
    final workers = widgetHeight >= minWorkersHeight && wh >= minWorkerHeight;
    if (!workers) {
      return ConstructionLayout._(
        width: w,
        height: h,
        workerHeight: 0,
        planners: 0,
        hammer: false,
        cones: false,
        barrow: false,
        painter: false,
        hammerScale: 0,
        barrowScale: 0,
        painterScale: 0,
        doneScale: 0,
        coneScale: 0,
        hammerLeft: 0,
        barrowLeft: 0,
        barrowRun: 0,
        zoneEnd: 0,
        plannersWidth: 0,
        tapeHeight: th,
        tapeFont: tapeFont,
        tapeTop: tapeTop,
        walkSeconds: 4,
      );
    }

    // The builder and the planners are as tall as wh.
    final sh = wh / _hammerHeight;
    // The wheelbarrow worker is a little smaller than the builder.
    final sb = sh * 0.8;
    // The painter, with the ladder, is a little taller.
    final sp = math.min(wh * 1.1, 0.9 * h) / _painterHeight;
    final sc = 0.42 * wh / _coneHeight;
    final sd = math.min(wh * 1.1, 0.92 * h) / _doneHeight;
    final hw = _hammerWidth * sh;
    final bw = _barrowWidth * sb;
    final cw = _coneWidth * sc;
    final pw = _plannerWidth * sh;

    // At the right: two planners when they fit, else the one that reads
    // the blueprint.
    final two = w >= 2 * pw + 3 * pad;
    final plannersWidth = two ? 2 * pw + pad : pw;
    // The work zone ends where the planners start.
    final zoneEnd = w - pad - plannersWidth - pad;

    // In the zone, from the left: cone, gap, builder, gap, the wheelbarrow's
    // lane, gap, cone. Without room for the cones and the builder there is
    // no builder: the planners work alone.
    final edge = pad + cw + pad;
    final builderFit = zoneEnd >= hw + 2 * edge;
    final lane = zoneEnd - 2 * edge - hw - pad;
    final barrowFit = builderFit && lane >= bw + minRun;
    // The painter needs a wide widget: room for the lane and itself.
    final pw2 = _painterWidth * sp;
    final painterFit = barrowFit && lane >= bw + minRun + pw2 + pad;

    final hammerLeft = barrowFit ? edge : math.max(pad, (zoneEnd - hw) / 2);
    final laneStart = hammerLeft + hw + pad;
    final laneEnd = zoneEnd - edge;
    final run = math.max(0.0, laneEnd - laneStart - bw);
    return ConstructionLayout._(
      width: w,
      height: h,
      workerHeight: wh,
      planners: two ? 2 : 1,
      hammer: builderFit,
      cones: builderFit,
      barrow: barrowFit,
      painter: painterFit,
      hammerScale: sh,
      barrowScale: sb,
      painterScale: sp,
      doneScale: sd,
      coneScale: sc,
      hammerLeft: hammerLeft,
      barrowLeft: laneStart,
      barrowRun: run,
      zoneEnd: zoneEnd,
      plannersWidth: plannersWidth,
      tapeHeight: th,
      tapeFont: tapeFont,
      tapeTop: tapeTop,
      // About 30 px a second, there and back, with a pause at each end.
      walkSeconds: (2 * run / 30 / 0.92).clamp(4.0, 40.0),
    );
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

  /// At most this many sites at once.
  static const int maxSites = 3;

  // The design boxes of the characters, in CSS pixels at scale 1. They are
  // the sizes in `ConstructionAssets`: a new picture of a character has the
  // same aspect ratio. The builder's box has room for the hammer's swing:
  // at the strike the hammer reaches about 92 px from the body's left edge.
  static const double _hammerWidth = 95;
  static const double _hammerHeight = 123;
  static const double _plannerWidth = 74;
  static const double _plannerHeight = 123;
  static const double _barrowWidth = 121;
  static const double _painterWidth = 114;
  static const double _painterHeight = 189;
  static const double _coneWidth = 65;
  static const double _coneHeight = 81;
  static const double _doneHeight = 146;

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

  /// The CSS scale of each part: its drawn size times this.
  final double hammerScale;
  final double barrowScale;
  final double painterScale;
  final double doneScale;
  final double coneScale;

  /// Left edge of the builder.
  final double hammerLeft;

  /// Left edge of the wheelbarrow's lane, and how far it walks.
  final double barrowLeft;
  final double barrowRun;

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

  /// The classes of the site's element: which parts show.
  List<String> get classes => [
    if (!hasWorkers) 'ppc-bare',
    if (planners == 2) 'ppc-plan2',
    if (hammer) 'ppc-hammer-on',
    if (cones) 'ppc-cones',
    if (barrow) 'ppc-barrow-on',
    if (painter) 'ppc-painter-on',
  ];

  static String _n(double v) {
    final s = v.toStringAsFixed(3);
    return s.contains('.')
        ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : s;
  }

  double get _plannerBoxWidth => _plannerWidth * hammerScale;

  /// The inline `style` text of the site's element, without its position.
  ///
  /// `--sh` scales the builder and the planners, `--sw` is the site's width
  /// (the measure line sweeps that far), `--hin` and `--bin` how far the
  /// builder and the wheelbarrow walk in, `--pout` how far the planners
  /// walk out, `--pa` and `--pb` where the two planners stand (from the
  /// right edge), `--cl2` the left edge of the far cone, `--ppw` and
  /// `--prun` the painter's width and how far it rolls, `--dl` the left
  /// edge of the "done" worker.
  String get variables =>
      '--sh:${_n(hammerScale)};--sb:${_n(barrowScale)};'
      '--sp:${_n(painterScale)};--sd:${_n(doneScale)};'
      '--sc:${_n(coneScale)};--hl:${_n(hammerLeft)}px;'
      '--bl:${_n(barrowLeft)}px;--run:${_n(barrowRun)}px;'
      '--th:${_n(tapeHeight)}px;'
      '--tf:${_n(tapeFont)}px;--tt:${_n(tapeTop)}px;--wd:${_n(walkSeconds)}s;'
      '--fa:${_n(fallDegrees)}deg;--sw:${_n(width)}px;'
      '--hin:${_n(hammerLeft + _hammerWidth * hammerScale)}px;'
      '--bin:${_n(barrowLeft + _barrowWidth * barrowScale)}px;'
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

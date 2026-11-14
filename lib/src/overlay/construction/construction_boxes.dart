import 'dart:math' as math;

import 'construction_crew.dart';

/// One box of a widget's blueprint: where a child render box sits, in CSS
/// pixels from the top left of the widget.
///
/// Plain numbers only (no `dart:ui`), like the layout, so the markup and
/// the preview can use it anywhere.
class ConstructionBox {
  const ConstructionBox(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get area => width * height;

  @override
  bool operator ==(Object other) =>
      other is ConstructionBox &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'ConstructionBox($left, $top, $width, $height)';
}

/// The clock of one construction site, in seconds from the moment it goes
/// up. The CSS carries the same numbers as animation delays: the stage never
/// starts a phase from Dart.
abstract final class ConstructionTimeline {
  /// Planning: only the planners, the blueprint drawn as if measured.
  static const double planSeconds = 2.5;

  /// The builder and the wheelbarrow walk in from the left.
  static const double walkInSeconds = 1.1;

  /// The builder's first swing. After this the hammer hits every
  /// [hammerPeriod] seconds, [hitOffset] seconds into each swing.
  static const double hammerStart = planSeconds + walkInSeconds;
  static const double hammerPeriod = 0.6;
  static const double hitOffset = 0.15;

  /// A repair slides for this long before the hit, then jolts.
  static const double fixLead = 0.33;

  /// The slow loop of a long build: one slip every few seconds.
  static const double loopSeconds = 12;
  static const int maxSlippers = 6;

  /// The wheelbarrow worker is at the start of his lane, and the stacker's
  /// first trip begins.
  static const double barrowStart = planSeconds + 1.6;

  /// A box is repaired every two hits, or every hit when there are many.
  static double repairStep(int boxes) =>
      boxes <= 10 ? 2 * hammerPeriod : hammerPeriod;

  /// When the box [index] of [count] is hit and repaired.
  static double hitOf(int index, int count) =>
      hammerStart + hitOffset + repairStep(count) * (index + 1);
}

/// What one box does in the lifecycle.
class ConstructionBoxPlan {
  const ConstructionBoxPlan({
    required this.box,
    required this.dx,
    required this.dy,
    required this.degrees,
    required this.drawDelay,
    required this.breakDelay,
    required this.repairDelay,
    required this.slipDelay,
    required this.dimX,
    required this.dimY,
    this.stacker = false,
    this.stackerSlip,
  });

  final ConstructionBox box;

  /// How far, and how much turned, the box is when it is broken.
  final double dx;
  final double dy;
  final double degrees;

  /// Seconds until the outline is drawn (planning).
  final double drawDelay;

  /// Seconds until it breaks (building starts).
  final double breakDelay;

  /// Seconds until its repair starts; the hit is [ConstructionTimeline.fixLead]
  /// later.
  final double repairDelay;

  /// Seconds until its first slip in the slow loop, or null when it never
  /// slips.
  final double? slipDelay;

  /// Whether it has dimension ticks along its top and its left side.
  final bool dimX;
  final bool dimY;

  /// Whether the stacker repairs it (a box in the upper half); else the
  /// builder does.
  final bool stacker;

  /// For a box of the stacker that slips in the slow loop: the number of
  /// its slip (see [ConstructionCrew.loop]); else null.
  final int? stackerSlip;
}

/// The boxes of a site: the generic ones, and the plan of the lifecycle.
abstract final class ConstructionBoxes {
  /// The fewest pixels a box side needs to be drawn.
  static const double minSide = 4;

  /// The most boxes a blueprint has.
  static const int maxBoxes = 40;

  /// Dimension ticks go on the biggest boxes only.
  static const int maxDims = 10;

  static const int _modulus = 2147483647;

  /// A number from the note [id], the same on every platform and run.
  static int seedOf(String id) {
    var h = 7;
    for (final unit in id.codeUnits) {
      h = (h * 131 + unit) % _modulus;
    }
    return h == 0 ? 1 : h;
  }

  /// The first numbers of box [index]'s stream. Park-Miller: products stay
  /// under 2^53, so the numbers are the same in the browser and the VM.
  static List<double> _stream(int seed, int index, int count) {
    var state = (seed + (index + 1) * 104729) % _modulus;
    if (state == 0) state = 1;
    final out = <double>[];
    for (var i = 0; i < count + 3; i++) {
      state = (state * 48271) % _modulus;
      if (i >= 3) out.add(state / _modulus);
    }
    return out;
  }

  /// A few degrees, 1.5 to 5.5, but less on a long box: its ends must not
  /// swing more than about 9 px.
  static double _turn(double u, ConstructionBox box) {
    final longest = math.max(box.width, box.height);
    final cap = math.min(
      5.5,
      math.asin(math.min(1.0, 18 / math.max(longest, 1))) * 180 / math.pi,
    );
    final low = math.min(1.5, cap);
    return low + u * (cap - low);
  }

  static double _round(double v) => (v * 100).roundToDouble() / 100;

  /// Whether the centre of [box] is in the upper half of a widget
  /// [widgetHeight] tall: the stacker's boxes. The others are the builder's.
  static bool isHigh(ConstructionBox box, double widgetHeight) =>
      box.top + box.height / 2 < widgetHeight / 2;

  /// A few plain boxes from a widget's size, for when none can be read: an
  /// inner frame, a leading square and two lines of text.
  static List<ConstructionBox> generic(double width, double height) {
    if (width < 2 * minSide || height < 2 * minSide) return const [];
    final pad = math.min(8.0, math.min(0.06 * width, 0.12 * height));
    final boxes = <ConstructionBox>[
      ConstructionBox(pad, pad, width - 2 * pad, height - 2 * pad),
    ];
    final side = (0.5 * height).clamp(minSide, 48.0);
    final x = 2 * pad + side + pad;
    final textWidth = width - x - 2 * pad;
    if (height >= 28 && textWidth >= 24) {
      boxes
        ..add(ConstructionBox(2 * pad, (height - side) / 2, side, side))
        ..add(
          ConstructionBox(
            x,
            height * 0.3,
            textWidth,
            math.max(minSide, height * 0.13),
          ),
        )
        ..add(
          ConstructionBox(
            x,
            height * 0.3 + height * 0.22,
            textWidth * 0.6,
            math.max(minSide, height * 0.13),
          ),
        );
    } else if (width >= 60) {
      boxes.add(
        ConstructionBox(2 * pad, height * 0.3, width * 0.5, height * 0.4),
      );
    }
    return [
      for (final b in boxes)
        if (b.width >= minSide && b.height >= minSide) b,
    ];
  }

  /// What each of [boxes] does, from the note's [seed].
  ///
  /// A broken box is shifted by a few pixels up to about 12% of its size,
  /// and turned by a few degrees; the numbers depend only on the seed and
  /// the box's index. The delays follow [ConstructionTimeline].
  ///
  /// With a [crew] (a site with the stacker) the boxes in the upper half are
  /// repaired by him, at the times of his trips; the builder repairs the
  /// others, one after the other as before. The slow loop begins when both
  /// are done.
  static List<ConstructionBoxPlan> plan(
    int seed,
    List<ConstructionBox> boxes, {
    ConstructionCrew? crew,
  }) {
    final count = boxes.length;
    // The biggest boxes get dimension ticks.
    final order = [for (var i = 0; i < count; i++) i]
      ..sort((a, b) {
        final byArea = boxes[b].area.compareTo(boxes[a].area);
        return byArea != 0 ? byArea : a.compareTo(b);
      });
    final dims = order.take(maxDims).toSet();

    // The builder's boxes, in order: the ones the stacker does not take.
    final stackerBoxes = crew?.boxes.toSet() ?? const <int>{};
    final builderBoxes = [
      for (var i = 0; i < count; i++)
        if (!stackerBoxes.contains(i)) i,
    ];
    final builderCount = builderBoxes.length;
    final builderRank = {
      for (var k = 0; k < builderCount; k++) builderBoxes[k]: k,
    };

    final slippers = <int, int>{};
    final slipCount = math.min(
      crew == null
          ? ConstructionTimeline.maxSlippers
          : ConstructionTimeline.maxSlippers - ConstructionCrew.maxLoopBoxes,
      builderCount,
    );
    for (var k = 0; k < slipCount; k++) {
      slippers[builderBoxes[(k * builderCount) ~/ slipCount]] = k;
    }
    final repairEnd = math.max(
      builderCount == 0
          ? 0.0
          : ConstructionTimeline.hitOf(builderCount - 1, builderCount),
      crew?.buildEnd ?? 0.0,
    );

    return [
      for (var i = 0; i < count; i++)
        () {
          final box = boxes[i];
          final r = _stream(seed, i, 7);
          double shift(double u, double sign, double size) =>
              sign * (3 + u * math.max(0.0, 0.12 * size - 3));
          final slip = slippers[i];
          final byStacker = stackerBoxes.contains(i);
          final hit = byStacker
              ? crew!.hitOf(i)
              : ConstructionTimeline.hitOf(builderRank[i]!, builderCount);
          return ConstructionBoxPlan(
            box: box,
            dx: _round(shift(r[0], r[1] < 0.5 ? -1 : 1, box.width)),
            dy: _round(shift(r[2], r[3] < 0.5 ? -1 : 1, box.height)),
            degrees: _round((r[4] < 0.5 ? -1 : 1) * _turn(r[5], box)),
            drawDelay: _round(0.2 + math.min(i * 0.05, 1.3)),
            breakDelay: _round(
              ConstructionTimeline.planSeconds + math.min(i * 0.03, 0.6),
            ),
            repairDelay: _round(hit - ConstructionTimeline.fixLead),
            slipDelay: slip == null
                ? null
                : _round(
                    repairEnd +
                        1 +
                        slip * ConstructionTimeline.loopSeconds / slipCount,
                  ),
            dimX: dims.contains(i) && box.width >= 44,
            dimY: dims.contains(i) && box.height >= 36,
            stacker: byStacker,
            stackerSlip: byStacker ? crew!.slipOf(i) : null,
          );
        }(),
    ];
  }
}

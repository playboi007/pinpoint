import 'dart:math' as math;

import 'construction_assets.dart';
import 'construction_boxes.dart';
import 'construction_layout.dart';

part 'construction_crew_css.dart';

/// One trip of the stacker, and the wheelbarrow worker's walk that feeds it.
///
/// All times are seconds in the timeline the trip belongs to (see
/// [ConstructionCrew]). A trip, from [start] (the wheelbarrow worker is at
/// the start of his lane, the stacker waits on the ground, hands out):
///
/// * The worker walks to the stacker, for [walk] seconds.
/// * He stops. At [throwAt] a block leaves the wheelbarrow; at [catchAt] it
///   is in the stacker's hands. The worker walks back.
/// * The stacker flies to the box, for [flight] seconds, and is there at
///   [arriveAt]. He places the block; the box is repaired at [hitAt].
/// * At [liftAt] he flies back down, and is on the ground at [landAt].
/// * The next trip begins at [end].
class StackerTrip {
  const StackerTrip({
    required this.box,
    required this.start,
    required this.walk,
    required this.flight,
    required this.dx,
    required this.dy,
  });

  /// The index of the box he repairs.
  final int box;
  final double start;

  /// How long the wheelbarrow worker walks to the stacker, and the stacker
  /// flies up (and down).
  final double walk;
  final double flight;

  /// Where he hovers, from the hand-off spot, in CSS pixels.
  final double dx;
  final double dy;

  /// The block is in the air from [throwAt] to [catchAt].
  double get throwAt => start + walk + 0.05;
  double get catchAt => start + walk + 0.4;

  /// The wheelbarrow worker turns and walks back.
  double get turnAt => start + walk + 0.45;
  double get arriveAt => catchAt + flight;

  /// The box snaps into place.
  double get hitAt => arriveAt + 0.25;
  double get liftAt => arriveAt + 0.5;
  double get landAt => liftAt + flight;

  /// The trip is as long as its parts need: the worker's walk there and
  /// back, and the stacker back on the ground before the next block flies.
  double get cycle => math.max(2 * walk + 0.45, landAt - start - walk + 0.05);
  double get end => start + cycle;
}

/// The extra worker of a site with the stacker, and the schedule of his work:
/// which boxes he repairs, when, and the CSS keyframes that play it.
///
/// During building the wheelbarrow worker walks in from the left to a
/// hand-off spot, stops, and hands over one light block: it flies in a short
/// arc to the stacker's hands. The stacker, with booster shoes, flies up to a
/// broken box in the upper half of the widget, places the block on it (the
/// box is repaired right then) and flies back down. The builder repairs the
/// other boxes, the low ones.
///
/// There are two timelines, both starting at 0: the building one ([trips],
/// from the first walk to [buildEnd]) and the slow loop that goes on after it
/// ([loop], [loopLength] seconds, repeated): the stacker keeps repairing
/// the one or two boxes that slip.
///
/// Everything is computed from the layout and the boxes only, so it is the
/// same for the same note on every platform and run.
class ConstructionCrew {
  ConstructionCrew._({
    required this.layout,
    required this.boxes,
    required this.trips,
    required this.loop,
    required this.walk,
  });

  /// The crew of a site laid out as [layout], for its blueprint [boxes], or
  /// null when the layout has no stacker.
  static ConstructionCrew? of(
    ConstructionLayout layout,
    List<ConstructionBox> boxes,
  ) {
    if (!layout.stacker) return null;
    final widgetHeight = layout.height - 2 * ConstructionLayout.overscan;
    final mine = [
      for (var i = 0; i < boxes.length; i++)
        if (ConstructionBoxes.isHigh(boxes[i], widgetHeight)) i,
    ];
    if (mine.isEmpty) return null;

    final walk = math.max(0.7, layout.barrowRun / 42);
    StackerTrip trip(int box, double start) {
      final hover = _hover(layout, boxes[box]);
      final dist = math.sqrt(hover.$1 * hover.$1 + hover.$2 * hover.$2);
      return StackerTrip(
        box: box,
        start: start,
        walk: walk,
        flight: (0.6 + dist / 300).clamp(0.85, 1.15),
        dx: hover.$1,
        dy: hover.$2,
      );
    }

    final trips = <StackerTrip>[];
    var at = ConstructionTimeline.barrowStart;
    for (final box in mine) {
      final t = trip(box, at);
      trips.add(t);
      at = t.end;
    }

    // The slow loop: the stacker repairs the boxes that slip, a few, evenly
    // spread among his own.
    final slipCount = math.min(maxLoopBoxes, mine.length);
    final loop = <StackerTrip>[];
    at = 0;
    for (var k = 0; k < slipCount; k++) {
      final t = trip(mine[(k * mine.length) ~/ slipCount], at);
      loop.add(t);
      at = t.end;
    }
    return ConstructionCrew._(
      layout: layout,
      boxes: mine,
      trips: trips,
      loop: loop,
      walk: walk,
    );
  }

  /// At most this many of his boxes slip in the slow loop.
  static const int maxLoopBoxes = 2;

  /// The stacker drops in from above while the planners leave.
  static const double dropStart = ConstructionTimeline.planSeconds;
  static const double dropSeconds = 0.7;

  /// A slip begins this long before the stacker is at the box.
  static const double slipLead = 0.6;

  final ConstructionLayout layout;

  /// The indexes of the boxes the stacker repairs, in order.
  final List<int> boxes;

  /// His trips while building, and in the slow loop (times from the start of
  /// the loop).
  final List<StackerTrip> trips;
  final List<StackerTrip> loop;

  /// Seconds the wheelbarrow worker needs to walk to the stacker.
  final double walk;

  /// When the last repair trip ends: the loop begins.
  double get buildEnd => trips.last.end;

  /// How long one round of the loop takes.
  double get loopLength => loop.last.end;

  /// When the box [index] (one of [boxes]) is repaired.
  double hitOf(int index) => trips.firstWhere((t) => t.box == index).hitAt;

  /// The number of the slip of box [index] in the loop, or null.
  int? slipOf(int index) {
    for (var k = 0; k < loop.length; k++) {
      if (loop[k].box == index) return k;
    }
    return null;
  }

  // ---- Geometry, in the site's pixels ----

  double get _spotTop => layout.groundY - layout.stackerBoxHeight;

  /// The lowest the top of his canvas goes: his highest content (the block
  /// over his head) stays 1 px under the tape.
  static double _minTop(ConstructionLayout layout) =>
      layout.tapeTop +
      layout.tapeHeight +
      1 -
      ConstructionAssets.stackerContentTop * layout.stackerBoxHeight;

  /// Where the stacker hovers to work on [box], as an offset from the spot:
  /// the block of his place pose is on the box's top edge, centred on the
  /// box; but his content never leaves the site or goes behind the tape.
  static (double, double) _hover(
    ConstructionLayout layout,
    ConstructionBox box,
  ) {
    const o = ConstructionLayout.overscan;
    final w = layout.stackerBoxWidth;
    final h = layout.stackerBoxHeight;
    const pad = ConstructionLayout.pad;
    final low = pad - ConstructionAssets.stackerContentLeft * w;
    final high =
        layout.width - pad - ConstructionAssets.stackerContentRight * w;
    final left =
        (box.left +
                o +
                box.width / 2 -
                ConstructionAssets.stackerPlaceBlockX * w)
            .clamp(low, math.max(low, high));
    final spotTop = layout.groundY - h;
    final top = (box.top + o - ConstructionAssets.stackerPlaceBlockBottom * h)
        .clamp(math.min(_minTop(layout), spotTop), spotTop);
    return (left - layout.stackerLeft, top - spotTop);
  }

  /// The block's size, and its place at the start and the end of its arc:
  /// the wheelbarrow's load and the stacker's hands (centres, in the site).
  double get _block => ConstructionAssets.blockSize * layout.stackerScale;

  (double, double) get _arcStart => (
    layout.barrowLeft + layout.barrowRun + 0.78 * layout.barrowBoxWidth,
    layout.groundY - 0.6 * layout.barrowBoxHeight,
  );

  (double, double) get _arcEnd => (
    layout.stackerLeft +
        ConstructionAssets.stackerHandX * layout.stackerBoxWidth,
    _spotTop + ConstructionAssets.stackerHandY * layout.stackerBoxHeight,
  );

  /// Where the stacker is [seconds] after the site went up, as an offset
  /// from the hand-off spot: the landing of the finish starts there. Eases
  /// are the smooth-step of the CSS curves, near enough for a landing.
  (double, double) offsetAt(double seconds) {
    final t = seconds < buildEnd ? seconds : (seconds - buildEnd) % loopLength;
    final moves = seconds < buildEnd
        ? _moves(trips, withDrop: true)
        : _moves(loop, withDrop: false);
    if (t <= moves.first.t) return (moves.first.x, moves.first.y);
    for (var i = 0; i + 1 < moves.length; i++) {
      final a = moves[i];
      final b = moves[i + 1];
      if (t > b.t) continue;
      final u = b.t == a.t ? 1.0 : ((t - a.t) / (b.t - a.t)).clamp(0.0, 1.0);
      final k = a.ease.at(u);
      return (a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k);
    }
    return (moves.last.x, moves.last.y);
  }

  double get _dropY => layout.groundY + 12;

  /// How high he cruises across the lane (a negative offset from the spot):
  /// over the head of the wheelbarrow worker if there is room under the
  /// tape, and higher when his box is.
  double _cruise(StackerTrip t) {
    final room = _minTop(layout) - _spotTop;
    return math.min(
      t.dy,
      math.max(-(layout.barrowBoxHeight + 8), math.min(0.0, room)),
    );
  }

  /// The stacker's flight as places in time. [_Move.ease] says how he goes
  /// from this place to the next.
  List<_Move> _moves(List<StackerTrip> list, {required bool withDrop}) {
    final out = <_Move>[];
    if (withDrop) {
      out
        ..add(_Move(0, 0, -_dropY, _Ease.none))
        ..add(_Move(dropStart, 0, -_dropY, _Ease.drop))
        ..add(_Move(dropStart + dropSeconds, 0, 0, _Ease.none));
    } else {
      out.add(_Move(0, 0, 0, _Ease.none));
    }
    // Up, then across; across, then down: he rises straight from the
    // hand-off spot and drops straight onto it.
    for (final t in list) {
      out
        ..add(_Move(t.catchAt, 0, 0, _Ease.inward))
        ..add(
          _Move(
            t.catchAt + _riseShare * t.flight,
            0,
            _cruise(t),
            _Ease.outward,
          ),
        )
        ..add(_Move(t.arriveAt, t.dx, t.dy, _Ease.none))
        ..add(_Move(t.liftAt, t.dx, t.dy, _Ease.inward))
        ..add(
          _Move(
            t.liftAt + (1 - _riseShare) * t.flight,
            0,
            _cruise(t),
            _Ease.outward,
          ),
        )
        ..add(_Move(t.landAt, 0, 0, _Ease.none));
    }
    return out;
  }

  /// The share of a flight up that is straight up.
  static const double _riseShare = 0.35;

  /// The CSS of this crew for the site whose class is `ppc-$key`: the
  /// keyframes of both timelines and the rules that play them.
  ///
  /// Each element plays the building keyframes once, then the loop keyframes
  /// forever. When the site reveals, they stop and the stacker lands.
  String css(String key, String rootId) => _crewCss(key, rootId);
}

class _Move {
  const _Move(this.t, this.x, this.y, this.ease);

  final double t;
  final double x;
  final double y;

  /// How the flight from here to the next place goes.
  final _Ease ease;
}

/// The curves of the stacker's flight: the CSS timing function, and the
/// same curve as a function for the landing (near enough for that).
enum _Ease {
  /// A hold: no curve.
  none(null),

  /// Starts slow, ends at speed.
  inward('cubic-bezier(.45,0,.9,.6)'),

  /// Starts at speed, ends slow.
  outward('cubic-bezier(.1,.4,.55,1)'),

  /// The drop-in from above.
  drop('cubic-bezier(.3,.6,.5,1)');

  const _Ease(this.css);

  final String? css;

  double at(double u) => switch (this) {
    _Ease.none => u,
    _Ease.inward => u * u,
    _Ease.outward => 1 - (1 - u) * (1 - u),
    _Ease.drop => 1 - (1 - u) * (1 - u),
  };
}

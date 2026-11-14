import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../detect/detector.dart';
import '../../detect/findings_controller.dart';
import '../../search/render_search.dart';
import '../../theme/marks.dart';
import '../../theme/pinpoint_motion.dart';
import '../../theme/pinpoint_tokens.dart';

/// "Scan this screen" as a moment: a thin accent line sweeps down the app
/// once, and each finding's marker pops in as the line passes it.
///
/// It plays once for each change of [FindingsController.sweeps], which only
/// the "Scan this screen" button counts. It runs for about 1.5 s in all: the
/// line takes 600 ms, the markers stay for a beat, then fade out. At rest it
/// runs nothing and paints nothing. With reduced motion it does not play at
/// all: the findings are in the list and outline on hover as always.
///
/// The marker of a finding is its rect outline in the stroke of its severity
/// (solid for errors, dashed for warnings, dotted for hints) and a corner
/// mark whose shape differs too (square, diamond, circle), so colour is not
/// the only signal. Both are drawn over a paper halo.
///
/// It takes no pointer events and sits in the same stack as the
/// `FindingPainter`.
class ScanSweep extends StatefulWidget {
  const ScanSweep({super.key, required this.findings, required this.origin});

  static const Key paintKey = ValueKey<String>('pinpoint.scanSweep');

  /// How long the line takes from the top to the bottom.
  static const Duration sweepBase = Duration(milliseconds: 600);

  /// How long the markers stay after the line has passed.
  static const Duration holdBase = Duration(milliseconds: 700);

  /// How long a marker takes to pop in.
  static const Duration popBase = Duration(milliseconds: 200);

  /// The most markers one sweep draws.
  static const int maxMarks = 60;

  final FindingsController findings;

  /// The layer's global position, to turn global rects into local ones.
  final Offset Function() origin;

  @override
  State<ScanSweep> createState() => _ScanSweepState();
}

/// What the sweep draws for one finding.
class _Mark {
  const _Mark(this.rect, this.severity);

  /// In global logical pixels.
  final Rect rect;
  final Severity severity;
}

class _ScanSweepState extends State<ScanSweep>
    with SingleTickerProviderStateMixin {
  /// 0 at the start of a sweep, 1 when the markers are gone. Runs only
  /// while a sweep plays.
  late final AnimationController _run = AnimationController(vsync: this);

  /// What the sweep in progress draws, taken when it started.
  List<_Mark> _marks = const <_Mark>[];

  /// The timeline of the sweep in progress: line, hold, fade.
  _Timeline _timeline = _Timeline.of(const PinPointMotion());

  int _seen = 0;

  @override
  void initState() {
    super.initState();
    _seen = widget.findings.sweeps.value;
    widget.findings.sweeps.addListener(_asked);
  }

  @override
  void didUpdateWidget(ScanSweep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.findings, widget.findings)) {
      oldWidget.findings.sweeps.removeListener(_asked);
      _seen = widget.findings.sweeps.value;
      widget.findings.sweeps.addListener(_asked);
    }
  }

  @override
  void dispose() {
    widget.findings.sweeps.removeListener(_asked);
    _run.dispose();
    super.dispose();
  }

  void _asked() {
    if (!mounted || widget.findings.sweeps.value == _seen) return;
    _seen = widget.findings.sweeps.value;
    final motion = PinPointMotion.of(context);
    // No decorative motion: the end state is "nothing drawn".
    if (motion.reduced) {
      _run.value = 0;
      return;
    }
    _timeline = _Timeline.of(motion);
    _marks = [
      for (final finding in widget.findings.findings.take(ScanSweep.maxMarks))
        if (_rectOf(finding) case final Rect rect)
          _Mark(rect, finding.severity),
    ];
    _run
      ..duration = _timeline.total
      ..forward(from: 0);
  }

  /// Where [finding] is now: read again from its render object when the
  /// widget is still there, so the marker follows a scroll since the scan.
  static Rect? _rectOf(Finding finding) {
    final element = finding.element;
    if (element != null && element.mounted) {
      final renderObject = element.renderObject;
      if (renderObject != null) {
        final live = RenderSearch.globalRectOf(renderObject);
        if (live != null) return live;
      }
    }
    return finding.rect;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        key: ScanSweep.paintKey,
        size: Size.infinite,
        painter: _SweepPainter(
          run: _run,
          marks: () => _marks,
          timeline: () => _timeline,
          origin: widget.origin,
          tokens: PinPointTokens.of(context),
        ),
      ),
    );
  }
}

/// The shape of one sweep in time, as fractions of its whole run.
class _Timeline {
  const _Timeline({
    required this.total,
    required this.sweepEnd,
    required this.fadeStart,
    required this.popFraction,
  });

  factory _Timeline.of(PinPointMotion motion) {
    final sweep = ScanSweep.sweepBase;
    final hold = ScanSweep.holdBase;
    final fade = PinPointMotion.moderateBase;
    final whole = sweep + hold + fade;
    return _Timeline(
      total: motion.scaled(whole),
      sweepEnd: sweep.inMicroseconds / whole.inMicroseconds,
      fadeStart: (sweep + hold).inMicroseconds / whole.inMicroseconds,
      popFraction: ScanSweep.popBase.inMicroseconds / whole.inMicroseconds,
    );
  }

  final Duration total;

  /// Where the line reaches the bottom.
  final double sweepEnd;

  /// Where the markers start to fade out.
  final double fadeStart;

  /// How much of the run one pop takes.
  final double popFraction;
}

class _SweepPainter extends CustomPainter {
  _SweepPainter({
    required this.run,
    required this.marks,
    required this.timeline,
    required this.origin,
    required this.tokens,
  }) : super(repaint: run);

  final AnimationController run;
  final List<_Mark> Function() marks;
  final _Timeline Function() timeline;
  final Offset Function() origin;
  final PinPointTokens tokens;

  static const Curve _line = PinPointMotion.move;

  /// The run fraction at which the line is at [fraction] of the height.
  /// The curve only rises, so a bisection finds it.
  static double _timeOf(double fraction, double sweepEnd) {
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 16; i++) {
      final mid = (lo + hi) / 2;
      if (_line.transform(mid) < fraction) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return hi * sweepEnd;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final v = run.value;
    // At rest (before a sweep, or when it is over) there is nothing.
    if (v <= 0 || v >= 1 || run.status == AnimationStatus.dismissed) return;
    final time = timeline();
    final shift = -origin();
    final fade = v <= time.fadeStart
        ? 1.0
        : 1 - (v - time.fadeStart) / (1 - time.fadeStart);

    for (final mark in marks()) {
      final local = mark.rect.shift(shift);
      final top = (local.top / math.max(1.0, size.height)).clamp(0.0, 1.0);
      final popStart = _timeOf(top, time.sweepEnd);
      final pop = ((v - popStart) / time.popFraction).clamp(0.0, 1.0);
      if (pop <= 0) continue;
      _paintMark(canvas, local, mark.severity, pop, fade);
    }

    if (v < time.sweepEnd) {
      final y = _line.transform(v / time.sweepEnd) * size.height;
      strokeHalo(
        canvas,
        Path()
          ..moveTo(0, y)
          ..lineTo(size.width, y),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = tokens.accent,
        tokens,
      );
    }
  }

  void _paintMark(
    Canvas canvas,
    Rect rect,
    Severity severity,
    double pop,
    double fade,
  ) {
    final (Color base, List<double>? dash) = switch (severity) {
      Severity.error => (tokens.err, null),
      Severity.warning => (tokens.warn, const <double>[6, 3]),
      Severity.info => (tokens.info, const <double>[1.5, 2.5]),
    };
    final opacity = pop.clamp(0.0, 1.0) * fade;
    final color = base.withValues(alpha: base.a * opacity);
    final scale = PinPointMotion.spring.transform(pop);

    // The outline, in the stroke of its severity.
    final haloTokens = tokens.copyWith(
      paper: tokens.paper.withValues(alpha: tokens.paper.a * opacity),
    );
    strokeHalo(
      canvas,
      Path()..addRect(rect.deflate(1)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
      haloTokens,
      dash: dash,
    );

    // The corner mark pops with a spring: it grows from its centre.
    const size = 14.0;
    final center = rect.topLeft + const Offset(size / 2 + 2, size / 2 + 2);
    final half = size / 2 * scale;
    final path = switch (severity) {
      Severity.error =>
        (Path()..addRect(Rect.fromCircle(center: center, radius: half))),
      Severity.warning =>
        Path()
          ..moveTo(center.dx, center.dy - half * 1.15)
          ..lineTo(center.dx + half * 1.15, center.dy)
          ..lineTo(center.dx, center.dy + half * 1.15)
          ..lineTo(center.dx - half * 1.15, center.dy)
          ..close(),
      Severity.info =>
        Path()..addOval(Rect.fromCircle(center: center, radius: half)),
    };
    canvas
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeJoin = StrokeJoin.miter
          ..color = haloTokens.paper,
      )
      ..drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SweepPainter old) =>
      !identical(old.run, run) || old.tokens != tokens || old.origin != origin;
}

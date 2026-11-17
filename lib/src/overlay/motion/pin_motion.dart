import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/pinpoint_motion.dart';

/// The seldom-used moments of a pin: a note the agent fixed, a verify
/// result that arrived, a note the user accepted.
///
/// Each one plays once, on a change of state while the pin is on screen,
/// and never at rest: every frame of an animation is a trace event in the
/// flight recorder. With reduced motion none of them plays.
abstract final class PinMoments {
  /// How high the pin hops when the agent fixed its note, in logical pixels.
  static const double hopHeight = 5;

  /// The pin hops up in the first part of the moment, and lands with a small
  /// bounce in the rest. 0 at rest.
  static double hop(double t) {
    if (t <= 0 || t >= 1) return 0;
    const split = 0.35;
    if (t < split) {
      return -hopHeight * Curves.easeOutCubic.transform(t / split);
    }
    final down = PinPointMotion.spring.transform((t - split) / (1 - split));
    return -hopHeight * (1 - down);
  }

  /// How much of the tick is drawn, 0 to 1, at [t] of the fixed moment. It
  /// starts a little after the hop does.
  static double tick(double t) =>
      const Interval(0.2, 0.8, curve: Curves.easeOut).transform(t);

  /// The stamp starts this many times its size...
  static const double stampScale = 1.8;

  /// ...and this far turned, in radians.
  static const double stampTurn = -0.35;

  static const Interval _drop = Interval(0, 0.7, curve: PinPointMotion.spring);

  /// The stamp's size: [stampScale] at the start, 1 at rest, with a small
  /// bounce below 1 on the way.
  static double stampSize(double t) =>
      stampScale + (1 - stampScale) * _drop.transform(t);

  /// The stamp's turn: [stampTurn] at the start, 0 at rest.
  static double stampAngle(double t) => stampTurn * (1 - _drop.transform(t));

  /// The stamp shows at once, a little after it starts.
  static double stampOpacity(double t) => const Interval(0, 0.15).transform(t);

  /// How far the dust ring has grown, 0 to 1. The ring starts when the
  /// stamp lands.
  static double dust(double t) =>
      const Interval(0.35, 1, curve: Curves.easeOut).transform(t);

  /// How long the fold of an accepted pin takes.
  static const Duration foldBase = Duration(milliseconds: 300);
}

/// A check mark of the Material `check` glyph at 11 px, drawn up to
/// [progress] of its length: the short stroke first, then the long one.
class TickPainter extends CustomPainter {
  const TickPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  /// The centre line of the glyph, in an 11 px box.
  static Path path(Size size) {
    final s = size.width / 11;
    return Path()
      ..moveTo(1.9 * s, 5.8 * s)
      ..lineTo(4.1 * s, 8.1 * s)
      ..lineTo(9.1 * s, 3.1 * s);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final metric = path(size).computeMetrics().first;
    final drawn = metric.extractPath(
      0,
      metric.length * progress.clamp(0.0, 1.0),
    );
    canvas.drawPath(
      drawn,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.square
        ..strokeJoin = StrokeJoin.miter
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(TickPainter old) =>
      old.progress != progress || old.color != color;
}

/// A thin ring that grows out of the stamp and fades: the dust of the paper
/// where the stamp landed. Round for a pass, square for a fail. No blur.
class DustRingPainter extends CustomPainter {
  const DustRingPainter({
    required this.progress,
    required this.round,
    required this.color,
  });

  /// 0 (not started) to 1 (gone).
  final double progress;
  final bool round;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final grown = (Offset.zero & size).inflate(
      math.max(size.width, size.height) * 0.45 * progress,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: color.a * (1 - progress));
    if (round) {
      canvas.drawOval(grown, paint);
    } else {
      canvas.drawRect(grown, paint);
    }
  }

  @override
  bool shouldRepaint(DustRingPainter old) =>
      old.progress != progress || old.round != round || old.color != color;
}

/// Folds [child] away like a sheet of paper: it shrinks to its bottom edge
/// and leans over. Plays once from the first frame, then calls [onDone].
///
/// With reduced motion it is gone at once: [onDone] is called after the
/// first frame and the child is never drawn.
class PinFold extends StatefulWidget {
  const PinFold({super.key, required this.child, required this.onDone});

  final Widget child;
  final VoidCallback onDone;

  @override
  State<PinFold> createState() => _PinFoldState();
}

class _PinFoldState extends State<PinFold> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  bool _started = false;
  bool _skipped = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = PinPointMotion.of(context).scaled(PinMoments.foldBase);
    _controller.duration = duration;
    if (_started) return;
    _started = true;
    if (duration == Duration.zero) {
      _skipped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onDone();
      });
      return;
    }
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) widget.onDone();
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_skipped) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = PinPointMotion.exit.transform(_controller.value);
        final matrix = Matrix4.identity()
          ..setEntry(0, 1, -0.45 * t)
          ..scaleByDouble(1.0, 1 - t, 1.0, 1.0);
        return Opacity(
          opacity: 1 - 0.5 * t,
          child: Transform(
            alignment: Alignment.bottomCenter,
            transform: matrix,
            child: child,
          ),
        );
      },
    );
  }
}

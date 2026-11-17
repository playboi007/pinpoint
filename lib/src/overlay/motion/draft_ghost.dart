import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../theme/pinpoint_motion.dart';
import '../../theme/pinpoint_tokens.dart';
import '../pin_marker.dart';
import 'flights.dart';

/// The card that flies into its pin when a comment is saved as a draft.
///
/// A ghost of the info panel (paper, ink border, hard shadow, a few ruled
/// lines) shrinks and moves to the corner of the widget where the pin
/// appears, in about 400 ms, and is gone. The draft and its pin are made
/// at once; this only shows where they went.
///
/// With reduced motion it does not show at all.
class DraftGhost extends StatefulWidget {
  const DraftGhost({super.key, required this.run, required this.onDone});

  /// The flight at full speed.
  static const Duration flightBase = Duration(milliseconds: 400);

  final DraftRun run;

  /// Called once, when the card is gone.
  final VoidCallback onDone;

  /// The pin's box for a pin whose widget has its corner at [corner], inside
  /// a layer [size] big. The same place [PinLayer] puts it.
  static Rect pinRect(Offset corner, Size size) {
    double clamp(double value, double max) =>
        max <= 0 ? 0 : value.clamp(0, max).toDouble();
    const s = PinMarker.size;
    return Rect.fromLTWH(
      clamp(corner.dx - s / 2, size.width - s),
      clamp(corner.dy - s / 2, size.height - s),
      s,
      s,
    );
  }

  @override
  State<DraftGhost> createState() => _DraftGhostState();
}

class _DraftGhostState extends State<DraftGhost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flight = AnimationController(vsync: this);
  bool _started = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _flight.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = PinPointMotion.of(context);
    _flight.duration = motion.scaled(DraftGhost.flightBase);
    if (_started) return;
    _started = true;
    if (motion.reduced) {
      _finish();
    } else {
      _flight.forward();
    }
  }

  void _finish() {
    if (_done) return;
    _done = true;
    // Not now: this can run while the tree builds.
    scheduleMicrotask(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _flight.duration = PinPointMotion.of(context).scaled(DraftGhost.flightBase);
    if (_done) return const SizedBox.shrink();
    final tokens = PinPointTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final to = DraftGhost.pinRect(widget.run.pin, constraints.biggest);
        return AnimatedBuilder(
          animation: _flight,
          builder: (context, _) {
            final t = PinPointMotion.move.transform(_flight.value);
            final rect = Rect.lerp(widget.run.from, to, t)!;
            return Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: CustomPaint(
                    painter: _Card(
                      progress: t,
                      paper: tokens.paper,
                      ink: tokens.ink,
                      rule: tokens.rule,
                      accent: tokens.accent,
                      shadow: tokens.shadow,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// A panel, drawn to whatever size it has: a header band, ruled lines and
/// a block for the buttons. The strokes keep their width as it shrinks.
class _Card extends CustomPainter {
  _Card({
    required this.progress,
    required this.paper,
    required this.ink,
    required this.rule,
    required this.accent,
    required this.shadow,
  });

  final double progress;
  final Color paper, ink, rule, accent, shadow;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final box = Offset.zero & size;
    // The hard offset shadow gets smaller with the card.
    final lift = 3 * (1 - progress);
    if (lift > 0.1) {
      canvas.drawRect(box.shift(Offset(lift, lift)), Paint()..color = shadow);
    }
    canvas.drawRect(box, Paint()..color = paper);
    final line = Paint()
      ..color = rule
      ..strokeWidth = 1;
    final header = size.height * 0.12;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, header),
      Paint()..color = accent.withValues(alpha: accent.a * (1 - progress)),
    );
    for (var i = 0; i < 4; i++) {
      final y = header + (size.height * 0.62) * (i + 1) / 5;
      canvas.drawLine(
        Offset(size.width * 0.08, y),
        Offset(size.width * (i.isEven ? 0.92 : 0.7), y),
        line,
      );
    }
    final button = Rect.fromLTWH(
      size.width * 0.66,
      size.height * 0.86,
      size.width * 0.26,
      size.height * 0.08,
    );
    canvas.drawRect(button, Paint()..color = ink);
    canvas.drawRect(
      box.deflate(0.5),
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_Card old) => old.progress != progress;
}

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../agent/stress_matrix.dart';
import '../../theme/pinpoint_motion.dart';
import '../../theme/pinpoint_tokens.dart';

/// A progress strip with one tick for each run of the stress matrix that
/// runs now. It sits at the foot of the rail's agent item.
///
/// It shows only while a matrix runs and is gone after: [progress] is null
/// when none runs. A tick is filled when its run has ended, outlined when it
/// has not, and the run in progress has a bar under it, so the fill is not
/// the only signal. The tooltip of the item says "run k of n" in words.
///
/// It fades in once when a matrix starts and never moves after: the ticks
/// change when a run ends, which is a value, not a tween. That is why it
/// also shows with reduced motion.
class StressStrip extends StatelessWidget {
  const StressStrip({super.key, this.progress});

  static const Key stripKey = ValueKey<String>('pinpoint.stress.strip');

  /// Null reads [StressProgress.running].
  final ValueListenable<StressStatus?>? progress;

  /// The words for [status]: `Stress matrix: run 3 of 9`.
  static String describe(StressStatus status) {
    final run = status.done < status.total ? status.done + 1 : status.total;
    return 'Stress matrix: run $run of ${status.total}';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<StressStatus?>(
      valueListenable: progress ?? StressProgress.running,
      builder: (context, status, _) {
        if (status == null || status.total <= 0) return const SizedBox.shrink();
        return _FadeIn(
          key: stripKey,
          child: SizedBox(
            height: 6,
            width: double.infinity,
            child: CustomPaint(
              painter: _StripPainter(status, PinPointTokens.of(context)),
            ),
          ),
        );
      },
    );
  }
}

/// Fades its child in once when it mounts. The controller stops at the end.
class _FadeIn extends StatefulWidget {
  const _FadeIn({super.key, required this.child});

  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fade.duration = PinPointMotion.of(context).quick;
    if (!_started) {
      _started = true;
      // Zero with reduced motion: it ends at once.
      _fade.forward();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _fade, child: widget.child);
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.status, this.tokens);

  final StressStatus status;
  final PinPointTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final total = status.total;
    // Ticks are 1 px apart. With more runs than fit at 2 px each, they run
    // together into a bar, which still fills from the left.
    const gap = 1.0;
    final width = (size.width - gap * (total - 1)) / total;
    final tick = width < 2 ? size.width / total : width;
    final gapped = width >= 2;
    final h = size.height - 2;
    final fill = Paint()..color = tokens.accent;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = tokens.ink;
    for (var i = 0; i < total; i++) {
      final left = gapped ? i * (tick + gap) : i * tick;
      final rect = Rect.fromLTWH(left, 0, tick, h);
      if (i < status.done) {
        canvas.drawRect(rect, fill);
      } else if (gapped) {
        canvas.drawRect(rect.deflate(0.5), line);
      }
      if (i == status.done && i < total) {
        // The run in progress: a bar under its tick.
        canvas.drawRect(
          Rect.fromLTWH(left, size.height - 2, tick, 2),
          Paint()..color = tokens.ink,
        );
      }
    }
    if (!gapped) {
      // Run together: one outline for the whole bar, so the empty part
      // reads as empty.
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, h).deflate(0.5), line);
      canvas.drawRect(Rect.fromLTWH(0, 0, tick * status.done, h), fill);
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.status != status || old.tokens != tokens;
}

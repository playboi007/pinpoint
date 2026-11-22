part of 'controls.dart';

/// One line of text that, when it does not fit, drops characters from the
/// start and shows `…` first, so the end stays visible:
/// `…/presentation/dashboard_panels.dart:652`. It prefers to cut at a `/`.
/// The default style is the value style.
class StartEllipsisText extends StatelessWidget {
  const StartEllipsisText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final effective = style ?? PinPointTokens.of(context).value;
    final resolved = DefaultTextStyle.of(context).style.merge(effective);
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final scaler = MediaQuery.textScalerOf(context);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final shown = _fit(
            text,
            resolved,
            direction,
            scaler,
            constraints.maxWidth,
          );
          return Text(
            shown,
            style: effective,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
          );
        },
      ),
    );
  }

  /// [text], or `…` and its tail, whichever fits [maxWidth].
  static String _fit(
    String text,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
    double maxWidth,
  ) {
    if (!maxWidth.isFinite) return text;
    bool fits(String candidate) {
      final painter = TextPainter(
        text: TextSpan(text: candidate, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width <= maxWidth;
    }

    if (fits(text)) return text;
    // The fewest characters to drop. Dropping all of them (just `…`) is the
    // floor: nothing shorter exists.
    var low = 1;
    var high = text.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (fits('…${text.substring(mid)}')) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    final drop = low;
    // Start the tail at the next `/`, when there is one, so no folder name is
    // cut in half.
    final slash = text.indexOf('/', drop);
    if (slash != -1 && slash < text.length - 1) {
      return '…${text.substring(slash)}';
    }
    return '…${text.substring(drop)}';
  }
}

/// A 14 px ring spinner: a `rule` ring with an `ink` arc turning on it. Only
/// a mounted spinner draws frames, so show it only while something loads.
class DraftSpinner extends StatefulWidget {
  const DraftSpinner({super.key});

  @override
  State<DraftSpinner> createState() => _DraftSpinnerState();
}

class _DraftSpinnerState extends State<DraftSpinner>
    with SingleTickerProviderStateMixin {
  /// One turn. It tells that something loads, so it turns with reduced
  /// motion too; only the slow motion is corrected.
  static const Duration turn = Duration(milliseconds: 800);

  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: turn,
  )..repeat();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final period = PinPointMotion.of(context).informative(turn);
    if (_turn.duration != period) {
      _turn
        ..duration = period
        ..repeat();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return Semantics(
      label: 'Loading',
      child: SizedBox.square(
        dimension: 14,
        child: CustomPaint(
          painter: _SpinnerPainter(
            turn: _turn,
            ring: tokens.rule,
            arc: tokens.ink,
          ),
        ),
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.turn, required this.ring, required this.arc})
    : super(repaint: turn);

  final Animation<double> turn;
  final Color ring;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    const width = 2.0;
    final oval = (Offset.zero & size).deflate(width / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = ring;
    canvas.drawOval(oval, paint);
    paint.color = arc;
    // A quarter of the ring, centred on the top, then turned.
    const quarter = 3.141592653589793 / 2;
    canvas.drawArc(
      oval,
      -quarter * 1.5 + turn.value * 2 * 3.141592653589793,
      quarter,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.ring != ring || old.arc != arc;
}

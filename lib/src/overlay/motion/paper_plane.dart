import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/pinpoint_motion.dart';
import '../../theme/pinpoint_tokens.dart';
import 'flights.dart';

/// The paper plane of a send.
///
/// On Send, a small plane flies from the left of the button to the right
/// and off, with a dashed trail, in about 350 ms. It starts with the send
/// and never holds it back. Then a "Sent" stamp stays on the button's place
/// for a moment: the panel is already gone when the send worked, so the
/// stamp is drawn here, not on the real button. When the send fails, the
/// plane drops and fades instead, and no stamp shows.
///
/// With reduced motion nothing moves: no plane, and the stamp shows at once
/// and goes at once, after the same pause.
///
/// No animation loops, and none runs while the stamp rests: the pause is a
/// timer, not frames.
class SendGhost extends StatefulWidget {
  const SendGhost({
    super.key,
    required this.run,
    required this.onDone,
    this.flight = flightBase,
    this.dwell = dwellTime,
  });

  /// The plane's flight at full speed.
  static const Duration flightBase = Duration(milliseconds: 350);

  /// How long the stamp rests.
  static const Duration dwellTime = Duration(milliseconds: 900);

  final SendRun run;

  /// Called once, when nothing is left to draw.
  final VoidCallback onDone;

  final Duration flight;
  final Duration dwell;

  @override
  State<SendGhost> createState() => _SendGhostState();
}

enum _Phase { flying, dropping, stamp, done }

class _SendGhostState extends State<SendGhost> with TickerProviderStateMixin {
  late final AnimationController _fly = AnimationController(vsync: this);
  late final AnimationController _drop = AnimationController(vsync: this);
  late final AnimationController _land = AnimationController(vsync: this);
  late final AnimationController _fade = AnimationController(vsync: this);
  Timer? _rest;
  PinPointMotion _motion = const PinPointMotion();
  bool _started = false;
  bool _flown = false;
  _Phase _phase = _Phase.flying;

  /// How far along the flight the plane was when it began to fall.
  double _dropFrom = _Plane.last;

  @override
  void initState() {
    super.initState();
    widget.run.addListener(_onOutcome);
    _fly.addStatusListener((status) {
      if (status == AnimationStatus.completed) _landed();
    });
    _drop.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
    _fade.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Timed in build as well as here: the slow motion can change while it
    // plays.
    _time(PinPointMotion.of(context));
    if (_started) return;
    _started = true;
    if (_motion.reduced) {
      _landed();
    } else {
      _fly.forward();
      // A send can end before the first frame, for example with no sink.
      _onOutcome();
    }
  }

  void _time(PinPointMotion motion) {
    _motion = motion;
    _fly.duration = motion.scaled(widget.flight);
    _drop.duration = motion.scaled(const Duration(milliseconds: 280));
    _land.duration = motion.quick;
    _fade.duration = motion.quick;
  }

  /// The flight is over: the plane is off to the right.
  void _landed() {
    _flown = true;
    if (_phase == _Phase.flying) _onOutcome();
  }

  void _onOutcome() {
    if (!mounted || _phase == _Phase.done || _phase == _Phase.stamp) return;
    switch (widget.run.outcome) {
      case SendOutcome.pending:
        return;
      case SendOutcome.failed:
        if (_motion.reduced) return _finish();
        _dropFrom = _flown ? _Plane.last : _Plane.curve(_fly.value);
        _fly.stop();
        _phase = _Phase.dropping;
        _drop.forward(from: 0);
      case SendOutcome.sent:
        // The stamp waits for the plane to be gone.
        if (!_flown) return;
        _phase = _Phase.stamp;
        if (!_motion.reduced) _land.forward(from: 0);
        _rest = Timer(widget.dwell, () {
          if (!mounted) return;
          if (_motion.reduced) {
            _finish();
          } else {
            _fade.forward(from: 0);
          }
        });
    }
    setState(() {});
  }

  void _finish() {
    if (_phase == _Phase.done) return;
    _phase = _Phase.done;
    // Not now: this can run while the tree builds.
    scheduleMicrotask(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    widget.run.removeListener(_onOutcome);
    _rest?.cancel();
    _fly.dispose();
    _drop.dispose();
    _land.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _time(PinPointMotion.of(context));
    final tokens = PinPointTokens.of(context);
    final rect = widget.run.rect;
    return switch (_phase) {
      _Phase.done => const SizedBox.shrink(),
      _Phase.stamp => Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fromRect(
            rect: rect,
            child: AnimatedBuilder(
              animation: Listenable.merge([_land, _fade]),
              builder: (context, _) {
                final grow =
                    1 +
                    0.18 * (1 - PinPointMotion.spring.transform(_land.value));
                return Opacity(
                  opacity: 1 - _fade.value,
                  child: Transform.scale(
                    scale: grow,
                    child: _Stamp(tokens: tokens),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      _ => SizedBox.expand(
        child: AnimatedBuilder(
          animation: Listenable.merge([_fly, _drop]),
          builder: (context, _) => CustomPaint(
            painter: _Plane(
              rect: rect,
              progress: _phase == _Phase.dropping
                  ? _dropFrom
                  : _Plane.curve(_fly.value),
              fall: _phase == _Phase.dropping
                  ? PinPointMotion.exit.transform(_drop.value)
                  : null,
              ink: tokens.ink,
              paper: tokens.paper,
              wing: tokens.rule,
              shadow: tokens.shadow,
            ),
          ),
        ),
      ),
    };
  }
}

/// The "Sent" label, in the look of the enabled Send button.
class _Stamp extends StatelessWidget {
  const _Stamp({required this.tokens});

  final PinPointTokens tokens;

  @override
  Widget build(BuildContext context) {
    final style = tokens.body.copyWith(
      color: tokens.onAccent,
      fontWeight: FontWeight.w500,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.accent,
        border: Border.all(color: tokens.ink),
      ),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sent', style: style, maxLines: 1),
              const SizedBox(width: 4),
              Icon(PinPointIcons.check, size: 15, color: tokens.onAccent),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws the plane at [progress] of its flight over [rect], with its trail,
/// or falling when [fall] is set. Hard edges and a hard offset shadow: no
/// blur, as everywhere in the Drafting look.
class _Plane extends CustomPainter {
  _Plane({
    required this.rect,
    required this.progress,
    required this.fall,
    required this.ink,
    required this.paper,
    required this.wing,
    required this.shadow,
  });

  /// Where the plane has got to, from a progress of the flight.
  static double curve(double t) => PinPointMotion.move.transform(t);

  /// Where the plane leaves the button: past the right edge.
  static const double last = 0.92;

  static const double _width = 18;
  static const double _height = 13;
  static const double _trail = 0.34;
  static const int _ticks = 10;

  final Rect rect;
  final double progress;

  /// 0 to 1 while the plane falls; null in flight.
  final double? fall;
  final Color ink, paper, wing, shadow;

  Offset _at(double u) {
    final left = rect.left - 8;
    final right = rect.right + 30;
    final lift = -5 * math.sin(math.pi * u.clamp(0, 1));
    return Offset(left + (right - left) * u, rect.center.dy + lift);
  }

  @override
  void paint(Canvas canvas, Size size) {
    var at = _at(progress);
    var turn = -0.12 * (1 - progress);
    var opacity = 1.0;
    final falling = fall;
    if (falling == null) {
      final line = Paint()
        ..color = ink
        ..strokeWidth = 1.5
        ..isAntiAlias = false;
      // A dash every other step behind the plane, on the path it flew.
      for (var k = 2; k <= _ticks; k += 2) {
        final u = progress - _trail * k / _ticks;
        if (u <= 0) break;
        final p = _at(u);
        if (p.dx < rect.left || p.dx > rect.right + 30) continue;
        canvas.drawLine(p.translate(-3, 0), p.translate(3, 0), line);
      }
    } else {
      at = at.translate(7 * falling, 26 * falling);
      turn = 1.0 * falling;
      opacity = 1 - falling;
    }
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(turn);
    final path = Path()
      ..moveTo(_width / 2, 0)
      ..lineTo(-_width / 2, -_height / 2)
      ..lineTo(-_width / 4, 0)
      ..lineTo(-_width / 2, _height / 2)
      ..close();
    final lower = Path()
      ..moveTo(_width / 2, 0)
      ..lineTo(-_width / 4, 0)
      ..lineTo(-_width / 2, _height / 2)
      ..close();
    Color fade(Color c) => c.withValues(alpha: c.a * opacity);
    canvas.drawPath(
      path.shift(const Offset(1.5, 1.5)),
      Paint()..color = fade(shadow),
    );
    canvas.drawPath(path, Paint()..color = fade(paper));
    canvas.drawPath(lower, Paint()..color = fade(wing));
    canvas.drawPath(
      path,
      Paint()
        ..color = fade(ink)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25
        ..strokeJoin = StrokeJoin.miter,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Plane old) =>
      old.rect != rect ||
      old.progress != progress ||
      old.fall != fall ||
      old.ink != ink ||
      old.paper != paper ||
      old.wing != wing ||
      old.shadow != shadow;
}

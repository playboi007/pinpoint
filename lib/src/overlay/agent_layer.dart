import 'package:flutter/material.dart';

import '../agent/agent_control.dart';
import '../search/render_search.dart';
import '../theme/marks.dart';
import '../theme/pinpoint_motion.dart';
import '../theme/pinpoint_tokens.dart';

/// What the agent is doing, drawn above the app: a chip while control is
/// on ("AGENT CONTROL ON"), a banner while a command runs, a dot where each
/// synthetic tap lands, and the outline of `flash`.
///
/// When control turns on, a dashed accent line draws itself once around the
/// screen edge (500 ms) and then stays still while control is on. When it
/// turns off the line pulls back (250 ms). The chip stays: the line is the
/// first sight of it, not a replacement. With reduced motion the line is
/// there or not, at once.
///
/// It takes no pointer events: a synthetic tap must reach the app, not
/// this layer. The switch that turns control on and off is the rail's smart
/// toy item, which carries [toggleKey].
class AgentLayer extends StatefulWidget {
  const AgentLayer({super.key, required this.agent, required this.origin});

  static const Key bannerKey = ValueKey<String>('pinpoint.agent.banner');
  static const Key marksKey = ValueKey<String>('pinpoint.agent.marks');

  /// The dashed line around the screen edge while control is on.
  static const Key edgeKey = ValueKey<String>('pinpoint.agent.edge');

  /// How long the edge line takes to draw itself around the screen.
  static const Duration edgeDraw = Duration(milliseconds: 500);

  /// The "Allow agent control" item of the rail.
  static const Key toggleKey = ValueKey<String>('pinpoint.agent.toggle');

  /// How long the flash outline takes to fade out.
  static const Duration flashFade = Duration(milliseconds: 600);

  final AgentControl agent;

  /// The layer's global position, to turn global rects into local ones.
  final Offset Function() origin;

  @override
  State<AgentLayer> createState() => _AgentLayerState();
}

class _AgentLayerState extends State<AgentLayer> with TickerProviderStateMixin {
  /// 0 when the flash starts, 1 when it has faded out. Runs only while a
  /// flash is on screen.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: AgentLayer.flashFade,
    value: 1,
  );

  /// 0 when the edge line is not there, 1 when it is all drawn. It moves
  /// only for the moment control turns on or off.
  late final AnimationController _edge = AnimationController(vsync: this);

  /// Whether control was on at the last change, to see it turn on or off.
  bool _wasEnabled = false;

  @override
  void initState() {
    super.initState();
    widget.agent.flash.addListener(_flashed);
    widget.agent.addListener(_agentChanged);
    // Already on at the start: the line is simply there.
    _wasEnabled = widget.agent.enabled;
    if (_wasEnabled) _edge.value = 1;
  }

  @override
  void didUpdateWidget(AgentLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.agent, widget.agent)) {
      oldWidget.agent.flash.removeListener(_flashed);
      oldWidget.agent.removeListener(_agentChanged);
      widget.agent.flash.addListener(_flashed);
      widget.agent.addListener(_agentChanged);
      _wasEnabled = widget.agent.enabled;
      _edge.value = _wasEnabled ? 1 : 0;
    }
  }

  @override
  void dispose() {
    widget.agent.flash.removeListener(_flashed);
    widget.agent.removeListener(_agentChanged);
    _fade.dispose();
    _edge.dispose();
    super.dispose();
  }

  void _agentChanged() {
    final on = widget.agent.enabled;
    if (on == _wasEnabled) return;
    _wasEnabled = on;
    if (!mounted) return;
    _timeEdge(PinPointMotion.of(context));
    // Zero durations (reduced motion) end at once.
    if (on) {
      _edge.forward();
    } else {
      _edge.reverse();
    }
  }

  void _timeEdge(PinPointMotion motion) {
    _edge
      ..duration = motion.scaled(AgentLayer.edgeDraw)
      ..reverseDuration = motion.moderate;
  }

  void _flashed() {
    if (widget.agent.flash.value != null) _fade.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    // It shows where the agent acted: it fades with reduced motion too.
    final motion = PinPointMotion.of(context);
    _fade.duration = motion.informative(AgentLayer.flashFade);
    _timeEdge(motion);
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            key: AgentLayer.edgeKey,
            painter: _EdgePainter(draw: _edge, tokens: tokens),
          ),
          CustomPaint(
            key: AgentLayer.marksKey,
            painter: _AgentPainter(
              agent: widget.agent,
              origin: widget.origin,
              tokens: tokens,
              fade: _fade,
            ),
          ),
          ListenableBuilder(
            listenable: widget.agent,
            builder: (context, _) {
              if (!widget.agent.enabled && widget.agent.driving == null) {
                return const SizedBox.shrink();
              }
              return SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _banner(tokens, widget.agent.driving),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// The chip while control is on, filled with the accent while a command
  /// runs. The text differs too, so the fill is not the only signal.
  Widget _banner(PinPointTokens tokens, String? driving) {
    final running = driving != null;
    final color = running ? tokens.onAccent : tokens.ink;
    return DecoratedBox(
      key: AgentLayer.bannerKey,
      decoration: running
          ? tokens.surface(2).copyWith(color: tokens.accent)
          : tokens.surface(2),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PinPointIcons.smartToy, size: 16, color: color),
            const SizedBox(width: 8),
            Text(
              running
                  ? 'AGENT DRIVING · ${driving.toUpperCase()} · ESC STOPS'
                  : 'AGENT CONTROL ON · ESC STOPS',
              style: tokens.caps.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// The dashed accent line around the screen edge, drawn from the top-left
/// corner clockwise up to [draw] of its length, over a paper halo. Nothing
/// is drawn at 0. It repaints only while [draw] moves.
class _EdgePainter extends CustomPainter {
  _EdgePainter({required this.draw, required this.tokens})
    : super(repaint: draw);

  final Animation<double> draw;
  final PinPointTokens tokens;

  /// 2 px mark, 1 px of halo each side: inset so all of it is on screen.
  static const double _inset = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final t = PinPointMotion.enter.transform(draw.value.clamp(0.0, 1.0));
    if (t <= 0 || size.isEmpty) return;
    final rect = (Offset.zero & size).deflate(_inset);
    final metric = (Path()..addRect(rect)).computeMetrics().first;
    final shown = metric.extractPath(0, metric.length * t);
    strokeHalo(
      canvas,
      shown,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = tokens.accent,
      tokens,
      dash: const [10, 6],
    );
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      !identical(old.draw, draw) || old.tokens != tokens;
}

class _AgentPainter extends CustomPainter {
  _AgentPainter({
    required this.agent,
    required this.origin,
    required this.tokens,
    required this.fade,
  }) : super(repaint: Listenable.merge([agent.marks, agent.flash, fade]));

  final AgentControl agent;
  final Offset Function() origin;
  final PinPointTokens tokens;

  /// 0 at the start of a flash, 1 when it is gone.
  final Animation<double> fade;

  @override
  void paint(Canvas canvas, Size size) {
    final at = origin();
    final target = agent.flash.value;
    final rect = target == null ? null : RenderSearch.globalRectOf(target);
    if (rect != null && fade.value < 1) {
      paintAgentFlash(canvas, rect.shift(-at), tokens, 1 - fade.value);
    }
    for (final mark in agent.marks.value) {
      final center = mark.position - at;
      // The ripple: 30 px across, 1 px, accent at 60%.
      canvas.drawCircle(
        center,
        14.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = tokens.accent.withValues(alpha: 0.6),
      );
      // The dot: 18 px of accent, a 2 px paper ring, a 1 px ink ring.
      canvas
        ..drawCircle(center, 9 + 2 + 1, Paint()..color = tokens.ink)
        ..drawCircle(center, 9 + 2, Paint()..color = tokens.paper)
        ..drawCircle(center, 9, Paint()..color = tokens.accent);
      if (mark.longPress) {
        // A long press also gets a ring inside the dot, so the two taps do
        // not differ by size alone.
        canvas.drawCircle(
          center,
          5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = tokens.onAccent,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_AgentPainter old) =>
      !identical(old.agent, agent) ||
      old.origin != origin ||
      old.tokens != tokens;
}

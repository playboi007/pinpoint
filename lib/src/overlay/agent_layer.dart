import 'package:flutter/material.dart';

import '../agent/agent_control.dart';
import '../search/render_search.dart';
import '../theme/marks.dart';
import '../theme/pinpoint_tokens.dart';

/// What the agent is doing, drawn above the app: a chip while control is
/// on ("AGENT CONTROL ON"), a banner while a command runs, a dot where each
/// synthetic tap lands, and the outline of `flash`.
///
/// It takes no pointer events: a synthetic tap must reach the app, not
/// this layer. The switch that turns control on and off is the rail's smart
/// toy item, which carries [toggleKey].
class AgentLayer extends StatefulWidget {
  const AgentLayer({super.key, required this.agent, required this.origin});

  static const Key bannerKey = ValueKey<String>('pinpoint.agent.banner');
  static const Key marksKey = ValueKey<String>('pinpoint.agent.marks');

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

class _AgentLayerState extends State<AgentLayer>
    with SingleTickerProviderStateMixin {
  /// 0 when the flash starts, 1 when it has faded out. Runs only while a
  /// flash is on screen.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: AgentLayer.flashFade,
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    widget.agent.flash.addListener(_flashed);
  }

  @override
  void didUpdateWidget(AgentLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.agent, widget.agent)) {
      oldWidget.agent.flash.removeListener(_flashed);
      widget.agent.flash.addListener(_flashed);
    }
  }

  @override
  void dispose() {
    widget.agent.flash.removeListener(_flashed);
    _fade.dispose();
    super.dispose();
  }

  void _flashed() {
    if (widget.agent.flash.value != null) _fade.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
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

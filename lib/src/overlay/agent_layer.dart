import 'package:flutter/material.dart';

import '../agent/agent_control.dart';
import '../core/pinpoint_controller.dart';
import '../search/render_search.dart';
import 'toolbar.dart';

/// What the agent is doing, drawn above the app: a chip while control is
/// on ("Agent control on"), a banner while a command runs, a dot where each
/// synthetic tap lands, and the outline of `flash`.
///
/// It takes no pointer events: a synthetic tap must reach the app, not
/// this layer (the toggle is a separate widget, [AgentToggle]).
class AgentLayer extends StatelessWidget {
  const AgentLayer({super.key, required this.agent, required this.origin});

  static const Key bannerKey = ValueKey<String>('pinpoint.agent.banner');
  static const Key marksKey = ValueKey<String>('pinpoint.agent.marks');
  static const Key toggleKey = ValueKey<String>('pinpoint.agent.toggle');

  final AgentControl agent;

  /// The layer's global position, to turn global rects into local ones.
  final Offset Function() origin;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            key: marksKey,
            painter: _AgentPainter(agent: agent, origin: origin),
          ),
          ListenableBuilder(
            listenable: agent,
            builder: (context, _) {
              if (!agent.enabled && agent.driving == null) {
                return const SizedBox.shrink();
              }
              final driving = agent.driving;
              return SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Material(
                      key: bannerKey,
                      elevation: 3,
                      color: driving == null
                          ? colors.tertiaryContainer
                          : colors.tertiary,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.smart_toy_outlined,
                              size: 16,
                              color: driving == null
                                  ? colors.onTertiaryContainer
                                  : colors.onTertiary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              driving == null
                                  ? 'Agent control on · Esc stops'
                                  : 'Agent is driving: $driving · Esc stops',
                              style: TextStyle(
                                fontSize: 12,
                                color: driving == null
                                    ? colors.onTertiaryContainer
                                    : colors.onTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The "Allow agent control" switch: a round button above the launcher.
/// Shown while a mode is active, and in idle while control is on, so it can
/// always be turned off where it shows that it is on.
class AgentToggle extends StatelessWidget {
  const AgentToggle({super.key, required this.controller});

  final PinPointController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.agent,
    builder: (context, _) {
      final on = controller.agent.enabled;
      if (!controller.isActive && !on) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      return SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            // Above the launcher's default corner.
            padding: const EdgeInsets.only(
              right: 16,
              bottom: 16 + PinPointLauncher.size + 8,
            ),
            child: Tooltip(
              message: on
                  ? 'Agent control on: click or Esc to turn it off'
                  : 'Allow agent control',
              child: Material(
                key: AgentLayer.toggleKey,
                type: MaterialType.circle,
                elevation: 4,
                color: on ? colors.tertiary : colors.surface,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => controller.agent.enabled = !on,
                  child: SizedBox.square(
                    dimension: PinPointLauncher.size,
                    child: Icon(
                      on ? Icons.smart_toy : Icons.smart_toy_outlined,
                      color: on ? colors.onTertiary : colors.primary,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _AgentPainter extends CustomPainter {
  _AgentPainter({required this.agent, required this.origin})
    : super(repaint: Listenable.merge([agent.marks, agent.flash]));

  final AgentControl agent;
  final Offset Function() origin;

  static const Color _tap = Color(0xFFE040FB);
  static const Color _flash = Color(0xFFFF6D00);

  @override
  void paint(Canvas canvas, Size size) {
    final at = origin();
    final target = agent.flash.value;
    final rect = target == null ? null : RenderSearch.globalRectOf(target);
    if (rect != null) {
      canvas.drawRect(
        rect.shift(-at).inflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = _flash,
      );
    }
    for (final mark in agent.marks.value) {
      final center = mark.position - at;
      canvas
        ..drawCircle(center, 10, Paint()..color = _tap.withValues(alpha: 0.35))
        ..drawCircle(
          center,
          mark.longPress ? 14 : 10,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = _tap,
        );
    }
  }

  @override
  bool shouldRepaint(_AgentPainter old) =>
      !identical(old.agent, agent) || old.origin != origin;
}

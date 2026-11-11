import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../core/pinpoint_controller.dart';
import '../sink/http_sink.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';

/// The launcher at the foot of the rail: an ink block that starts and stops
/// picking.
///
/// It is 40 px wide and [height] high, to sit inside the rail. While a mode is
/// active it shows a close glyph instead of the launcher glyph, and while the
/// app is frozen it carries a small snowflake mark in its corner.
class PinPointLauncher extends StatelessWidget {
  const PinPointLauncher({
    super.key,
    required this.controller,
    required this.shortcutLabel,
  });

  /// Height of the launcher.
  static const double height = PinPointSizes.launcher;

  /// Width of the launcher: the width of a rail item.
  static const double width = PinPointSizes.railItem;

  final PinPointController controller;
  final String shortcutLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final active = controller.isActive;
    return Tooltip(
      message:
          'Pinpoint ($shortcutLabel)'
          '${controller.frozen ? ', app frozen: P while picking resumes' : ''}',
      child: Semantics(
        button: true,
        label: 'Pinpoint',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: controller.toggle,
            child: Container(
              width: width,
              height: height,
              color: tokens.ink,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    active ? PinPointIcons.close : PinPointIcons.launcher,
                    size: 20,
                    color: tokens.paper,
                  ),
                  if (controller.frozen)
                    Positioned(
                      right: 3,
                      top: 3,
                      child: Container(
                        width: 12,
                        height: 12,
                        alignment: Alignment.center,
                        color: tokens.paper,
                        child: Icon(
                          PinPointIcons.acUnit,
                          size: 10,
                          color: tokens.ink,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Says which HTTP sinks did not answer their health check: the
/// `BRIDGE OFFLINE` system badge, and under it one line per sink. Notes still
/// go to the other sinks.
///
/// It takes no pointer events, so a widget under it can still be picked. That
/// is why the detail is printed instead of kept in the badge's tooltip, which
/// needs a hover. [SystemBadgeLayer] places it.
class BridgeBadge extends StatelessWidget {
  const BridgeBadge({super.key, required this.offline});

  static const Key badgeKey = ValueKey<String>('pinpoint.bridgeOffline');

  /// For example `bridge offline: 127.0.0.1:4747`, one per sink.
  final List<String> offline;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    return IgnorePointer(
      child: Column(
        key: badgeKey,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SystemBadge.bridgeOffline(detail: offline.join('\n')),
          for (final line in offline)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: DraftSurface(
                elevation: 1,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  line,
                  style: tokens.micro.copyWith(color: tokens.ink),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The system badges, top-right: `FROZEN` while the app is frozen, and the
/// bridge badge while a mode is active and a sink is offline. Freeze and
/// agent control are independent, so each has its own signal.
///
/// It takes no pointer events.
class SystemBadgeLayer extends StatelessWidget {
  const SystemBadgeLayer({
    super.key,
    required this.controller,
    required this.offline,
  });

  static const Key frozenKey = ValueKey<String>('pinpoint.frozenBadge');

  final PinPointController controller;

  /// The HTTP sinks that did not answer. Empty when every sink answers.
  final ValueListenable<List<HttpSink>> offline;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: ListenableBuilder(
              listenable: Listenable.merge([controller, offline]),
              builder: (context, _) {
                final lines = controller.isActive
                    ? [
                        for (final sink in offline.value)
                          '${sink.name} offline: ${sink.url.authority}',
                      ]
                    : const <String>[];
                if (!controller.frozen && lines.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (controller.frozen)
                      const SystemBadge.frozen(key: frozenKey),
                    if (controller.frozen && lines.isNotEmpty)
                      const SizedBox(height: 6),
                    if (lines.isNotEmpty) BridgeBadge(offline: lines),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

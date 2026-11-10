import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/pinpoint_controller.dart';

/// Covers the screen and places [PinPointLauncher], bottom-right by default.
///
/// Only the launcher itself takes pointer events; the rest of the area lets
/// them through.
class LauncherLayer extends StatefulWidget {
  const LauncherLayer({
    super.key,
    required this.controller,
    required this.shortcutLabel,
  });

  final PinPointController controller;
  final String shortcutLabel;

  @override
  State<LauncherLayer> createState() => _LauncherLayerState();
}

class _LauncherLayerState extends State<LauncherLayer> {
  static const double _margin = 16;

  /// Top-left corner after a drag. Null means the default corner.
  Offset? _position;

  Offset _clamp(Offset position, Size area) => Offset(
    position.dx.clamp(0, area.width - PinPointLauncher.size).toDouble(),
    position.dy.clamp(0, area.height - PinPointLauncher.size).toDouble(),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = constraints.biggest;
        // Clamp on every build too, so a window resize never leaves the
        // launcher off screen.
        final position = _clamp(
          _position ??
              Offset(
                area.width - PinPointLauncher.size - _margin,
                area.height - PinPointLauncher.size - _margin,
              ),
          area,
        );
        return Stack(
          children: [
            Positioned(
              left: position.dx,
              top: position.dy,
              child: GestureDetector(
                // Count the movement from pointer down, so the launcher
                // stays under the pointer instead of lagging by the slop.
                dragStartBehavior: DragStartBehavior.down,
                // Several updates can arrive before the next build, so add to
                // the stored position, not to the one this build used.
                onPanUpdate: (details) => setState(
                  () => _position = _clamp(
                    _clamp(_position ?? position, area) + details.delta,
                    area,
                  ),
                ),
                child: PinPointLauncher(
                  controller: widget.controller,
                  shortcutLabel: widget.shortcutLabel,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The round button that starts and stops picking.
class PinPointLauncher extends StatelessWidget {
  const PinPointLauncher({
    super.key,
    required this.controller,
    required this.shortcutLabel,
  });

  static const double size = 44;

  final PinPointController controller;
  final String shortcutLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = controller.isActive;
    return Tooltip(
      message:
          'Pinpoint ($shortcutLabel)'
          '${controller.frozen ? ', app frozen: P while picking resumes' : ''}',
      child: Material(
        type: MaterialType.circle,
        elevation: 4,
        color: active ? colors.primary : colors.surface,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: controller.toggle,
          child: SizedBox.square(
            dimension: size,
            child: Badge(
              isLabelVisible: controller.frozen,
              label: const Icon(Icons.ac_unit, size: 10),
              backgroundColor: colors.tertiary,
              child: Icon(
                active ? Icons.close : Icons.ads_click,
                color: active ? colors.onPrimary : colors.primary,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Says which HTTP sinks did not answer their health check, top-right,
/// while a mode is active. Notes still go to the other sinks.
///
/// It takes no pointer events, so a widget under it can still be picked.
class BridgeBadge extends StatelessWidget {
  const BridgeBadge({super.key, required this.offline});

  static const Key badgeKey = ValueKey<String>('pinpoint.bridgeOffline');

  /// For example `bridge offline: 127.0.0.1:4747`, one per sink.
  final List<String> offline;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Material(
              key: badgeKey,
              color: colors.errorContainer,
              borderRadius: BorderRadius.circular(12),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cloud_off,
                      size: 14,
                      color: colors.onErrorContainer,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      offline.join(', '),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

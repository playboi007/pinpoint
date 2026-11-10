import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/pinpoint_controller.dart';
import '../info/widget_info.dart';
import '../search/pick_result.dart';

/// Covers the screen and places [InfoPanel] while there is a selection.
///
/// Only the panel takes pointer events; the rest of the area lets them
/// through to the trap.
class InfoPanelLayer extends StatelessWidget {
  const InfoPanelLayer({super.key, required this.controller});

  final PinPointController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PickResult?>(
      valueListenable: controller.selection,
      builder: (context, selection, _) {
        if (selection == null) return const SizedBox.shrink();
        return _PanelPlacement(controller: controller, selection: selection);
      },
    );
  }
}

class _PanelPlacement extends StatefulWidget {
  const _PanelPlacement({required this.controller, required this.selection});

  final PinPointController controller;
  final PickResult selection;

  @override
  State<_PanelPlacement> createState() => _PanelPlacementState();
}

class _PanelPlacementState extends State<_PanelPlacement> {
  static const double _margin = 16;

  Offset _clamp(Offset position, Size area, double width) => Offset(
    position.dx.clamp(0, (area.width - width).clamp(0, double.infinity)),
    position.dy.clamp(
      0,
      (area.height - InfoPanel.headerHeight).clamp(0, double.infinity),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = constraints.biggest;
        final width = area.width < InfoPanel.width
            ? area.width
            : InfoPanel.width;
        // Clamped on every build too, so a window resize never leaves the
        // header off screen.
        final position = _clamp(
          widget.controller.panelPosition ??
              Offset(area.width - width - _margin, _margin),
          area,
          width,
        );
        return Stack(
          children: [
            Positioned(
              left: position.dx,
              top: position.dy,
              width: width,
              child: InfoPanel(
                selection: widget.selection,
                maxHeight: area.height - position.dy,
                onClose: widget.controller.clearSelection,
                onDrag: (delta) => setState(() {
                  // Several updates can arrive before the next build, so add
                  // to the stored position, not to the one this build used.
                  final from = widget.controller.panelPosition ?? position;
                  widget.controller.panelPosition = _clamp(
                    _clamp(from, area, width) + delta,
                    area,
                    width,
                  );
                }),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A card with the picked widget's [WidgetInfo]: labels, then sections.
///
/// Milestone 5 adds a Comment tab and Milestone 11 a Tweak tab; for now it
/// shows the Info content only.
class InfoPanel extends StatelessWidget {
  const InfoPanel({
    super.key = panelKey,
    required this.selection,
    required this.onClose,
    required this.onDrag,
    this.maxHeight = double.infinity,
  });

  static const Key panelKey = ValueKey<String>('pinpoint.infoPanel');
  static const Key headerKey = ValueKey<String>('pinpoint.infoPanel.header');

  static const double width = 300;
  static const double headerHeight = 48;

  final PickResult selection;
  final VoidCallback onClose;
  final ValueChanged<Offset> onDrag;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final WidgetInfo? info;
    try {
      info = WidgetInfo.fromRenderObject(selection.renderObject);
    } catch (_) {
      // The tracker clears a selection whose element is gone after the next
      // frame; until then there is nothing to read.
      return const SizedBox.shrink();
    }
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              key: headerKey,
              // Count the movement from pointer down, so the panel stays
              // under the pointer instead of lagging by the touch slop.
              dragStartBehavior: DragStartBehavior.down,
              onPanUpdate: (details) => onDrag(details.delta),
              child: _Header(
                selection: selection,
                renderType: info.renderType,
                onClose: onClose,
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: _InfoContent(info: info, theme: theme),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.selection,
    required this.renderType,
    required this.onClose,
  });

  final PickResult selection;
  final String renderType;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: Container(
        height: InfoPanel.headerHeight,
        color: theme.colorScheme.surfaceContainerHigh,
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${selection.element.widget.runtimeType}',
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    renderType,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Tooltip(
              message: 'Click the same spot again for the next widget',
              child: Text(
                '${selection.index + 1} of ${selection.candidates.length}',
                style: theme.textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: 'Close panel',
              iconSize: 18,
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoContent extends StatelessWidget {
  const _InfoContent({required this.info, required this.theme});

  final WidgetInfo info;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final title = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.primary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Row(name: 'size', label: info.sizeLabel),
        _Row(name: 'position', label: info.positionLabel),
        _Row(name: 'constraints', label: info.constraintsLabel),
        _Row(name: 'depth', label: '${info.depth}'),
        for (final section in info.sections) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(section.title, style: title),
          ),
          for (final property in section.properties)
            _Row(name: property.name, label: property.label),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.name, required this.label});

  final String name;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              name,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

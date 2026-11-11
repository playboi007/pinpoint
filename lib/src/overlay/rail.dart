import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/pinpoint_controller.dart';
import '../theme/controls.dart';
import '../theme/pinpoint_tokens.dart';
import 'agent_layer.dart';
import 'environment_panel.dart';
import 'findings_panel.dart';
import 'theme_menu.dart';
import 'toolbar.dart';

/// Where the rail is, shared with the panels that open beside it.
///
/// The rail sits on the right edge and only moves up and down. [top] is null
/// until it is dragged, which means centred. [height] is set by the rail on
/// every build, so a panel can read it when it lays out.
class RailPlacement extends ChangeNotifier {
  double? _top;

  /// Outer height of the rail, border included.
  double height = 0;

  /// Outer width of the rail: the items and the 1 px border on each side.
  static const double width = PinPointSizes.railWidth + 2;

  /// The gap between the rail and the right edge of the screen.
  static const double inset = PinPointSizes.railInset;

  /// The rail's top edge in an area [areaHeight] high.
  double topIn(double areaHeight) {
    final room = math.max(0.0, areaHeight - height);
    return (_top ?? room / 2).clamp(0.0, room);
  }

  /// The rail's rectangle in an [area] this big.
  Rect rectIn(Size area) => Rect.fromLTWH(
    area.width - inset - width,
    topIn(area.height),
    width,
    height,
  );

  /// Moves the rail by [dy], which stays inside [areaHeight].
  void dragBy(double dy, double areaHeight) {
    final room = math.max(0.0, areaHeight - height);
    _top = ((_top ?? room / 2).clamp(0.0, room) + dy).clamp(0.0, room);
    notifyListeners();
  }
}

/// Opens the what-if panel or the findings list from the rail. The panels
/// live with the active modes, behind the pointer trap, so a click in idle
/// starts picking first.
void openRailPanel(PinPointController controller, ValueNotifier<bool> panel) {
  if (!controller.isActive) {
    controller.startPicking();
    panel.value = true;
    return;
  }
  panel.value = !panel.value;
}

/// One 40 px square of the rail: a glyph, an optional [badge] top-right, and
/// the active look (accent fill, accent ink, and a 2 px bar on the left, so
/// colour is not the only signal).
class RailItem extends StatefulWidget {
  const RailItem({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.badge,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// A panel is open, a control is on, or a menu is open.
  final bool active;

  /// Shown top-right, inset 4.
  final Widget? badge;

  @override
  State<RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<RailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = PinPointTokens.of(context);
    final active = widget.active;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        selected: active,
        label: widget.tooltip,
        excludeSemantics: true,
        onTap: widget.onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              width: PinPointSizes.railItem,
              height: PinPointSizes.railItem,
              color: active || _hovered ? tokens.accentBg : null,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (active)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 2,
                      child: ColoredBox(color: tokens.accent),
                    ),
                  Icon(
                    widget.icon,
                    size: 18,
                    color: active ? tokens.accentInk : tokens.ink,
                  ),
                  if (widget.badge != null)
                    Positioned(right: 4, top: 4, child: widget.badge!),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Covers the screen and places the rail on the right edge: What-if,
/// Findings, Allow agent control and Theme, then the launcher.
///
/// Only the rail and the theme menu take pointer events; the rest of the
/// area lets them through. The rail is draggable along the edge, never
/// across it.
///
/// With `showLauncher` false the rail still shows while a mode is active, or
/// while agent control is on (so the switch is where its state shows), but
/// not in idle, and it has no launcher.
class RailLayer extends StatefulWidget {
  const RailLayer({
    super.key,
    required this.controller,
    required this.placement,
    required this.environmentPanel,
    required this.findingsPanel,
    required this.shortcutLabel,
    required this.showLauncher,
    required this.allowAgentControl,
  });

  static const Key railKey = ValueKey<String>('pinpoint.rail');

  final PinPointController controller;
  final RailPlacement placement;

  /// Open state of the what-if panel and of the findings list.
  final ValueNotifier<bool> environmentPanel;
  final ValueNotifier<bool> findingsPanel;

  final String shortcutLabel;
  final bool showLauncher;
  final bool allowAgentControl;

  @override
  State<RailLayer> createState() => _RailLayerState();
}

class _RailLayerState extends State<RailLayer> {
  final Object _menuGroup = Object();
  bool _menuOpen = false;

  PinPointController get _controller => widget.controller;

  /// Outer height of the rail with [items] items.
  double _heightFor(int items) {
    // Items, a 1 px rule between each, then the ink rule and the launcher.
    var height = items * PinPointSizes.railItem + (items - 1);
    if (widget.showLauncher) height += 1 + PinPointSizes.launcher;
    return height + 2;
  }

  void _toggleMenu() => setState(() => _menuOpen = !_menuOpen);

  void _closeMenu() {
    if (_menuOpen) setState(() => _menuOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _controller,
        _controller.agent,
        _controller.findings,
        widget.environmentPanel,
        widget.findingsPanel,
        widget.placement,
      ]),
      builder: (context, _) {
        final visible =
            widget.showLauncher ||
            _controller.isActive ||
            _controller.agent.enabled;
        if (!visible) return const SizedBox.shrink();
        final tokens = PinPointTokens.of(context);
        final items = 3 + (widget.allowAgentControl ? 1 : 0);
        final placement = widget.placement..height = _heightFor(items);
        return LayoutBuilder(
          builder: (context, constraints) {
            final area = constraints.biggest;
            final rect = placement.rectIn(area);
            final paletteIndex = items - 1;
            final paletteTop =
                rect.top + 1 + paletteIndex * (PinPointSizes.railItem + 1);
            return Stack(
              children: [
                Positioned(
                  right: RailPlacement.inset,
                  top: rect.top,
                  child: GestureDetector(
                    // Count the movement from pointer down, so the rail stays
                    // under the pointer instead of lagging by the slop.
                    dragStartBehavior: DragStartBehavior.down,
                    onVerticalDragUpdate: (details) =>
                        placement.dragBy(details.delta.dy, area.height),
                    child: DraftSurface(
                      key: RailLayer.railKey,
                      elevation: 2,
                      padding: const EdgeInsets.all(1),
                      child: SizedBox(
                        width: PinPointSizes.railWidth,
                        child: _column(tokens),
                      ),
                    ),
                  ),
                ),
                if (_menuOpen)
                  Positioned(
                    right: RailPlacement.inset + RailPlacement.width + 8,
                    top: math.max(
                      8,
                      math.min(paletteTop, area.height - ThemeMenu.height - 8),
                    ),
                    child: TapRegion(
                      groupId: _menuGroup,
                      onTapOutside: (_) => _closeMenu(),
                      child: ThemeMenu(
                        palette: _controller.palette,
                        onClose: _closeMenu,
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

  Widget _column(PinPointTokens tokens) {
    final agent = _controller.agent;
    final findings = _controller.findings.findings.length;
    final children = <Widget>[
      RailItem(
        key: EnvironmentBar.toggleKey,
        icon: PinPointIcons.tune,
        tooltip: 'What-if',
        active: widget.environmentPanel.value && _controller.isActive,
        onTap: () => openRailPanel(_controller, widget.environmentPanel),
      ),
      const DraftRule(),
      RailItem(
        key: FindingsPanel.buttonKey,
        icon: PinPointIcons.warning,
        tooltip: findings == 0 ? 'Findings' : 'Findings ($findings)',
        active: widget.findingsPanel.value && _controller.isActive,
        badge: findings > 0 ? CountBadge(findings) : null,
        onTap: () => openRailPanel(_controller, widget.findingsPanel),
      ),
      const DraftRule(),
      if (widget.allowAgentControl) ...[
        RailItem(
          key: AgentLayer.toggleKey,
          icon: PinPointIcons.smartToy,
          tooltip: agent.enabled
              ? 'Agent control on: click or Esc to turn it off'
              : 'Allow agent control',
          active: agent.enabled,
          onTap: () => agent.enabled = !agent.enabled,
        ),
        const DraftRule(),
      ],
      TapRegion(
        groupId: _menuGroup,
        child: RailItem(
          key: ThemeMenu.buttonKey,
          icon: PinPointIcons.palette,
          tooltip: 'Theme',
          active: _menuOpen,
          onTap: _toggleMenu,
        ),
      ),
    ];
    if (widget.showLauncher) {
      children
        ..add(DraftRule(color: tokens.ink))
        ..add(
          PinPointLauncher(
            controller: _controller,
            shortcutLabel: widget.shortcutLabel,
          ),
        );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// Places a panel to the left of the rail: its top edge on the rail's, moved
/// up if it would run off the bottom. The width is `min(360, viewport - 16)`
/// and the height at most `viewport - 24`, so the panel's body scrolls. Where
/// the viewport is too narrow for the panel and the rail side by side, the
/// panel keeps the 8 px margin from the right edge and covers the rail.
class BesideRail extends StatelessWidget {
  const BesideRail({super.key, required this.placement, required this.child});

  final RailPlacement placement;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomSingleChildLayout(
    delegate: _BesideRailDelegate(placement),
    child: child,
  );
}

class _BesideRailDelegate extends SingleChildLayoutDelegate {
  _BesideRailDelegate(this.placement) : super(relayout: placement);

  final RailPlacement placement;

  static const double _gap = 8;
  static const double _margin = 8;
  static const double _marginY = 12;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
      PinPointSizes.panelWidth,
      math.max(0.0, constraints.maxWidth - 2 * _margin),
    );
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.max(0.0, constraints.maxHeight - 2 * _marginY),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rail = placement.rectIn(size);
    var x = rail.left - _gap - childSize.width;
    if (x < _margin) x = size.width - _margin - childSize.width;
    final y = rail.top
        .clamp(
          _marginY,
          math.max(_marginY, size.height - childSize.height - _marginY),
        )
        .toDouble();
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_BesideRailDelegate oldDelegate) =>
      oldDelegate.placement != placement;
}
